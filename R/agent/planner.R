# Planner ----------------------------------------------------------------------
#
# Decide o próximo passo do agente. Três fontes, em ordem de prioridade:
#   1. DeepSeek (planner estruturado) quando há chave e orçamento de chamadas;
#   2. Plano adaptativo determinístico (reage ao evaluator) quando não há LLM;
#   3. Plano de pipeline fixo (default_plan) como última reserva.
#
# O plano adaptativo é o que torna o sistema reativo sem depender de rede/LLM:
# a próxima ação é escolhida em função do resultado e da avaliação anteriores.

plan_action <- function(tool, arguments = list(), summary, source, is_replan = FALSE, done = FALSE) {
  list(
    action = list(
      tool = tool,
      arguments = arguments,
      reasoning_summary = summary,
      expected_result = summary,
      done = done
    ),
    decision = NULL,
    source = source,
    is_replan = is_replan
  )
}

canonical_next <- function(state) {
  if (!isTRUE(state$collected)) return("collect_news")
  if (!isTRUE(state$deduplicated)) return("deduplicate_news")
  if (!isTRUE(state$ranked_done)) return("rank_news")
  if (!isTRUE(state$summarized_done)) return("summarize_article")
  if (!isTRUE(state$report_generated)) return("generate_report")
  if (!isTRUE(state$send_attempted)) return("send_report")
  "finalize"
}

first_url <- function(state) {
  if (nrow(state$items) > 0 && !is.null(state$items$url) && length(state$items$url) > 0) {
    return(state$items$url[[1]])
  }
  if (nrow(state$selected) > 0 && length(state$selected$url) > 0) {
    return(state$selected$url[[1]])
  }
  ""
}

# Plano determinístico fixo (fallback de pipeline). Preservado para
# compatibilidade e como referência do comportamento não-adaptativo.
default_plan <- function(state, config) {
  act <- function(tool, arguments = list(), summary = "Deterministic pipeline step.") {
    list(
      tool = tool,
      arguments = arguments,
      reasoning_summary = summary,
      expected_result = summary,
      done = FALSE
    )
  }

  if (!isTRUE(state$collected)) {
    return(list(action = act("collect_news"), decision = NULL, source = "default", is_replan = FALSE))
  }
  if (nrow(state$status_tbl) == 0 || !any_source_collected(state$status_tbl)) {
    return(list(
      action = list(tool = "finalize", arguments = list(), reasoning_summary = "No source returned usable items.", expected_result = "Stop with failure report.", done = TRUE),
      decision = NULL,
      source = "default",
      is_replan = FALSE
    ))
  }
  if (!isTRUE(state$deduplicated)) return(list(action = act("deduplicate_news"), decision = NULL, source = "default", is_replan = FALSE))
  if (!isTRUE(state$ranked_done)) return(list(action = act("rank_news"), decision = NULL, source = "default", is_replan = FALSE))
  if (!isTRUE(state$summarized_done)) return(list(action = act("summarize_article"), decision = NULL, source = "default", is_replan = FALSE))
  if (!isTRUE(state$report_generated)) return(list(action = act("generate_report"), decision = NULL, source = "default", is_replan = FALSE))
  if (!isTRUE(state$sent) && !isTRUE(state$send_attempted)) return(list(action = act("send_report"), decision = NULL, source = "default", is_replan = FALSE))
  list(
    action = list(tool = "finalize", arguments = list(), reasoning_summary = "Pipeline complete.", expected_result = "Finalize the run.", done = TRUE),
    decision = NULL,
    source = "default",
    is_replan = FALSE
  )
}

