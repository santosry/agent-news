ranking_schema <- function() {
  list(
    type = "object",
    additionalProperties = FALSE,
    required = list("items"),
    properties = list(
      items = list(
        type = "array",
        items = list(
          type = "object",
          additionalProperties = FALSE,
          required = list("id", "score", "topic", "justification"),
          properties = list(
            id = list(type = "string"),
            score = list(type = "number", minimum = 0, maximum = 100),
            topic = list(type = "string"),
            justification = list(type = "string")
          )
        )
      )
    )
  )
}

rank_news <- function(items, config) {
  if (nrow(items) == 0) {
    return(items |>
      dplyr::mutate(score = numeric(), topic = character(), justification = character()))
  }

  if (!deepseek_available(config)) {
    if (!config$dry_run && !isTRUE(config$allow_no_deepseek)) {
      stop("DEEPSEEK_API_KEY is required outside dry run unless ALLOW_NO_DEEPSEEK=true.", call. = FALSE)
    }
    log_warn("DEEPSEEK_API_KEY missing. Using deterministic heuristic ranking.")
    return(heuristic_rank(items))
  }

  log_info("Sending {nrow(items)} candidates to DeepSeek ranking.")
  chunks <- split(items, ceiling(seq_len(nrow(items)) / 40))
  ranked <- purrr::map_dfr(chunks, function(chunk) {
    payload <- chunk |>
      dplyr::transmute(
        id = .data$id,
        source = .data$source,
        published_at = format(.data$published_at, "%Y-%m-%d %H:%M:%S %Z"),
        title = .data$title,
        excerpt = .data$excerpt
      )

    instructions <- paste(
      "You are an editorial relevance scorer for a weekly intelligence clipping.",
      "Score only the facts presented in the supplied title and excerpt.",
      "Do not invent facts. Do not change the source.",
      "Prioritize: public health, epidemiology, nursing, SUS, hospitals, vaccination, disease outbreaks, science, research, public policy, public management, education, higher education, basic education, professional education, fiscal policy, infrastructure, environment, climate, pollution, public-impact technology, AI, Rio de Janeiro, Campos dos Goytacazes, and Norte Fluminense.",
      "For J3News and Folha1, give high weight to Campos dos Goytacazes, Norte Fluminense, local administration, health, infrastructure, regional economy, and municipal policy.",
      "For IFF and UENF, give high weight to research, science, innovation, extension, graduate programs, academic opportunities, institutional decisions, public education, technology transfer, health, environment, and regional development.",
      "For MEC, give high weight to educational policy, basic and higher education programs, PNE, ENEM, FIES, PROUNI, teacher training, educational inclusion, and school infrastructure.",
      "For Ministério da Saúde, give high weight to SUS, public health policy, vaccination, disease control, primary care, specialized care, health surveillance, health funding, and health workforce.",
      "For Cofen and Coren-RJ, give high weight to nursing, professional regulation, ethical guidelines, public health nursing, health workforce policy, and professional training.",
      "For BBC News and CNN Brasil, prioritize national and international facts with broad population, scientific, political, economic, environmental, or institutional impact.",
      "Strongly penalize gossip, celebrities, reality shows, astrology, routine sports, promotional content, and clickbait unless there is extraordinary public impact.",
      sep = "\n"
    )

    input <- paste(
      "Return a JSON object matching the schema. Score each item from 0 to 100.",
      jsonlite::toJSON(payload, dataframe = "rows", auto_unbox = TRUE),
      sep = "\n\n"
    )

    result <- deepseek_chat_completions(
      config = config,
      model = config$rank_model,
      system_prompt = instructions,
      user_prompt = input,
      schema_name = "news_ranking",
      schema = ranking_schema()
    )

    out <- dplyr::bind_rows(result$items)
    validate_ranking_output(out, chunk)
  })

  items |>
    dplyr::left_join(ranked, by = "id") |>
    dplyr::mutate(
      score = pmax(0, pmin(100, as.numeric(.data$score))),
      topic = clean_text(.data$topic),
      justification = clean_text(.data$justification)
    )
}

