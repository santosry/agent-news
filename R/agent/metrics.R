# Métricas de autonomia computacional ------------------------------------------
#
# Camada simples e mensurável para avaliar trajetórias. Não inventa métricas
# sofisticadas: começa com contagens e sinais observáveis no estado auditável.

agent_trajectory <- function(state) {
  n <- length(state$actions)
  if (n == 0) {
    return(tibble::tibble(
      iteration = integer(), tool = character(), arguments = character(),
      ok = logical(), reasoning_summary = character(), source = character(),
      is_replan = logical(), confidence = numeric(), evidence_quality = character(),
      completed = logical()
    ))
  }

  get_ev <- function(i, field) {
    ev <- state$evaluations[[i]]
    if (is.null(ev)) return(NA)
    ev[[field]]
  }

  tibble::tibble(
    iteration = vapply(state$actions, function(a) a$iteration %||% NA_integer_, integer(1)),
    tool = vapply(state$actions, function(a) a$tool %||% NA_character_, character(1)),
    arguments = vapply(state$actions, function(a) {
      jsonlite::toJSON(a$arguments %||% list(), auto_unbox = TRUE, null = "null")
    }, character(1)),
    ok = vapply(seq_len(n), function(i) {
      if (i <= length(state$results)) isTRUE(state$results[[i]]$ok) else NA
    }, logical(1)),
    reasoning_summary = vapply(state$actions, function(a) a$reasoning_summary %||% NA_character_, character(1)),
    source = vapply(seq_len(n), function(i) {
      if (i <= length(state$decisions)) state$decisions[[i]]$source %||% NA_character_ else NA_character_
    }, character(1)),
    is_replan = vapply(seq_len(n), function(i) {
      if (i <= length(state$decisions)) isTRUE(state$decisions[[i]]$is_replan) else NA
    }, logical(1)),
    confidence = vapply(seq_len(n), function(i) as.numeric(get_ev(i, "confidence") %||% NA_real_), numeric(1)),
    evidence_quality = vapply(seq_len(n), function(i) as.character(get_ev(i, "evidence_quality") %||% NA_character_), character(1)),
    completed = vapply(seq_len(n), function(i) isTRUE(get_ev(i, "completed")), logical(1))
  )
}

compute_agent_metrics <- function(state, config, outcome, elapsed_sec = NA_real_) {
  tools <- vapply(state$actions, function(a) a$tool %||% NA_character_, character(1))
  n_actions <- length(tools)
  n_errors <- length(state$errors)

  n_failures_recovered <- 0L
  if (n_actions > 1) {
    oks <- vapply(seq_len(n_actions), function(i) {
      if (i <= length(state$results)) isTRUE(state$results[[i]]$ok) else FALSE
    }, logical(1))
    for (i in seq_len(max(0L, n_actions - 1L))) {
      if (!oks[[i]] && oks[[i + 1L]]) n_failures_recovered <- n_failures_recovered + 1L
    }
  }

  repeated <- 0L
  if (n_actions > 1) {
    sigs <- vapply(state$actions, function(a) action_signature(a), character(1))
    repeated <- sum(sigs[-1L] == sigs[-length(sigs)])
  }

  list(
    agent_run_id = state$run_id,
    iterations = state$iteration,
    n_actions = n_actions,
    distinct_tools = length(unique(tools)),
    n_replans = state$replans %||% 0L,
    repeat_rate = if (n_actions > 0) repeated / n_actions else 0,
    n_verifications = sum(tools == "verify_source"),
    n_searches = sum(tools == "search_news"),
    n_failures_recovered = n_failures_recovered,
    n_errors = n_errors,
    n_loops_stopped = if (identical(outcome, "loop_detected")) 1L else 0L,
    stop_success = identical(outcome, "completed") || identical(outcome, "finalized"),
    final_confidence = state$last_evaluation$confidence %||% NA_real_,
    final_evidence_quality = state$last_evaluation$evidence_quality %||% NA_character_,
    goal_achieved = isTRUE(state$last_evaluation$completed) &&
      identical(state$last_evaluation$stop_reason, "goal_achieved"),
    elapsed_sec = elapsed_sec,
    llm_calls = state$llm_calls
  )
}
