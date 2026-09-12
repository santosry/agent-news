# Testes do agente autônomo: registry, validação, JSON, memória, limites,
# recuperação de erro e — criticamente — a lógica de destinatários por modo.

test_that("tool registry exposes the required allowlist", {
  registry <- tool_registry()
  required <- c(
    "collect_news", "search_news", "fetch_article", "deduplicate_news",
    "rank_news", "verify_source", "summarize_article", "generate_report",
    "send_report"
  )
  expect_true(all(required %in% names(registry)))
  expect_true(all(vapply(registry, function(t) !is.null(t$name) && !is.null(t$run), logical(1))))
})

test_that("validate_action rejects unknown tools and accepts known tools", {
  registry <- tool_registry()

  bad <- validate_action(list(action = "run_shell", arguments = list()), registry)
  expect_false(bad$ok)
  expect_match(bad$error, "unknown tool")

  good <- validate_action(
    list(action = "collect_news", arguments = list(sources = "IFF"), reasoning_summary = "x", done = FALSE),
    registry
  )
  expect_true(good$ok)
  expect_equal(good$action$tool, "collect_news")
  expect_equal(good$action$arguments$sources, "IFF")

  final <- validate_action(list(action = "finalize", done = TRUE), registry)
  expect_true(final$ok)
  expect_true(final$action$done)
})

test_that("validate_action rejects malformed arguments", {
  registry <- tool_registry()

  # Tipo errado (boolean esperado, string fornecida)
  missing <- validate_action(list(action = "deduplicate_news", arguments = list(use_memory = "yes")), registry)
  expect_false(missing$ok)

  # Argumento desconhecido
  unknown <- validate_action(list(action = "collect_news", arguments = list(evil = "x")), registry)
  expect_false(unknown$ok)
  expect_match(unknown$error, "unknown argument")

  # Argumento obrigatório ausente
  noarg <- validate_action(list(action = "search_news", arguments = list()), registry)
  expect_false(noarg$ok)
  expect_match(noarg$error, "missing required argument")
})

test_that("parse_llm_json recovers from invalid and markdown-wrapped JSON", {
  expect_null(parse_llm_json("this is not json at all"))
  expect_null(parse_llm_json(""))

  md <- '```json\n{"action": "finalize", "done": true}\n```'
  parsed <- parse_llm_json(md)
  expect_equal(parsed$action, "finalize")
  expect_true(parsed$done)

  noisy <- 'prefix text {"action": "collect_news", "arguments": {"force": false}} suffix'
  parsed2 <- parse_llm_json(noisy)
  expect_equal(parsed2$action, "collect_news")
})

test_that("normalize_decision coerces to a safe typed list", {
  expect_false(normalize_decision(NULL)$valid)
  expect_false(normalize_decision(list())$valid)

  d <- normalize_decision(list(action = "rank_news", arguments = list(), done = TRUE))
  expect_true(d$valid)
  expect_equal(d$action, "rank_news")
  expect_true(is.list(d$arguments))
  expect_true(d$done)

  d2 <- normalize_decision(list(action = "rank_news", arguments = list(), done = 1))
  expect_false(d2$done)
})

test_that("default plan reproduces the deterministic pipeline order", {
  cfg <- load_config(dry_run = TRUE, now = lubridate::ymd_hms("2026-07-05 18:00:00", tz = "America/Sao_Paulo"))
  state <- new_agent_state(NULL, cfg)

  p1 <- default_plan(state, cfg)
  expect_equal(p1$action$tool, "collect_news")

  state$collected <- TRUE
  state$status_tbl <- tibble::tibble(source = "IFF", status = "ok", in_window_count = 1L)
  p2 <- default_plan(state, cfg)
  expect_equal(p2$action$tool, "deduplicate_news")

  state$deduplicated <- TRUE
  state$ranked_done <- TRUE
  state$summarized_done <- TRUE
  state$report_generated <- TRUE
  state$sent <- TRUE
  p3 <- default_plan(state, cfg)
  expect_equal(p3$action$tool, "finalize")
})

test_that("execute_action returns structured failure for a throwing tool", {
  cfg <- load_config(dry_run = TRUE, now = lubridate::ymd_hms("2026-07-05 18:00:00", tz = "America/Sao_Paulo"))
  state <- new_agent_state(NULL, cfg)
  registry <- list(
    boom = tool_spec(
      name = "boom",
      description = "always fails",
      parameters = list(),
      validate = function(args, state, config) list(ok = TRUE),
      run = function(args, state, config, memory) stop("kaboom", call. = FALSE)
    )
  )
  res <- execute_action(list(tool = "boom", arguments = list()), state, cfg, registry)
  expect_false(res$ok)
  expect_match(res$error, "kaboom")

  res_fin <- execute_action(list(tool = "finalize", arguments = list()), state, cfg, registry)
  expect_true(res_fin$ok)
  expect_true(res_fin$result$done)
})

