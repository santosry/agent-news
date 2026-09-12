# Cenários de avaliação de comportamento agentivo -----------------------------
#
# Cada cenário usa ferramentas simuladas (helper-mock.R) e exercita o cérebro
# real do agente (planner adaptativo + evaluator + loop) de forma determinística.

test_that("A. LOW EVIDENCE: agent recognizes insufficiency and re-collects instead of summarizing", {
  scenario <- new_scenario(collect_n = 2L, collect_force_n = 10L, selected_n = 5L, min_articles_goal = 5L)
  res <- run_agent_scenario(scenario)

  expect_true(res$ok)
  expect_replanned(res)
  expect_tool_used(res, "collect_news")

  # A segunda coleta deve ter sido forçada (replan) e a trajetória NÃO pode ir
  # direto para dedup/resumo com apenas 2 itens.
  tools <- trajectory_tools(res)
  first_collect_idx <- which(tools == "collect_news")[1]
  second_collect_idx <- which(tools == "collect_news")[2]
  expect_true(!is.na(second_collect_idx), info = "expected a second (re-)collection")
  expect_true(second_collect_idx == first_collect_idx + 1L,
              info = "re-collection must immediately follow the insufficient first collection")

  expect_equal(res$metrics$n_replans >= 1L, TRUE)
})

test_that("B. CONFLICTING SOURCES: conflict triggers verification before ranking", {
  conflict <- new_scenario(collect_n = 10L, selected_n = 5L, inject_conflict = TRUE,
                           verify_quality = "high", claim_status = "corroborated", min_articles_goal = 5L)
  res_conflict <- run_agent_scenario(conflict)

  expect_tool_used(res_conflict, "verify_source")
  tools <- trajectory_tools(res_conflict)
  expect_true(which(tools == "verify_source")[1] < which(tools == "deduplicate_news")[1],
              info = "verification must happen before deduplication when conflict is detected")

  # Sem conflito, a mesma coleta não deve disparar verificação.
  calm <- new_scenario(collect_n = 10L, selected_n = 5L, inject_conflict = FALSE, min_articles_goal = 5L)
  res_calm <- run_agent_scenario(calm)
  expect_tool_not_used(res_calm, "verify_source")
})

test_that("C. SOURCE FAILURE: partial failures are recorded and the run continues", {
  scenario <- new_scenario(collect_n = 10L, n_failed_sources = 2L, selected_n = 5L, min_articles_goal = 5L)
  res <- run_agent_scenario(scenario)

  expect_true(res$ok)
  gaps <- res$metrics$final_evidence_quality
  expect_tool_used(res, "deduplicate_news")
  expect_tool_used(res, "send_report")
})

test_that("C2. SOURCE FAILURE: all sources failing ends explicitly (no fake report)", {
  scenario <- new_scenario(all_sources_fail = TRUE, min_articles_goal = 5L)
  res <- run_agent_scenario(scenario)

  expect_false(res$ok)
  expect_equal(res$outcome, "failed")
  expect_false("generate_report" %in% trajectory_tools(res),
               info = "must not generate a report when collection totally failed")
})