validate_ranking_output <- function(out, input_items) {
  required <- c("id", "score", "topic", "justification")
  if (!all(required %in% names(out))) {
    stop("DeepSeek ranking schema missing fields.", call. = FALSE)
  }
  if (!all(out$id %in% input_items$id)) {
    stop("DeepSeek ranking returned unknown ids.", call. = FALSE)
  }
  out |>
    dplyr::transmute(
      id = .data$id,
      score = as.numeric(.data$score),
      topic = as.character(.data$topic),
      justification = as.character(.data$justification)
    )
}

heuristic_rank <- function(items) {
  priority_terms <- c(
    "saude", "sus", "epidemia", "epidemiologia", "vacina", "ciencia", "pesquisa", "clima", "ambiente",
    "poluicao", "infraestrutura", "economia", "economico", "fiscal", "governo", "prefeitura", "campos",
    "goytacazes", "norte fluminense", "rio de janeiro", "inteligencia artificial",
    "tecnologia", "politica", "gestao", "iff", "iffluminense", "uenf", "universidade",
    "instituto federal", "educacao", "ensino", "extensao", "pos graduacao", "mestrado",
    "doutorado", "iniciacao cientifica", "inovacao", "laboratorio", "bolsa", "edital",
    "monitoria", "prograd", "proppg", "proex", "campus", "academia", "health", "public health", "science",
    "research", "scientist", "epidemiology", "vaccine", "climate", "heatwave",
    "environment", "pollution", "economy", "economic", "fiscal", "government",
    "policy", "infrastructure", "artificial intelligence", "technology", "deaths",
    "excess deaths", "hospital", "disease", "emissions",
    "enfermagem", "enfermeiro", "nursing", "nurse", "coren", "cofen",
    "ideb", "enem", "fies", "prouni", "pne", "educacao basica", "ensino medio",
    "ensino superior", "formacao docente", "educacao inclusiva", "ensino profissional",
    "atencao primaria", "vigilancia", "saude mental", "saude indigena"
  )
  penalty_terms <- c(
    "celebridade", "bbb", "reality", "horoscopo", "famos", "futebol", "copa",
    "show", "serie c", "carioca", "quartas", "estadio", "partida", "celebrity",
    "taylor swift", "wedding", "football", "premier league"
  )

  text <- normalize_title(paste(items$title, items$excerpt))
  score <- rep(35, length(text))
  for (term in priority_terms) score <- score + ifelse(has_normalized_term(text, term), 8, 0)
  for (term in penalty_terms) score <- score - ifelse(has_normalized_term(text, term), 18, 0)
  score <- score + ifelse(items$source %in% c("IFF", "UENF"), 8, 0)
  score <- pmax(0, pmin(100, score))

  items |>
    dplyr::mutate(
      score = score,
      topic = dplyr::case_when(
        has_any_normalized_term(text, c("saude", "sus", "epidemia", "epidemiologia", "vacina", "health", "public health", "vaccine", "hospital", "disease")) ~ "saúde pública",
        has_any_normalized_term(text, c("economia", "economico", "fiscal", "mercado", "economy", "economic")) ~ "economia",
        has_any_normalized_term(text, c("clima", "ambiente", "poluicao", "climate", "heatwave", "environment", "pollution", "emissions")) ~ "meio ambiente",
        items$source %in% c("IFF", "UENF") | has_any_normalized_term(text, c("universidade", "instituto federal", "educacao", "ensino", "pesquisa", "extensao", "inovacao", "mestrado", "doutorado", "campus")) ~ "academia e instituições públicas",
        has_any_normalized_term(text, c("campos", "goytacazes", "norte fluminense")) ~ "Campos/Norte Fluminense",
        TRUE ~ "interesse público"
      ),
      justification = heuristic_justification(.data$source, .data$topic, text)
    )
}