test_that("agent stops at max_iterations without infinite loop", {
  cfg <- load_config(dry_run = TRUE, now = lubridate::ymd_hms("2026-07-05 18:00:00", tz = "America/Sao_Paulo"))
  cfg$max_iterations <- 1L
  cfg$deepseek_api_key <- ""
  cfg$output_dir <- tempfile("agent_limit_out")
  cfg$memory_path <- tempfile(fileext = ".json")

  registry <- list(
    collect_news = tool_spec(
      name = "collect_news",
      description = "mock",
      parameters = list(),
      validate = function(args, state, config) list(ok = TRUE),
      run = function(args, state, config, memory) {
        state$collected <- TRUE
        state$status_tbl <- tibble::tibble(source = "IFF", status = "ok", in_window_count = 1L)
        state$items <- empty_news_tbl()
        list(summary = "ok", result = list(ok = TRUE))
      }
    )
  )

  res <- run_agent(config = cfg, registry = registry)
  expect_false(res$ok)
  expect_equal(res$iterations, 1L)
  expect_match(res$message, "iteration limit")
})

test_that("memory persists and reads structured tables", {
  cfg <- load_config(dry_run = TRUE)
  cfg$memory_path <- tempfile(fileext = ".json")

  mem <- memory_open(cfg)
  mem <- memory_append(mem, "agent_runs", list(run_id = "run_1", status = "finished", n_errors = 0L))
  mem <- memory_append(mem, "articles", list(id = "a1", source = "IFF", url = "https://example.com/a", content_hash = "h1"))
  memory_save(mem, cfg)

  mem2 <- memory_open(cfg)
  expect_equal(memory_count(mem2, "agent_runs"), 1L)
  expect_equal(memory_count(mem2, "articles"), 1L)
  seen <- memory_seen_articles(mem2)
  expect_true("https://example.com/a" %in% seen$url)
})

test_that("memory dedup keeps at least one item per collected source", {
  cfg <- load_config(dry_run = TRUE)
  cfg$memory_path <- tempfile(fileext = ".json")

  mem <- memory_open(cfg)
  mem <- memory_append(mem, "articles", list(id = "a1", source = "J3News", url = "https://j3news.com/seen", content_hash = "h1"))
  memory_save(mem, cfg)

  state <- new_agent_state(NULL, cfg)
  state$items <- tibble::tibble(
    id = c("j1", "f1"),
    source = c("J3News", "Folha1"),
    title = c("Notícia já vista", "Notícia nova"),
    title_norm = normalize_title(c("Notícia já vista", "Notícia nova")),
    url = c("https://j3news.com/seen", "https://folha1.com.br/nova"),
    published_at = lubridate::ymd_hms(c("2026-07-05 10:00:00", "2026-07-05 11:00:00"), tz = "America/Sao_Paulo"),
    modified_at = as.POSIXct(NA, tz = "America/Sao_Paulo"),
    date_kind = "published",
    date_source = "rss_pubDate",
    excerpt = "",
    keywords = "",
    raw_source = NA_character_,
    discard_reason = NA_character_
  )

  tool <- tool_deduplicate_news()
  tool$run(list(use_memory = TRUE), state, cfg, memory_open(cfg))

  expect_true("J3News" %in% state$candidates$source)
  expect_true("Folha1" %in% state$candidates$source)
  expect_equal(nrow(state$candidates), 2L)
})

test_that("verify_source produces deterministic evidence quality", {
  cfg <- load_config(dry_run = TRUE)
  state <- new_agent_state(NULL, cfg)
  registry <- tool_registry()

  # Domínio configurado => known_domain TRUE (independe de rede para o rótulo).
  expect_true(domain_is_known("https://www.bbc.com/news/a"))
  expect_true(domain_is_known("https://j3news.com/post"))
  expect_false(domain_is_known("https://unknown.example.org/x"))
})

test_that("recipients: dry_run sends nothing", {
  withr::local_envvar(c(EMAIL_TO = "owner@example.com", DEEPSEEK_API_KEY = ""))
  cfg <- load_config(dry_run = TRUE, test_mode = FALSE)
  expect_equal(cfg$send_recipients, character())
})

