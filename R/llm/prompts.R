# Prompts do planner -----------------------------------------------------------
#
# O DeepSeek atua como planejador: recebe objetivo, estado, observações,
# histórico resumido e as ferramentas disponíveis; devolve UMA decisão
# estruturada (JSON). Nunca recebe segredos nem conteúdo de cadeia de raciocínio.

planner_system_prompt <- function(goal, registry) {
  tools <- paste(tools_description(registry), collapse = "\n")
  paste0(
    "You are the planning module of an autonomous news-curation agent written in R. ",
    "You do NOT execute code and you do NOT see secrets. ",
    "You choose exactly ONE next action from the allowlist below, with structured arguments.\n\n",
    "GOAL:\n", goal, "\n\n",
    "AVAILABLE TOOLS (allowlist only):\n", tools, "\n\n",
    "RULES:\n",
    "- Respond with a single JSON object matching this schema:\n",
    "  {\"action\": \"<tool_name|finalize>\", \"arguments\": {...}, ",
    "\"reasoning_summary\": \"short operational justification\", ",
    "\"expected_result\": \"what this action should produce\", \"done\": false}\n",
    "- 'action' MUST be one of the tool names above, or 'finalize'.\n",
    "- 'arguments' MUST only contain keys documented for that tool; never pass recipients, ",
    "secrets, code, or system commands.\n",
    "- Never emit chain-of-thought. Keep 'reasoning_summary' short and operational.\n",
    "- Set \"done\": true and action \"finalize\" only when the goal is met or the run must stop.\n",
    "- If evidence is insufficient or a source is weak, prefer verify_source or fetch_article ",
    "before relying on that evidence.\n",
    "- Output ONLY raw JSON, without markdown fences."
  )
}

planner_user_prompt <- function(state, evaluation = NULL) {
  summary <- agent_state_summary(state)
  history <- utils::tail(
    purrr::map_chr(state$actions, function(a) {
      sprintf("%s(%s)", a$tool, paste(names(a$arguments %||% list()), collapse = ","))
    }),
    6
  )

  eval_block <- if (is.null(evaluation)) {
    "(no action executed yet)"
  } else {
    jsonlite::toJSON(
      list(
        tool = evaluation$tool,
        ok = evaluation$ok,
        completed = evaluation$completed,
        insufficient = evaluation$insufficient,
        conflict_detected = evaluation$conflict_detected,
        needs_verification = evaluation$needs_verification,
        needs_more_evidence = evaluation$needs_more_evidence,
        produced_new_info = evaluation$produced_new_info,
        evidence_quality = evaluation$evidence_quality,
        confidence = evaluation$confidence,
        reasons = evaluation$reasons
      ),
      auto_unbox = TRUE, pretty = TRUE, null = "null"
    )
  }

  paste0(
    "CURRENT STATE (JSON):\n",
    jsonlite::toJSON(summary, auto_unbox = TRUE, pretty = TRUE, null = "null"),
    "\n\nLAST EVALUATION:\n", eval_block,
    "\n\nRECENT ACTIONS:\n",
    if (length(history) == 0) "(none yet)" else paste(history, collapse = "\n"),
    "\n\nChoose the next action based on the current state and the last evaluation."
  )
}
