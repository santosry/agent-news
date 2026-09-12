# Evaluator --------------------------------------------------------------------
#
# Camada independente de avaliação que CONTROLA a trajetória. Não apenas registra
# métricas: devolve sinais acionáveis (insufficient, conflict_detected,
# needs_verification, needs_more_evidence, produced_new_info, completed) que o
# planner usa para escolher a próxima ação.
#
# O agente NÃO assume sucesso só porque uma função retornou sem erro.

count_usable <- function(items) {
  if (is.null(items) || nrow(items) == 0) return(0L)
  sum(is.na(items$discard_reason) | items$discard_reason == "")
}

detect_conflict <- function(state) {
  if (length(state$claims) == 0) return(FALSE)
  any(vapply(state$claims, function(cl) {
    !is.null(cl$status) && cl$status %in% c("conflicting", "unsupported")
  }, logical(1)))
}

assess_evidence <- function(state, config) {
  quality <- "none"
  gaps <- character()

  n_selected <- nrow(state$selected)
  n_summarized <- nrow(state$summarized)
  n_evidence <- length(state$evidence)

  if (n_selected == 0 && n_summarized == 0) {
    quality <- "none"
    gaps <- c(gaps, "no_items_selected")
  } else if (n_summarized > 0) {
    quality <- "standard"
    if (n_evidence == 0) {
      gaps <- c(gaps, "selected_items_not_verified")
    } else if (n_evidence < n_summarized) {
      quality <- "partial"
      gaps <- c(gaps, "some_items_lack_verification")
    } else {
      quality <- "high"
    }
  }

  if (nrow(state$status_tbl) > 0) {
    failed <- state$status_tbl |>
      dplyr::filter(.data$status == "failed") |>
      dplyr::pull(.data$source)
    if (length(failed) > 0) {
      gaps <- c(gaps, paste0("failed_sources:", paste(failed, collapse = ",")))
    }
  }

  list(quality = quality, gaps = unique(gaps))
}

confidence_score <- function(state, evidence_quality, action_ok) {
  base <- 0.5

  if (isTRUE(action_ok)) base <- base + 0.1
  if (isTRUE(state$collected)) base <- base + 0.1
  if (isTRUE(state$ranked_done)) base <- base + 0.05
  if (isTRUE(state$summarized_done)) base <- base + 0.1
  if (isTRUE(state$report_generated)) base <- base + 0.15

  base <- base + switch(
    evidence_quality,
    high = 0.15,
    partial = 0.05,
    standard = 0.02,
    none = -0.1
  )

  base <- base - min(0.2, length(state$errors) * 0.05)
  base <- base - if (detect_conflict(state)) 0.15 else 0

  pmax(0, pmin(1, base))
}

evaluate_result <- function(state, action, result, config) {
  ok <- isTRUE(result$ok)
  tool <- action$tool %||% "finalize"

  reasons <- character()

  if (!ok) {
    reasons <- c(reasons, paste0("tool_failed:", tool))
  }

  conflict <- detect_conflict(state)
  evidence <- assess_evidence(state, config)
  confidence <- confidence_score(state, evidence$quality, ok)

  goal_min <- max(config$min_articles_goal %||% 5L, 1L)
  usable <- count_usable(state$items)

  insufficient <- FALSE
  produced_new_info <- FALSE

  if (ok && identical(tool, "collect_news")) {
    if (nrow(state$status_tbl) > 0 && !any_source_collected(state$status_tbl)) {
      reasons <- c(reasons, "no_usable_source_collected")
    } else if (usable < goal_min) {
      insufficient <- TRUE
      reasons <- c(reasons, "insufficient_items_after_collect")
    }
  }

  if (ok && identical(tool, "search_news")) {
    n <- as.integer(result$result$n %||% 0L)
    produced_new_info <- n > 0L
    if (!produced_new_info) {
      reasons <- c(reasons, "search_returned_no_new_information")
    }
  }

  if (ok && identical(tool, "verify_source")) {
    res <- result$result
    if (!is.null(res$evidence_quality) && identical(res$evidence_quality, "low")) {
      reasons <- c(reasons, "low_evidence_quality_source")
    }
  }

  if (ok && identical(tool, "deduplicate_news")) {
    if (nrow(state$candidates) < goal_min) {
      insufficient <- TRUE
      reasons <- c(reasons, "insufficient_articles_after_dedup")
    }
  }

  if (ok && identical(tool, "rank_news")) {
    if (nrow(state$candidates) > 0 && nrow(state$selected) < goal_min) {
      insufficient <- TRUE
      reasons <- c(reasons, "insufficient_selected_articles")
    }
  }

  needs_verification <- conflict || (evidence$quality %in% c("none", "low") && nrow(state$selected) > 0)
  needs_more_evidence <- insufficient || evidence$quality %in% c("none", "low")

  # Completude: objetivo alcançado (relatório gerado E envio resolvido).
  # Em dry_run o envio é tentado (no-op) apenas para gravar o relatório de run.
  goal_achieved <- isTRUE(state$report_generated) &&
    isTRUE(state$send_attempted) &&
    (isTRUE(config$dry_run) || isTRUE(state$send_result$any_success))

  # Falha de envio explícita (não dry-run).
  send_failed <- isTRUE(state$send_attempted) &&
    !isTRUE(config$dry_run) &&
    !isTRUE(state$send_result$any_success)

  completed <- goal_achieved || send_failed

  if (send_failed) {
    reasons <- c(reasons, "email_delivery_failed")
  }
  if (goal_achieved) {
    reasons <- c(reasons, "goal_achieved")
  }

  # Coleta totalmente falhou: encerrar explicitamente.
  if (isTRUE(state$collected) && (nrow(state$status_tbl) == 0 || !any_source_collected(state$status_tbl))) {
    completed <- TRUE
    reasons <- c(reasons, "critical_collection_failure")
  }

  # Decisão terminal do planner (finalize): reconhece o encerramento controlado
  # (ex.: insuficiência de informação, nenhuma ação útil restante) sem fingir
  # sucesso. O motivo fica em stop_reason e na trajetória auditável.
  if (identical(tool, "finalize") && !completed) {
    completed <- TRUE
    reasons <- c(reasons, "planner_requested_finalize")
  }

  stop_reason <- if (completed) {
    if (goal_achieved) "goal_achieved"
    else if (send_failed) "email_delivery_failed"
    else if (identical(tool, "finalize")) (action$reasoning_summary %||% "planner_finalized")
    else "critical_collection_failure"
  } else {
    NA_character_
  }

  list(
    ok = ok,
    tool = tool,
    completed = completed,
    continue = !completed && state$iteration < state$max_iterations,
    confidence = confidence,
    relevance = if (isTRUE(state$ranked_done) && nrow(state$ranked) > 0) {
      mean(as.numeric(state$ranked$score), na.rm = TRUE)
    } else {
      NA_real_
    },
    evidence_quality = evidence$quality,
    gaps = evidence$gaps,
    reasons = unique(reasons),
    insufficient = insufficient,
    conflict_detected = conflict,
    needs_verification = needs_verification,
    needs_more_evidence = needs_more_evidence,
    produced_new_info = produced_new_info,
    strategy_exhausted = FALSE,
    stop_reason = stop_reason
  )
}
