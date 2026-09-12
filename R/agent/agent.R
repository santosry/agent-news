# Agente -----------------------------------------------------------------------
#
# Loop controlado: observar -> planejar -> executar -> avaliar -> memorizar.
#
#   run_agent(goal = NULL, config = load_config())
#
# O agente decide, por meio do planner (DeepSeek) ou de um plano determinístico
# padrão, qual ferramenta executar a seguir. As ferramentas são executadas pelo
# executor (allowlist estrita); o evaluator decide se há evidência suficiente e
# se o objetivo foi alcançado; a memória persiste o que foi processado.

run_agent <- function(goal = NULL, config = load_config(), registry = tool_registry()) {
  memory <- memory_open(config)
  state <- new_agent_state(goal, config)
  run_started <- Sys.time()

  log_info("Agent run {state$run_id} started. mode={config$mode}; dry_run={config$dry_run}; test_mode={config$test_mode}")
  log_info("Agent recipients (send list): {paste(config$send_recipients, collapse = ', ')}")

  finished <- FALSE
  outcome <- "running"
  evaluation <- NULL

  on.exit({
    if (identical(state$status, "running")) {
      agent_state_set_status(state, "failed")
    }
    if (is.null(state$metrics) || length(state$metrics) == 0) {
      state$metrics <- compute_agent_metrics(state, config, outcome, as.numeric(difftime(Sys.time(), run_started, units = "secs")))
    }
    memory <- record_agent_run_memory(memory, state, config)
    memory_save(memory, config)
  }, add = TRUE)

  while (!finished) {
    if (state$iteration >= state$max_iterations) {
      agent_state_add_error(state, paste0("max_iterations (", state$max_iterations, ") reached without completing the goal."), context = "loop")
      outcome <- "iteration_limit"
      break
    }

    state$iteration <- state$iteration + 1L
    agent_state_add_observation(state, agent_state_summary(state))

    plan <- plan_next_action(state, config, registry, memory, evaluation)
    action <- plan$action
    decision <- plan$decision
    is_replan <- isTRUE(plan$is_replan)
    if (is_replan) state$replans <- state$replans + 1L

    agent_state_add_decision(state, if (is.null(decision)) {
      list(
        action = action$tool,
        arguments = action$arguments,
        reasoning_summary = action$reasoning_summary,
        expected_result = action$expected_result,
        done = isTRUE(action$done),
        source = plan$source %||% "adaptive",
        is_replan = is_replan
      )
    } else {
      c(decision, list(source = plan$source %||% "planner", is_replan = is_replan))
    })
    agent_state_add_action(state, action)

    result <- execute_action(action, state, config, registry, memory)
    agent_state_add_result(state, result)

    if (!isTRUE(result$ok)) {
      agent_state_add_error(state, result$error %||% "tool execution failed", context = action$tool)
      log_warn("Agent action '{action$tool}' failed: {result$error %||% 'unknown error'}")
    } else {
      log_info("Agent action '{action$tool}' -> {result$summary %||% 'ok'}")
    }

    # Detecção de loop improdutivo: mesma ferramenta + mesmos argumentos consecutivamente.
    sig <- action_signature(action)
    if (!is.null(state$last_signature) && identical(state$last_signature, sig)) {
      state$consecutive_repeats <- state$consecutive_repeats + 1L
    } else {
      state$last_signature <- sig
      state$consecutive_repeats <- 1L
    }

    evaluation <- evaluate_result(state, action, result, config)
    if (state$consecutive_repeats > config$max_repeated_action) {
      evaluation$strategy_exhausted <- TRUE
      evaluation$stop_reason <- "loop_detected"
      agent_state_add_error(state, paste0("Loop detected: repeated action '", sig, "' ", state$consecutive_repeats, " times."), context = "loop")
    }

    state$last_evaluation <- evaluation
    state$evaluations[[state$iteration]] <- evaluation

    agent_state_add_event(state, sprintf(
      "action=%s ok=%s confidence=%.2f evidence=%s completed=%s replan=%s",
      action$tool, result$ok, evaluation$confidence, evaluation$evidence_quality, evaluation$completed, is_replan
    ))

    if (isTRUE(evaluation$strategy_exhausted)) {
      outcome <- "loop_detected"
      finished <- TRUE
    } else if (identical(action$tool, "finalize")) {
      outcome <- if (identical(evaluation$stop_reason, "goal_achieved")) {
        "finalized"
      } else if (identical(evaluation$stop_reason, "loop_detected")) {
        "loop_detected"
      } else {
        "failed"
      }
      finished <- TRUE
    } else if (isTRUE(evaluation$completed)) {
      outcome <- if (identical(evaluation$stop_reason, "goal_achieved")) {
        "completed"
      } else if (identical(evaluation$stop_reason, "loop_detected")) {
        "loop_detected"
      } else {
        "failed"
      }
      finished <- TRUE
    }
  }

  state$stop_reason <- outcome
  agent_state_set_status(state, if (outcome %in% c("completed", "finalized")) "finished" else "failed")
  state$metrics <- compute_agent_metrics(state, config, outcome, as.numeric(difftime(Sys.time(), run_started, units = "secs")))

  ok <- outcome %in% c("completed", "finalized")
  message <- agent_result_message(state, config, ok, outcome)

  list(
    ok = ok,
    message = message,
    status = state$status_tbl,
    selected = state$summarized,
    html_path = state$html_path %||% NULL,
    audit_path = state$audit$csv_path %||% NULL,
    audit_json_path = state$audit$json_path %||% NULL,
    report_path = state$report_path %||% NULL,
    send_result = state$send_result %||% NULL,
    agent_run_id = state$run_id,
    iterations = state$iteration,
    max_iterations = state$max_iterations,
    mode = config$mode,
    dry_run = config$dry_run,
    test_mode = config$test_mode,
    outcome = outcome,
    metrics = state$metrics,
    trajectory = agent_trajectory(state),
    agent_audit_path = write_agent_audit(state, config)
  )
}

