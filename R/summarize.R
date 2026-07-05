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

  purrr::map_dfr(seq_len(nrow(selected)), function(i) {
    item <- selected[i, ]

    if (!openai_available(config)) {
      if (!config$dry_run) stop("OPENAI_API_KEY is required outside dry run.", call. = FALSE)
      article_text <- item$excerpt[[1]]
      out <- fallback_summary(item, article_text)
    } else {
      article_text <- fetch_article_text(item)
      out <- summarize_one_with_openai(item, article_text, config)
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

summarize_one_with_openai <- function(item, article_text, config) {
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

  openai_responses_json(
    config = config,
    model = config$summary_model,
    instructions = instructions,
    input = input,
    schema_name = "news_summary",
    schema = summary_schema()
  )
}

fallback_summary <- function(item, article_text) {
  basis <- if (nzchar(article_text)) article_text else item$excerpt[[1]]
  summary <- clean_text(substr(basis, 1, 600))
  if (!nzchar(summary)) summary <- "Resumo indisponível no dry run sem OPENAI_API_KEY."
  list(
    title_final = item$title[[1]],
    topic = item$topic[[1]],
    summary = summary,
    why_matters = item$justification[[1]],
    caveat = "Resumo gerado em dry run sem chamada à OpenAI; consulte a fonte original antes de usar a informação."
  )
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
