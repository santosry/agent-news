# Agent state -----------------------------------------------------------------
#
# Um estado de agente é um ambiente (referência semântica) que concentra tudo o
# que o agente observou, tentou e produziu durante uma execução. Ele é a base
# da auditoria: cada mutação relevante passa por `agent_state_add_*` e pode ser
# reconstruída a partir de `agent_state_snapshot()`.

agent_run_id <- function(now = Sys.time()) {
  stamp <- format(now, "%Y%m%d-%H%M%S")
  suffix <- substr(openssl::md5(charToRaw(paste0(stamp, Sys.getpid(), runif(1)))), 1, 8)
  paste0("run_", stamp, "_", suffix)
}

new_agent_state <- function(goal, config) {
  env <- new.env(parent = emptyenv())
  env$run_id <- agent_run_id(config$now)
  env$goal <- goal %||% default_agent_goal(config)
  env$status <- "running"
  env$started_at <- config$now
  env$finished_at <- as.POSIXct(NA, tz = config$timezone)

  env$iteration <- 0L
  env$max_iterations <- max(config$max_iterations, 1L)
  env$llm_calls <- 0L

  env$observations <- list()
  env$actions <- list()
  env$results <- list()
  env$decisions <- list()
  env$errors <- list()
  env$events <- list()

  # Domínio do pipeline
  env$items <- empty_news_tbl()
  env$status_tbl <- tibble::tibble()
  env$candidates <- empty_news_tbl()
  env$ranked <- empty_news_tbl() |>
    dplyr::mutate(score = numeric(), topic = character(), justification = character(), canonical_id = character())
  env$selected <- empty_news_tbl() |>
    dplyr::mutate(score = numeric(), topic = character(), justification = character(), canonical_id = character())
  env$summarized <- empty_news_tbl()
  env$article_texts <- list()
  env$evidence <- list()
  env$claims <- list()

  env$html <- NULL
  env$html_path <- NULL
  env$audit <- NULL
  env$report_path <- NULL
  env$send_result <- NULL

  # Marcadores de progresso do plano determinístico (e atalho do evaluator).
  env$collected <- FALSE
  env$deduplicated <- FALSE
  env$ranked_done <- FALSE
  env$summarized_done <- FALSE
  env$report_generated <- FALSE
  env$sent <- FALSE
  env$send_attempted <- FALSE

  # Estratégias de recuperação já tentadas (para replanejamento e abandono).
  env$search_attempted <- FALSE
  env$verify_attempted <- FALSE
  env$recollect_attempted <- FALSE

  # Controle de loop e replanejamento.
  env$last_signature <- NULL
  env$consecutive_repeats <- 0L
  env$replans <- 0L
  env$last_evaluation <- NULL
  env$evaluations <- list()
  env$metrics <- list()
  env$stop_reason <- NULL

  env
}

default_agent_goal <- function(config) {
  paste0(
    "Produzir o clipping semanal de notícias no período ",
    format(config$window_start, "%Y-%m-%d"), " a ",
    format(config$window_end, "%Y-%m-%d"), " (", config$timezone_label, "), ",
    "priorizando saúde pública, ciência, educação e políticas públicas, ",
    "deduplicar, ranquear, selecionar, resumir, gerar o HTML e enviar o relatório."
  )
}

agent_state_add_observation <- function(state, observation) {
  entry <- list(
    iteration = state$iteration,
    at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
    observation = observation
  )
  state$observations[[length(state$observations) + 1L]] <- entry
  invisible(entry)
}

agent_state_add_action <- function(state, action) {
  entry <- list(
    iteration = state$iteration,
    at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
    tool = action$tool %||% NA_character_,
    arguments = action$arguments %||% list(),
    reasoning_summary = action$reasoning_summary %||% NA_character_,
    expected_result = action$expected_result %||% NA_character_
  )
  state$actions[[length(state$actions) + 1L]] <- entry
  invisible(entry)
}