test_that("D. DUPLICATE NEWS: redundancy is removed and not treated as independent evidence", {
  # 10 itens, todos com o mesmo título/URL (duplicatas).
  make_dupes <- function() {
    items <- make_fake_items(10L)
    items$title <- rep("Mesma noticia repetida", 10L)
    items$url <- rep("https://example.com/duplicada", 10L)
    items$title_norm <- normalize_title(items$title)
    items
  }
  scenario <- new_scenario(collect_n = 10L, selected_n = 5L, min_articles_goal = 5L)
  scenario$dup_items <- make_dupes()

  # Sobrescreve collect para devolver duplicatas (espelhando o collect real,
  # inclusive marcando re-coleta no estado).
  registry <- make_mock_registry(scenario)
  registry$collect_news$run <- function(args, state, config, memory) {
    scenario$collect_calls <- scenario$collect_calls + 1L
    if (isTRUE(state$collected)) state$recollect_attempted <- TRUE
    state$status_tbl <- make_status(0L)
    state$items <- scenario$dup_items
    state$collected <- TRUE
    list(summary = "collected dupes", result = list(ok = TRUE, n_items = 10L))
  }

  cfg <- load_config(dry_run = TRUE, now = lubridate::ymd_hms("2026-07-05 18:00:00", tz = "America/Sao_Paulo"))
  cfg$deepseek_api_key <- ""
  cfg$max_iterations <- 20L
  cfg$min_articles_goal <- 5L
  cfg$output_dir <- tempfile("agent_eval_out")
  cfg$memory_path <- file.path(cfg$output_dir, "agent-memory.json")
  res <- run_agent(config = cfg, registry = registry)

  expect_tool_used(res, "deduplicate_news")
  # As 10 duplicatas colapsam para 1 candidato (< meta). O agente reconhece a
  # insuficiência e NÃO apresenta as duplicatas como 10 evidências independentes
  # (não gera relatório de sucesso com 10 itens).
  expect_false(res$ok, info = "duplicates must not be treated as independent evidence")
  expect_false(res$metrics$goal_achieved)
  expect_false("generate_report" %in% trajectory_tools(res),
               info = "must not generate a report from duplicated-only evidence")
  expect_true(res$iterations < res$max_iterations, info = "must stop cleanly, not loop on duplicates")
})

test_that("E. INSUFFICIENT ARTICLES: agent does not pretend the goal was achieved", {
  scenario <- new_scenario(collect_n = 2L, collect_force_n = 2L, selected_n = 2L,
                           search_hits = function(q) make_fake_items(0L), min_articles_goal = 5L)
  res <- run_agent_scenario(scenario)

  expect_false(res$ok)
  expect_false(res$metrics$goal_achieved)
  expect_true(res$outcome %in% c("failed", "loop_detected", "iteration_limit"))
  expect_false("generate_report" %in% trajectory_tools(res),
               info = "must not generate a report when the goal was not achieved")
})

test_that("F. REPLANNING: second action depends on the insufficient first result", {
  scenario <- new_scenario(collect_n = 1L, collect_force_n = 8L, selected_n = 5L, min_articles_goal = 5L)
  res <- run_agent_scenario(scenario)

  expect_true(res$ok)
  tools <- trajectory_tools(res)
  expect_equal(tools[1], "collect_news")
  expect_equal(tools[2], "collect_news")

  # A segunda coleta foi um replan e usou force=TRUE (argumento diferente).
  args2 <- res$trajectory$arguments[2]
  expect_true(grepl("force", args2), info = "second collect must be forced")

  expect_true(res$metrics$n_replans >= 1L)
})

test_that("FUNDAMENTAL ADAPTATION: different observed results produce different trajectories", {
  good <- new_scenario(collect_n = 10L, selected_n = 5L, min_articles_goal = 5L)
  bad <- new_scenario(collect_n = 1L, collect_force_n = 1L, selected_n = 1L,
                      search_hits = function(q) make_fake_items(0L), min_articles_goal = 5L)

  res_good <- run_agent_scenario(good)
  res_bad <- run_agent_scenario(bad)

  tools_good <- trajectory_tools(res_good)
  tools_bad <- trajectory_tools(res_bad)

  # Comparação semântica, não textual.
  expect_false(identical(tools_good, tools_bad),
               info = "good and bad scenarios must not produce identical trajectories")
  expect_true(res_good$ok && !res_bad$ok)
  expect_true(res_good$metrics$n_replans < res_bad$metrics$n_replans ||
              res_good$iterations < res_bad$iterations,
              info = "bad scenario should require more replanning/iterations")
})

test_that("G. STOP CONDITION: agent stops when the goal is achieved quickly", {
  scenario <- new_scenario(collect_n = 10L, selected_n = 5L, min_articles_goal = 5L)
  res <- run_agent_scenario(scenario)

  expect_true(res$ok)
  expect_equal(res$outcome, "completed")
  expect_true(res$metrics$stop_success)
  # Não deve executar busca/verificação extras depois de concluir.
  tools <- trajectory_tools(res)
  send_idx <- which(tools == "send_report")[1]
  expect_false(any(tools[seq_along(tools) > send_idx] %in% c("search_news", "verify_source", "collect_news")),
               info = "no extra tools after completion")
})