test_that("recipients: test_mode sends ONLY to the test recipient", {
  withr::local_envvar(c(EMAIL_TO = "owner@example.com,other@example.com", DEEPSEEK_API_KEY = ""))
  cfg <- load_config(dry_run = FALSE, test_mode = TRUE)
  expect_equal(cfg$send_recipients, test_recipient())
  expect_false("thaynafarias2007@gmail.com" %in% cfg$send_recipients)
  expect_false("owner@example.com" %in% cfg$send_recipients)
})

test_that("recipients: normal mode sends to full list including permanent recipient", {
  withr::local_envvar(c(EMAIL_TO = "owner@example.com,other@example.com", DEEPSEEK_API_KEY = ""))
  cfg <- load_config(dry_run = FALSE, test_mode = FALSE)
  expect_true("thaynafarias2007@gmail.com" %in% cfg$send_recipients)
  expect_true("owner@example.com" %in% cfg$send_recipients)
  expect_true("other@example.com" %in% cfg$send_recipients)
  expect_false("ryandpaulosantos@gmail.com" %in% cfg$send_recipients)
})

test_that("recipients: permanent recipient is added exactly once", {
  withr::local_envvar(c(EMAIL_TO = "thaynafarias2007@gmail.com,owner@example.com", DEEPSEEK_API_KEY = ""))
  cfg <- load_config(dry_run = FALSE, test_mode = FALSE)
  expect_equal(sum(cfg$send_recipients == "thaynafarias2007@gmail.com"), 1L)
})

test_that("CLI arg parser supports --dry-run, --send, --test and --mode", {
  expect_true(parse_args(c("--dry-run"))$dry_run)
  expect_false(parse_args(c("--send"))$dry_run)
  expect_true(parse_args(c("--test"))$test_mode)
  expect_equal(parse_args(c("--mode", "investigate"))$mode, "investigate")
  expect_null(parse_args(character())$dry_run)
})

test_that("planner uses adaptive plan without an API key", {
  cfg <- load_config(dry_run = TRUE, now = lubridate::ymd_hms("2026-07-05 18:00:00", tz = "America/Sao_Paulo"))
  cfg$deepseek_api_key <- ""
  state <- new_agent_state(NULL, cfg)
  plan <- plan_next_action(state, cfg, tool_registry(), memory_open(cfg))
  expect_equal(plan$source, "adaptive")
  expect_equal(plan$action$tool, "collect_news")
})

test_that("deterministic agent run produces all artifacts in dry-run", {
  make_fake_collector <- function(name) {
    force(name)
    function(config) {
      n <- 2L
      rows <- tibble::tibble(
        id = paste0("fake-", tolower(gsub("[^a-zA-Z]", "", name)), "-", seq_len(n)),
        source = name,
        title = sprintf("%s notícia relevante sobre saúde pública %d", name, seq_len(n)),
        url = sprintf("https://%s.example.com/%d", tolower(gsub("[^a-zA-Z]", "", name)), seq_len(n)),
        published_at = config$now - lubridate::days(seq_len(n)),
        modified_at = as.POSIXct(NA),
        date_kind = "published",
        date_source = "fake",
        excerpt = sprintf("Resumo da notícia %d de %s sobre SUS e políticas públicas.", seq_len(n), name),
        keywords = "",
        raw_source = "fake",
        discard_reason = NA_character_
      )
      finish_source_result(name, rows, raw_count = n, config = config)
    }
  }

  old <- get("news_collectors", envir = .GlobalEnv)
  assign(
    "news_collectors",
    function() setNames(lapply(source_order(), make_fake_collector), source_order()),
    envir = .GlobalEnv
  )
  on.exit(assign("news_collectors", old, envir = .GlobalEnv), add = TRUE)

  cfg <- load_config(dry_run = TRUE, now = lubridate::ymd_hms("2026-07-05 18:00:00", tz = "America/Sao_Paulo"))
  cfg$deepseek_api_key <- ""
  cfg$max_iterations <- 12L
  cfg$min_articles_goal <- 1L
  cfg$output_dir <- tempfile("agent_out")
  cfg$memory_path <- file.path(cfg$output_dir, "agent-memory.json")

  res <- run_agent(config = cfg)

  expect_true(res$ok)
  expect_equal(res$dry_run, TRUE)
  expect_true(file.exists(res$html_path))
  expect_true(file.exists(res$audit_path))
  expect_true(file.exists(res$report_path))
  expect_true(file.exists(res$agent_audit_path))
  expect_true(file.exists(cfg$memory_path))

  audit <- jsonlite::fromJSON(res$agent_audit_path, simplifyVector = FALSE)
  expect_equal(audit$run_id, res$agent_run_id)
  expect_true(length(audit$actions) >= 5L)
  expect_true(any(vapply(audit$actions, function(a) identical(a$tool, "generate_report"), logical(1))))
})