heuristic_justification <- function(source, topic, text) {
  purrr::pmap_chr(
    list(source = source, topic = topic, text = text),
    function(source, topic, text) {
      if (source %in% c("IFF", "UENF")) {
        if (has_any_normalized_term(text, c("pesquisa", "inovacao", "metodologia", "laboratorio", "science", "research"))) {
          return("Acompanha produção científica e tecnológica regional, com potencial de gerar parcerias, agendas de pesquisa e oportunidades acadêmicas.")
        }
        if (has_any_normalized_term(text, c("edital", "inscricao", "vaga", "monitoria", "bolsa", "mestrado", "doutorado", "concurso"))) {
          return("Reúne prazos e oportunidades acadêmicas que podem afetar estudantes, docentes, técnicos e grupos de pesquisa.")
        }
        return("Ajuda a acompanhar decisões e movimentos institucionais de uma fonte acadêmica estratégica para o Norte Fluminense.")
      }
      if (identical(topic, "saúde pública")) {
        return("Tem relevância sanitária porque pode afetar acesso a serviços, prevenção, risco populacional ou organização da rede de saúde.")
      }
      if (identical(topic, "economia")) {
        return("Ajuda a interpretar emprego, atividade econômica, arrecadação, investimentos ou decisões que afetam a região e o setor público.")
      }
      if (identical(topic, "meio ambiente")) {
        return("Tem interesse público por envolver risco ambiental, clima, energia, território ou impactos sobre saúde e infraestrutura.")
      }
      if (identical(topic, "Campos/Norte Fluminense")) {
        return("É relevante para acompanhar decisões, eventos e serviços com efeito direto em Campos dos Goytacazes e no Norte Fluminense.")
      }
      "Entra no radar por ter potencial de afetar decisões públicas, institucionais ou acadêmicas na semana."
    }
  )
}

has_normalized_term <- function(text, term) {
  term_norm <- normalize_title(term)
  if (!nzchar(term_norm)) return(rep(FALSE, length(text)))
  pattern <- paste0("(^| )", stringr::str_replace_all(term_norm, " ", " +"), "( |$)")
  stringr::str_detect(text, pattern)
}

has_any_normalized_term <- function(text, terms) {
  hits <- rep(FALSE, length(text))
  for (term in terms) hits <- hits | has_normalized_term(text, term)
  hits
}

select_for_clipping <- function(ranked, config) {
  if (nrow(ranked) == 0) return(ranked)

  valid <- ranked |>
    dplyr::filter(
      is.na(.data$discard_reason) | .data$discard_reason == "",
      !is.na(.data$score)
    ) |>
    dplyr::arrange(dplyr::desc(.data$score), dplyr::desc(.data$published_at))

  min_news_per_source <- min(config$min_news_per_source %||% 5L, config$news_per_source)

  # Phase 1: guarantee min_news_per_source from EVERY source (by best score, no threshold)
  protected <- valid |>
    dplyr::group_by(.data$source) |>
    dplyr::arrange(dplyr::desc(.data$score), dplyr::desc(.data$published_at), .by_group = TRUE) |>
    dplyr::slice_head(n = min_news_per_source) |>
    dplyr::ungroup()

  # Cap at max_selected
  if (nrow(protected) >= config$max_selected) {
    return(protected |>
      dplyr::arrange(dplyr::desc(.data$score), dplyr::desc(.data$published_at)) |>
      utils::head(config$max_selected))
  }

  fill_slots <- config$max_selected - nrow(protected)
  protected_counts <- protected |>
    dplyr::count(.data$source, name = "protected_n")

  # Phase 2: fill remaining slots with items >= min_score, respecting per-source cap (news_per_source)
  fill <- valid |>
    dplyr::filter(
      .data$score >= config$min_score,
      !.data$id %in% protected$id
    ) |>
    dplyr::left_join(protected_counts, by = "source") |>
    dplyr::mutate(remaining_source_slots = pmax(config$news_per_source - tidyr::replace_na(.data$protected_n, 0L), 0L)) |>
    dplyr::group_by(.data$source) |>
    dplyr::arrange(dplyr::desc(.data$score), dplyr::desc(.data$published_at), .by_group = TRUE) |>
    dplyr::filter(dplyr::row_number() <= dplyr::first(.data$remaining_source_slots)) |>
    dplyr::ungroup() |>
    dplyr::select(-dplyr::any_of(c("protected_n", "remaining_source_slots"))) |>
    dplyr::arrange(dplyr::desc(.data$score), dplyr::desc(.data$published_at)) |>
    utils::head(fill_slots)

  dplyr::bind_rows(protected, fill) |>
    dplyr::distinct(.data$id, .keep_all = TRUE) |>
    dplyr::arrange(dplyr::desc(.data$score), dplyr::desc(.data$published_at))
}

top_three <- function(selected) {
  selected |>
    dplyr::arrange(dplyr::desc(.data$score), dplyr::desc(.data$published_at)) |>
    utils::head(3)
}