test_that("G2. STOP CONDITION: unachievable goal ends explicitly (no infinite loop)", {
  scenario <- new_scenario(all_sources_fail = TRUE, min_articles_goal = 5L)
  res <- run_agent_scenario(scenario)

  expect_false(res$ok)
  expect_true(res$iterations < res$max_iterations, info = "must stop before the iteration limit")
  expect_false(res$metrics$goal_achieved)
})

test_that("H. STRATEGY ABANDONMENT: empty search is abandoned for another strategy", {
  scenario <- new_scenario(collect_n = 2L, collect_force_n = 2L, selected_n = 2L,
                           search_hits = function(q) make_fake_items(0L),
                           verify_quality = "high", claim_status = "corroborated",
                           min_articles_goal = 5L)
  res <- run_agent_scenario(scenario)

  tools <- trajectory_tools(res)
  expect_true("search_news" %in% tools)
  # Após uma busca vazia, o agente não repete a busca imediatamente.
  search_idx <- which(tools == "search_news")
  expect_equal(length(search_idx), 1L, info = "empty search must not be repeated")
  # A próxima ação após a busca vazia muda de estratégia.
  expect_true(tools[search_idx[1] + 1L] %in% c("verify_source", "collect_news", "finalize"),
              info = "must abandon search for a different strategy")
})

test_that("LOOP PROTECTION: repeated identical action is detected and stopped", {
  # Força o planner a repetir a mesma ação (simula um planner/LLM mal-comportado).
  scenario <- new_scenario(collect_n = 2L, selected_n = 2L,
                           search_hits = function(q) make_fake_items(0L), min_articles_goal = 5L)
  cfg <- load_config(dry_run = TRUE, now = lubridate::ymd_hms("2026-07-05 18:00:00", tz = "America/Sao_Paulo"))
  cfg$deepseek_api_key <- ""
  cfg$max_iterations <- 20L
  cfg$max_repeated_action <- 3L
  cfg$min_articles_goal <- 5L
  cfg$output_dir <- tempfile("agent_eval_out")
  cfg$memory_path <- file.path(cfg$output_dir, "agent-memory.json")

  registry <- make_mock_registry(scenario)
  # Sobrescreve plan_next_action globalmente para sempre repetir search_news.
  old_plan <- get("plan_next_action", envir = .GlobalEnv)
  assign("plan_next_action", function(state, config, registry, memory, evaluation) {
    list(
      action = list(tool = "search_news", arguments = list(query = "x"), reasoning_summary = "repeat", expected_result = "repeat", done = FALSE),
      decision = NULL, source = "forced", is_replan = FALSE
    )
  }, envir = .GlobalEnv)
  on.exit(assign("plan_next_action", old_plan, envir = .GlobalEnv), add = TRUE)

  res <- run_agent(config = cfg, registry = registry)

  expect_equal(res$outcome, "loop_detected")
  expect_true(res$metrics$n_loops_stopped >= 1L)
  expect_true(res$iterations < res$max_iterations)
})

test_that("SECURITY: LLM-style decisions cannot execute arbitrary R (allowlist only)", {
  registry <- make_mock_registry(new_scenario())
  # Decisão com ferramenta inexistente (como se o LLM tentasse executar algo arbitrário).
  bad <- validate_action(list(action = "system", arguments = list(cmd = "rm -rf /")), registry)
  expect_false(bad$ok)
  expect_match(bad$error, "unknown tool")

  # Argumento não permitido é rejeitado antes da execução.
  bad2 <- validate_action(list(action = "send_report", arguments = list(recipients = "evil@x.com")), registry)
  expect_false(bad2$ok)
  expect_match(bad2$error, "unknown argument")
})