agent_result_message <- function(state, config, ok, outcome) {
  if (identical(outcome, "iteration_limit")) {
    return(sprintf(
      "Agent stopped: iteration limit (%d) reached before the goal was completed. %d error(s) recorded.",
      state$max_iterations, length(state$errors)
    ))
  }

  if (identical(outcome, "loop_detected")) {
    return("Agent stopped: unproductive loop detected (repeated action without new information).")
  }

  if (isTRUE(config$dry_run)) {
    return(if (ok) "Agent dry run completed without sending email." else "Agent dry run failed.")
  }

  if (isTRUE(config$test_mode)) {
    return(if (ok) {
      sprintf("Agent test run completed; email sent only to test recipient (%s).", paste(config$send_recipients, collapse = ", "))
    } else {
      "Agent test run failed."
    })
  }

  if (ok) {
    return("Weekly clipping sent.")
  }

  if (length(state$errors) > 0) {
    return(sprintf("Agent failed: %s", state$errors[[length(state$errors)]]$error))
  }
  sprintf("Agent stopped without completing the goal (outcome: %s).", outcome %||% "failed")
}

# Registra uma execução inteira na memória persistente (uma única gravação ao
# final, reconstruída a partir do estado auditável).
record_agent_run_memory <- function(memory, state, config) {
  metrics <- state$metrics %||% list()
  memory <- memory_append(memory, "agent_runs", list(
    run_id = state$run_id,
    goal = state$goal,
    status = state$status,
    outcome = state$stop_reason %||% NA_character_,
    started_at = format(state$started_at, "%Y-%m-%dT%H:%M:%S%z"),
    finished_at = if (is.na(state$finished_at)) NA_character_ else format(state$finished_at, "%Y-%m-%dT%H:%M:%S%z"),
    iteration = state$iteration,
    max_iterations = state$max_iterations,
    mode = config$mode,
    dry_run = config$dry_run,
    test_mode = config$test_mode,
    n_errors = length(state$errors),
    n_replans = state$replans,
    n_verifications = metrics$n_verifications %||% 0L,
    n_searches = metrics$n_searches %||% 0L,
    n_failures_recovered = metrics$n_failures_recovered %||% 0L,
    n_loops_stopped = metrics$n_loops_stopped %||% 0L,
    stop_success = metrics$stop_success %||% NA,
    final_confidence = metrics$final_confidence %||% NA_real_
  ))

  for (i in seq_along(state$actions)) {
    action <- state$actions[[i]]
    result <- if (i <= length(state$results)) state$results[[i]] else list()
    memory <- memory_append(memory, "agent_actions", list(
      run_id = state$run_id,
      iteration = action$iteration,
      tool = action$tool,
      arguments = jsonlite::toJSON(action$arguments, auto_unbox = TRUE, null = "null"),
      reasoning_summary = action$reasoning_summary,
      expected_result = action$expected_result,
      ok = isTRUE(result$ok),
      error = result$error %||% NA_character_,
      elapsed_sec = result$elapsed_sec %||% NA_real_
    ))
  }

  for (decision in state$decisions) {
    memory <- memory_append(memory, "agent_decisions", list(
      run_id = state$run_id,
      iteration = decision$iteration,
      action = decision$action,
      reasoning_summary = decision$reasoning_summary,
      expected_result = decision$expected_result,
      done = isTRUE(decision$done),
      source = decision$source %||% NA_character_,
      is_replan = isTRUE(decision$is_replan)
    ))
  }

  if (nrow(state$status_tbl) > 0) {
    for (i in seq_len(nrow(state$status_tbl))) {
      row <- state$status_tbl[i, ]
      memory <- memory_append(memory, "sources", as.list(row) |> c(list(run_id = state$run_id)))
    }
  }

  audit_items <- if (nrow(state$items) > 0) build_audit_items(state$items, state$ranked) else state$items
  if (nrow(audit_items) > 0) {
    selected_ids <- state$summarized$id %||% character()
    for (i in seq_len(nrow(audit_items))) {
      row <- audit_items[i, ]
      memory <- memory_append(memory, "articles", list(
        run_id = state$run_id,
        id = row$id,
        source = row$source,
        title = row$title,
        url = row$url,
        published_at = if ("published_at" %in% names(row)) format(row$published_at, "%Y-%m-%dT%H:%M:%S%z") else NA_character_,
        score = row$score %||% NA_real_,
        topic = row$topic %||% NA_character_,
        selected = row$id %in% selected_ids,
        content_hash = md5_hex(paste0(row$url, "|", row$title))
      ))
    }
  }

  for (ev in state$evidence) {
    memory <- memory_append(memory, "evidence", c(list(run_id = state$run_id), ev))
  }
  for (cl in state$claims) {
    memory <- memory_append(memory, "claims", c(list(run_id = state$run_id), cl))
  }
  for (ev in state$events) {
    memory <- memory_append(memory, "events", c(list(run_id = state$run_id), ev))
  }

  memory
}

write_agent_audit <- function(state, config) {
  dir.create(config$output_dir, showWarnings = FALSE, recursive = TRUE)
  path <- file.path(config$output_dir, paste0("agent-run-", state$run_id, ".json"))
  jsonlite::write_json(agent_state_snapshot(state), path, pretty = TRUE, auto_unbox = TRUE, null = "null")
  normalizePath(path, winslash = "/", mustWork = FALSE)
}