# Plano adaptativo determinístico: reage aos sinais do evaluator.
adaptive_plan <- function(state, config, evaluation) {
  act <- function(tool, arguments = list(), summary) {
    plan_action(tool, arguments, summary, "adaptive",
                is_replan = !identical(tool, canonical_next(state)))
  }
  fin <- function(summary) {
    plan_action("finalize", list(), summary, "adaptive", done = TRUE,
                is_replan = !identical("finalize", canonical_next(state)))
  }

  if (is.null(evaluation)) {
    return(plan_action("collect_news", list(), "Start by collecting news.", "adaptive"))
  }

  # Condições de parada / loop têm prioridade.
  if (isTRUE(evaluation$completed)) {
    return(fin(evaluation$stop_reason %||% "goal_achieved"))
  }
  if (isTRUE(evaluation$strategy_exhausted)) {
    return(fin("loop_detected"))
  }

  tool <- evaluation$tool

  if (identical(tool, "collect_news")) {
    if (nrow(state$status_tbl) == 0 || !any_source_collected(state$status_tbl)) {
      return(fin("critical_collection_failure"))
    }
    if (isTRUE(evaluation$conflict_detected)) {
      return(act("verify_source", list(url = first_url(state)),
                 "Conflict detected after collection; verify the source before proceeding."))
    }
    if (isTRUE(evaluation$insufficient)) {
      if (!isTRUE(state$recollect_attempted)) {
        return(act("collect_news", list(force = TRUE), "Insufficient items after collect; re-collect to gather more evidence."))
      }
      if (!isTRUE(state$search_attempted)) {
        return(act("search_news", list(query = "saude educacao politica ciencia"),
                   "Still insufficient after re-collect; search collected content for relevant evidence."))
      }
      return(fin("insufficient_information"))
    }
    return(act("deduplicate_news", list(), "Collected enough items; deduplicate."))
  }

  if (identical(tool, "search_news")) {
    if (isTRUE(evaluation$produced_new_info)) {
      return(act("deduplicate_news", list(), "Search found relevant content; deduplicate and continue."))
    }
    # Abandona a estratégia de busca e tenta verificação.
    if (!isTRUE(state$verify_attempted)) {
      return(act("verify_source", list(url = first_url(state)),
                 "Search returned nothing; abandon search and verify an alternative source."))
    }
    return(fin("no_useful_action_remaining"))
  }

  if (identical(tool, "verify_source")) {
    if (isTRUE(evaluation$needs_more_evidence) && !isTRUE(state$recollect_attempted)) {
      return(act("collect_news", list(force = TRUE),
                 "Verification raised uncertainty; re-collect for corroboration."))
    }
    return(act("deduplicate_news", list(), "Verification complete; deduplicate."))
  }

  if (identical(tool, "deduplicate_news")) {
    if (isTRUE(evaluation$insufficient)) {
      if (!isTRUE(state$recollect_attempted)) {
        return(act("collect_news", list(force = TRUE), "Too few articles after dedup; re-collect."))
      }
      if (!isTRUE(state$search_attempted)) {
        return(act("search_news", list(query = "saude educacao politica ciencia"),
                   "Too few articles after dedup; search for more relevant content."))
      }
      return(fin("insufficient_articles"))
    }
    return(act("rank_news", list(), "Deduplicated; rank candidates."))
  }

  if (identical(tool, "rank_news")) {
    if (isTRUE(evaluation$insufficient)) {
      if (!isTRUE(state$search_attempted)) {
        return(act("search_news", list(query = "saude educacao politica ciencia"),
                   "Nothing above threshold; search for alternative relevant items."))
      }
      return(fin("no_item_above_threshold"))
    }
    return(act("summarize_article", list(), "Selected items; summarize."))
  }

  if (identical(tool, "summarize_article")) {
    return(act("generate_report", list(), "Summarized; generate the report."))
  }
  if (identical(tool, "generate_report")) {
    return(act("send_report", list(), "Report generated; send it."))
  }
  if (identical(tool, "send_report")) {
    return(fin("goal_achieved"))
  }

  # Última reserva: nenhuma regra se aplicou.
  default_plan(state, config)
}

plan_next_action <- function(state, config, registry = tool_registry(), memory = NULL, evaluation = NULL) {
  # Fallback determinístico adaptativo quando não há planner disponível.
  if (!deepseek_available(config)) {
    return(adaptive_plan(state, config, evaluation))
  }
  if (state$llm_calls >= config$max_llm_calls) {
    agent_state_add_error(state, "LLM call budget exhausted.", context = "planner")
    return(adaptive_plan(state, config, evaluation))
  }

  system_prompt <- planner_system_prompt(state$goal, registry)
  user_prompt <- planner_user_prompt(state, evaluation)

  parsed <- llm_complete(config, system_prompt, user_prompt, decision_schema(registry))
  state$llm_calls <- state$llm_calls + 1L

  if (is.null(parsed)) {
    agent_state_add_error(state, "Planner returned no usable response; falling back to adaptive plan.", context = "planner")
    return(adaptive_plan(state, config, evaluation))
  }

  decision <- normalize_decision(parsed)
  if (!isTRUE(decision$valid)) {
    agent_state_add_error(state, decision$error, context = "planner")
    return(adaptive_plan(state, config, evaluation))
  }

  validated <- validate_action(decision, registry)
  if (!isTRUE(validated$ok)) {
    agent_state_add_error(state, validated$error, context = "planner")
    return(adaptive_plan(state, config, evaluation))
  }

  canonical <- canonical_next(state)
  is_replan <- !identical(validated$action$tool, canonical)

  list(action = validated$action, decision = decision, source = "planner", is_replan = is_replan)
}
