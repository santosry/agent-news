summary_schema <- function() {
  list(
    type = "object",
    additionalProperties = FALSE,
    required = list("title_final", "topic", "summary", "why_matters", "caveat"),
    properties = list(
      title_final = list(type = "string"),
      topic = list(type = "string"),
      summary = list(type = "string"),
      why_matters = list(type = "string"),
      caveat = list(type = "string")
    )
  )
}

summarize_selected <- function(selected, config) {
  if (nrow(selected) == 0) {
    return(selected |>
      dplyr::mutate(
        title_final = character(),
        summary = character(),
        why_matters = character(),
        caveat = character(),
        article_text = character()
      ))
  }

  # Article text cache to avoid re-fetching
  text_cache <- new.env(parent = emptyenv())

  purrr::map_dfr(seq_len(nrow(selected)), function(i) {
    item <- selected[i, ]

    # Use cached text if available, otherwise fetch and cache
    cache_key <- item$url[[1]]
    if (is.null(text_cache[[cache_key]])) {
      text_cache[[cache_key]] <- fetch_article_text(item)
    }
    article_text <- text_cache[[cache_key]]

    if (!deepseek_available(config)) {
      if (!config$dry_run && !isTRUE(config$allow_no_deepseek)) {
        stop("DEEPSEEK_API_KEY is required outside dry run unless ALLOW_NO_DEEPSEEK=true.", call. = FALSE)
      }
      out <- fallback_summary(item, article_text)
    } else {
      out <- tryCatch(
        summarize_one_with_deepseek(item, article_text, config),
        error = function(e) {
          if (isTRUE(config$allow_no_deepseek)) {
            log_warn("DeepSeek summary failed for {item$url[[1]]}: {conditionMessage(e)}; using fallback summary.")
            fallback_summary(item, article_text)
          } else {
            stop(conditionMessage(e), call. = FALSE)
          }
        }
      )
    }

    item |>
      dplyr::mutate(
        title_final = clean_text(out$title_final %||% .data$title),
        topic = clean_text(out$topic %||% .data$topic),
        summary = clean_text(out$summary %||% ""),
        why_matters = clean_text(out$why_matters %||% ""),
        caveat = clean_text(out$caveat %||% "Nenhuma ressalva material identificável no conteúdo disponível."),
        article_text = article_text
      )
  })
}

summarize_one_with_deepseek <- function(item, article_text, config) {
  instructions <- paste(
    "You write analytical news clipping summaries in Brazilian Portuguese.",
    "Use only the supplied article title, source, date, excerpt, and article text.",
    "Do not invent facts, numbers, actors, or caveats.",
    "Do not attribute the story to any source other than the supplied source.",
    "Do not use sensationalist language or generic AI phrases.",
    "Explain objectively what happened, who is involved, important numbers, and reported consequences when present.",
    "If no material caveat is identifiable, say that clearly in Portuguese.",
    sep = "\n"
  )

  payload <- list(
    title = item$title[[1]],
    source = item$source[[1]],
    published_at = format(item$published_at[[1]], "%Y-%m-%d %H:%M:%S %Z"),
    topic = item$topic[[1]],
    score = item$score[[1]],
    excerpt = item$excerpt[[1]],
    article_text = substr(article_text, 1, 9000)
  )

  input <- jsonlite::toJSON(payload, auto_unbox = TRUE)

  deepseek_chat_completions(
    config = config,
    model = config$summary_model,
    system_prompt = instructions,
    user_prompt = input,
    schema_name = "news_summary",
    schema = summary_schema()
  )
}

fallback_summary <- function(item, article_text) {
  basis <- prepare_deterministic_text(article_text %||% item$excerpt[[1]])
  if (!nzchar(basis)) basis <- prepare_deterministic_text(item$excerpt[[1]])
  summary <- deterministic_summary_text(basis, item$title[[1]])
  list(
    title_final = item$title[[1]],
    topic = item$topic[[1]],
    summary = summary,
    why_matters = deterministic_why_matters(item, basis),
    caveat = deterministic_caveat(item, basis)
  )
}

prepare_deterministic_text <- function(text) {
  text <- clean_text(text %||% "")
  if (is.na(text)) return("")
  text <- stringr::str_remove(text, "O post .* apareceu primeiro em .*")
  text <- stringr::str_remove(text, "The post .* appeared first on .*")
  stringr::str_squish(text)
}

deterministic_summary_text <- function(text, title) {
  text <- prepare_deterministic_text(text)
  if (!nzchar(text)) return(clean_text(title))
  sentences <- unlist(stringr::str_split(text, "(?<=[.!?])\\s+"), use.names = FALSE)
  sentences <- sentences[nchar(sentences) >= 35]
  summary <- if (length(sentences) > 0) {
    paste(utils::head(sentences, 2), collapse = " ")
  } else {
    text
  }
  trim_to_words(summary, 620)
}

