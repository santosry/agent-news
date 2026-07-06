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

  if (!openai_available(config)) {
    if (!config$dry_run && !isTRUE(config$allow_no_openai)) {
      stop("OPENAI_API_KEY is required outside dry run unless ALLOW_NO_OPENAI=true.", call. = FALSE)
    }
    log_warn("OPENAI_API_KEY missing. Using deterministic heuristic ranking.")
    return(heuristic_rank(items))
  }

  log_info("Sending {nrow(items)} candidates to OpenAI ranking.")
  chunks <- split(items, ceiling(seq_len(nrow(items)) / 30))
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
      "Prioritize public health, science, epidemiology, public policy, public management, SUS, economy, fiscal policy, infrastructure, environment, climate, air pollution, public-impact technology, AI, Rio de Janeiro, Campos dos Goytacazes, and Norte Fluminense.",
      "For J3News and Folha1, give high weight to Campos dos Goytacazes, Norte Fluminense, local administration, health, infrastructure, regional economy, and municipal policy.",
      "For BBC News and CNN Brasil, prioritize national and international facts with broad population, scientific, political, economic, environmental, or institutional impact.",
      "Strongly penalize gossip, celebrities, reality shows, astrology, routine sports, promotional content, and clickbait unless there is extraordinary public impact.",
      sep = "\n"
    )

    input <- paste(
      "Return a JSON object matching the schema. Score each item from 0 to 100.",
      jsonlite::toJSON(payload, dataframe = "rows", auto_unbox = TRUE),
      sep = "\n\n"
    )

    result <- openai_responses_json(
      config = config,
      model = config$rank_model,
      instructions = instructions,
      input = input,
      schema_name = "news_ranking",
      schema = ranking_schema()
    )

    out <- tibble::as_tibble(result$items)
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
    stop("OpenAI ranking schema missing fields.", call. = FALSE)
  }
  if (!all(out$id %in% input_items$id)) {
    stop("OpenAI ranking returned unknown ids.", call. = FALSE)
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
    "tecnologia", "politica", "gestao", "health", "public health", "science",
    "research", "scientist", "epidemiology", "vaccine", "climate", "heatwave",
    "environment", "pollution", "economy", "economic", "fiscal", "government",
    "policy", "infrastructure", "artificial intelligence", "technology", "deaths",
    "excess deaths", "hospital", "disease", "emissions"
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
  score <- pmax(0, pmin(100, score))

  items |>
    dplyr::mutate(
      score = score,
      topic = dplyr::case_when(
        has_any_normalized_term(text, c("saude", "sus", "epidemia", "epidemiologia", "vacina", "health", "public health", "vaccine", "hospital", "disease")) ~ "saúde pública",
        has_any_normalized_term(text, c("economia", "economico", "fiscal", "mercado", "economy", "economic")) ~ "economia",
        has_any_normalized_term(text, c("clima", "ambiente", "poluicao", "climate", "heatwave", "environment", "pollution", "emissions")) ~ "meio ambiente",
        has_any_normalized_term(text, c("campos", "goytacazes", "norte fluminense")) ~ "Campos/Norte Fluminense",
        TRUE ~ "interesse público"
      ),
      justification = "Ranking heurístico determinístico usado sem OPENAI_API_KEY."
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

  source_min_score <- config$source_min_score %||% min(config$min_score, 40)
  min_news_per_source <- min(config$min_news_per_source %||% 1L, config$news_per_source)

  protected <- valid |>
    dplyr::filter(.data$score >= source_min_score) |>
    dplyr::group_by(.data$source) |>
    dplyr::arrange(dplyr::desc(.data$score), dplyr::desc(.data$published_at), .by_group = TRUE) |>
    dplyr::slice_head(n = min_news_per_source) |>
    dplyr::ungroup()

  fill_slots <- max(config$max_selected - nrow(protected), 0L)
  if (fill_slots == 0L) {
    return(protected |>
      dplyr::arrange(dplyr::desc(.data$score), dplyr::desc(.data$published_at)) |>
      utils::head(config$max_selected))
  }

  protected_counts <- protected |>
    dplyr::count(.data$source, name = "protected_n")

  fill <- valid |>
    dplyr::filter(.data$score >= config$min_score, !.data$id %in% protected$id) |>
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