agent_state_add_decision <- function(state, decision) {
  entry <- list(
    iteration = state$iteration,
    at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
    action = decision$action %||% NA_character_,
    arguments = decision$arguments %||% list(),
    reasoning_summary = decision$reasoning_summary %||% NA_character_,
    expected_result = decision$expected_result %||% NA_character_,
    done = isTRUE(decision$done),
    source = decision$source %||% "planner",
    is_replan = isTRUE(decision$is_replan)
  )
  state$decisions[[length(state$decisions) + 1L]] <- entry
  invisible(entry)
}

agent_state_add_result <- function(state, result) {
  entry <- list(
    iteration = state$iteration,
    at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
    tool = result$tool %||% NA_character_,
    ok = isTRUE(result$ok),
    elapsed_sec = result$elapsed_sec %||% NA_real_,
    summary = result$summary %||% NA_character_,
    error = result$error %||% NA_character_
  )
  state$results[[length(state$results) + 1L]] <- entry
  invisible(entry)
}

agent_state_add_error <- function(state, error, context = NA_character_) {
  entry <- list(
    iteration = state$iteration,
    at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
    context = context,
    error = as.character(error)
  )
  state$errors[[length(state$errors) + 1L]] <- entry
  invisible(entry)
}

agent_state_add_event <- function(state, event) {
  entry <- list(
    iteration = state$iteration,
    at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
    event = as.character(event)
  )
  state$events[[length(state$events) + 1L]] <- entry
  invisible(entry)
}

agent_state_set_status <- function(state, status) {
  state$status <- status
  if (identical(status, "finished") || identical(status, "failed")) {
    state$finished_at <- Sys.time()
  }
  invisible(state)
}

# Resumo serializável do estado para o planner e para auditoria.
# Nunca inclui segredos nem cadeia de raciocínio interna do modelo.
agent_state_summary <- function(state) {
  list(
    run_id = state$run_id,
    goal = state$goal,
    status = state$status,
    iteration = state$iteration,
    max_iterations = state$max_iterations,
    llm_calls = state$llm_calls,
    collected = isTRUE(state$collected),
    deduplicated = isTRUE(state$deduplicated),
    ranked = isTRUE(state$ranked_done),
    summarized = isTRUE(state$summarized_done),
    report_generated = isTRUE(state$report_generated),
    sent = isTRUE(state$sent),
    n_items = nrow(state$items),
    n_candidates = nrow(state$candidates),
    n_ranked = nrow(state$ranked),
    n_selected = nrow(state$selected),
    n_summarized = nrow(state$summarized),
    n_errors = length(state$errors),
    n_actions = length(state$actions),
    n_evidence = length(state$evidence),
    n_claims = length(state$claims),
    replans = state$replans,
    search_attempted = isTRUE(state$search_attempted),
    verify_attempted = isTRUE(state$verify_attempted),
    recollect_attempted = isTRUE(state$recollect_attempted),
    conflict_detected = detect_conflict(state),
    last_errors = utils::tail(
      purrr::map_chr(state$errors, function(e) e$error %||% NA_character_),
      3
    ),
    source_status = if (nrow(state$status_tbl) == 0) {
      list()
    } else {
      state$status_tbl |>
        dplyr::select("source", "status", "in_window_count") |>
        as.list()
    }
  )
}

agent_state_snapshot <- function(state) {
  list(
    run_id = state$run_id,
    goal = state$goal,
    status = state$status,
    started_at = format(state$started_at, "%Y-%m-%dT%H:%M:%S%z"),
    finished_at = if (is.na(state$finished_at)) NA_character_ else format(state$finished_at, "%Y-%m-%dT%H:%M:%S%z"),
    iteration = state$iteration,
    max_iterations = state$max_iterations,
    llm_calls = state$llm_calls,
    observations = state$observations,
    actions = state$actions,
    results = state$results,
    decisions = state$decisions,
    errors = state$errors,
    events = state$events,
    evidence = state$evidence,
    claims = state$claims,
    replans = state$replans,
    stop_reason = state$stop_reason %||% NA_character_,
    last_evaluation = state$last_evaluation,
    metrics = state$metrics %||% list(),
    html_path = state$html_path %||% NA_character_,
    audit = state$audit %||% list(),
    report_path = state$report_path %||% NA_character_
  )
}