trim_to_words <- function(text, max_chars = 620) {
  text <- clean_text(text)
  if (is.na(text) || nchar(text) <= max_chars) return(text %||% "")
  clipped <- substr(text, 1, max_chars)
  clipped <- stringr::str_remove(clipped, "\\s+\\S*$")
  paste0(clipped, "...")
}

deterministic_why_matters <- function(item, text) {
  source <- item$source[[1]]
  topic <- item$topic[[1]]
  normalized <- normalize_title(paste(item$title[[1]], item$excerpt[[1]], text))

  if (source %in% c("IFF", "UENF")) {
    if (has_any_normalized_term(normalized, c("edital", "inscricao", "vaga", "monitoria", "bolsa", "mestrado", "doutorado", "concurso", "resultado"))) {
      return("Interessa diretamente à comunidade acadêmica porque envolve prazos, oportunidades, seleção, editais ou resultados que podem orientar decisões de estudo, trabalho e pesquisa.")
    }
    if (has_any_normalized_term(normalized, c("pesquisa", "inovacao", "metodologia", "nanotecnologia", "laboratorio", "extensao", "tecnologia"))) {
      return("Ajuda a mapear a produção científica, tecnológica e extensionista da região, além de possíveis agendas de colaboração entre universidade, setor público e sociedade.")
    }
    return("Mantém no radar movimentos institucionais de IFF e UENF, duas instituições centrais para ensino, pesquisa, extensão e desenvolvimento regional.")
  }

  if (identical(topic, "saúde pública")) {
    return("Importa porque pode afetar prevenção, acesso a serviços, organização da rede de saúde ou risco sanitário para grupos populacionais específicos.")
  }
  if (identical(topic, "economia")) {
    return("Importa porque ajuda a acompanhar emprego, arrecadação, investimento, atividade empresarial e decisões que podem alterar o cenário econômico local ou nacional.")
  }
  if (identical(topic, "meio ambiente")) {
    return("Importa porque envolve clima, energia, território, poluição ou riscos ambientais com possíveis efeitos sobre saúde, infraestrutura e gestão pública.")
  }
  if (identical(topic, "Campos/Norte Fluminense")) {
    return("Importa porque trata de decisão, serviço ou evento com efeito direto sobre Campos dos Goytacazes e o Norte Fluminense.")
  }
  if (nzchar(item$justification[[1]]) && !stringr::str_detect(item$justification[[1]], "DEEPSEEK_API_KEY|heurístico")) {
    return(item$justification[[1]])
  }
  "Importa porque pode influenciar decisões públicas, acadêmicas ou institucionais ao longo da semana."
}

deterministic_caveat <- function(item, text) {
  normalized <- normalize_title(paste(item$title[[1]], item$excerpt[[1]], text))
  if (!nzchar(text) || nchar(text) < 180) {
    return("Material público disponível é curto; há pouco contexto além do título e da chamada.")
  }
  if (has_any_normalized_term(normalized, c("edital", "inscricao", "homologacao", "resultado", "concurso", "monitoria", "bolsa"))) {
    return("Para prazos, requisitos e documentação, vale conferir o comunicado ou edital original.")
  }
  if (has_any_normalized_term(normalized, c("pesquisa", "estudo", "metodologia", "laboratorio", "nanotecnologia"))) {
    return("Detalhes metodológicos e evidências técnicas devem ser conferidos na publicação ou fonte original citada pela instituição.")
  }
  ""
}

fetch_article_text <- function(item) {
  tryCatch({
    if (item$source[[1]] == "J3News" && stringr::str_detect(item$id[[1]], "^j3-[0-9]+$")) {
      post_id <- stringr::str_remove(item$id[[1]], "^j3-")
      url <- paste0("https://j3news.com/wp-json/wp/v2/posts/", post_id, "?_fields=content,excerpt")
      resp <- http_get(url, timeout = 25)
      post <- jsonlite::fromJSON(response_text(resp), simplifyVector = FALSE)
      text <- clean_text(strip_html(post$content$rendered %||% post$excerpt$rendered %||% ""))
      return(substr(text, 1, 6000))
    }

    doc <- read_html_url(item$url[[1]], timeout = 25)
    text <- extract_article_text_from_doc(doc)
    if (!nzchar(text)) text <- item$excerpt[[1]]
    text
  }, error = function(e) {
    log_warn("Article text unavailable for {item$url[[1]]}: {conditionMessage(e)}")
    item$excerpt[[1]]
  })
}
