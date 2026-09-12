# Helpers da suíte de avaliação comportamental --------------------------------
#
# Mocks determinísticos das ferramentas (o "ambiente" simulado) para exercitar
# o cérebro do agente (planner adaptativo + evaluator + loop) sem rede e sem
# DeepSeek. O estado e a trajetória continuam sendo os reais.

make_fake_items <- function(n, source = "J3News") {
  if (n <= 0) return(empty_news_tbl())
  title <- sprintf("Noticia %d sobre tema relevante %d", seq_len(n), seq_len(n))
  tibble::tibble(
    id = paste0("id-", seq_len(n)),
    source = rep(source, n),
    title = title,
    url = sprintf("https://example.com/%d", seq_len(n)),
    published_at = lubridate::ymd_hms(rep("2026-07-05 10:00:00", n), tz = "America/Sao_Paulo"),
    modified_at = as.POSIXct(rep(NA, n)),
    date_kind = rep("published", n),
    date_source = rep("fake", n),
    excerpt = sprintf("Resumo da noticia %d.", seq_len(n)),
    keywords = rep("", n),
    raw_source = rep("fake", n),
    discard_reason = rep(NA_character_, n),
    title_norm = normalize_title(title)
  )
}

make_status <- function(n_failed = 0L) {
  ok_sources <- source_order()
  ok <- tibble::tibble(
    source = ok_sources,
    status = "ok",
    raw_count = 10L,
    valid_date_count = 10L,
    in_window_count = 10L,
    elapsed_sec = 0.1,
    diagnostics = NA_character_
  )
  if (n_failed > 0) {
    fail_sources <- ok_sources[seq_len(min(n_failed, length(ok_sources)))]
    ok$status[ok$source %in% fail_sources] <- "failed"
    ok$raw_count[ok$source %in% fail_sources] <- 0L
    ok$valid_date_count[ok$source %in% fail_sources] <- 0L
    ok$in_window_count[ok$source %in% fail_sources] <- 0L
    ok$diagnostics[ok$source %in% fail_sources] <- "simulated failure"
  }
  ok
}

make_all_failed_status <- function() {
  make_status(n_failed = length(source_order()))
}

new_scenario <- function(collect_n = 10L,
                         collect_force_n = collect_n,
                         n_failed_sources = 0L,
                         all_sources_fail = FALSE,
                         selected_n = NULL,
                         search_hits = NULL,
                         verify_quality = "high",
                         claim_status = NULL,
                         inject_conflict = FALSE,
                         min_articles_goal = 5L) {
  env <- new.env(parent = emptyenv())
  env$collect_calls <- 0L
  env$collect_n <- collect_n
  env$collect_force_n <- collect_force_n
  env$n_failed_sources <- n_failed_sources
  env$all_sources_fail <- all_sources_fail
  env$selected_n <- selected_n
  env$search_hits <- search_hits
  env$verify_quality <- verify_quality
  env$claim_status <- claim_status
  env$inject_conflict <- inject_conflict
  env$min_articles_goal <- min_articles_goal
  env
}

make_mock_registry <- function(scenario) {
  list(
    collect_news = tool_spec(
      name = "collect_news",
      description = "mock collect",
      parameters = list(
        list(name = "sources", type = "string[]", required = FALSE, default = NULL),
        list(name = "force", type = "boolean", required = FALSE, default = FALSE)
      ),
      validate = function(args, state, config) list(ok = TRUE),
      run = function(args, state, config, memory) {
        if (isTRUE(state$collected) && !isTRUE(args$force)) {
          return(list(summary = "skip collect", result = list(already_collected = TRUE, n_items = 0L)))
        }
        scenario$collect_calls <- scenario$collect_calls + 1L
        if (isTRUE(state$collected)) state$recollect_attempted <- TRUE

        if (isTRUE(scenario$all_sources_fail)) {
          state$status_tbl <- make_all_failed_status()
          state$items <- empty_news_tbl()
          state$collected <- TRUE
          return(list(summary = "all sources failed", result = list(ok = FALSE, n_items = 0L)))
        }

        n <- if (scenario$collect_calls == 1L) scenario$collect_n else scenario$collect_force_n
        state$status_tbl <- make_status(n_failed = scenario$n_failed_sources)
        state$items <- make_fake_items(n)
        state$collected <- TRUE

        if (isTRUE(scenario$inject_conflict)) {
          state$claims[[length(state$claims) + 1L]] <- list(
            claim = "Duas fontes divergem sobre o evento",
            url = "https://example.com/1",
            reliability = "known_configured_source",
            evidence_quality = "high",
            status = "conflicting"
          )
        }

        list(
          summary = sprintf("collected %d items", n),
          result = list(ok = TRUE, n_items = n, n_sources = length(source_order()))
        )
      }
    ),
    search_news = tool_spec(
      name = "search_news",
      description = "mock search",
      parameters = list(
        list(name = "query", type = "string", required = TRUE),
        list(name = "source", type = "string", required = FALSE, default = NULL)
      ),
      validate = function(args, state, config) list(ok = TRUE),
      run = function(args, state, config, memory) {
        state$search_attempted <- TRUE
        hits <- if (!is.null(scenario$search_hits)) scenario$search_hits(args$query %||% "") else make_fake_items(0)
        hits <- hits %||% make_fake_items(0)
        if (nrow(hits) > 0) {
          state$items <- dplyr::bind_rows(state$items, hits)
        }
        list(summary = sprintf("found %d", nrow(hits)), result = list(n = nrow(hits), matches = hits))
      }
    ),
    fetch_article = tool_spec(
      name = "fetch_article",
      description = "mock fetch",
      parameters = list(
        list(name = "id", type = "string", required = FALSE, default = NULL),
        list(name = "url", type = "string", required = FALSE, default = NULL)
      ),
      validate = function(args, state, config) list(ok = TRUE),
      run = function(args, state, config, memory) {
        key <- args$id %||% args$url %||% "unknown"
        state$article_texts[[key]] <- "texto simulado do artigo"
        state$evidence[[key]] <- list(id = key, url = args$url %||% "", n_chars = 20L)
        list(summary = "fetched", result = list(fetched = TRUE, id = key, n_chars = 20L))
      }
    ),
    deduplicate_news = tool_spec(
      name = "deduplicate_news",
      description = "mock dedup",
      parameters = list(list(name = "use_memory", type = "boolean", required = FALSE, default = FALSE)),
      validate = function(args, state, config) list(ok = TRUE),
      run = function(args, state, config, memory) {
        before <- nrow(state$items)
        candidates <- state$items |>
          dplyr::filter(is.na(.data$discard_reason) | .data$discard_reason == "") |>
          deduplicate_exact()
        state$candidates <- candidates
        state$deduplicated <- TRUE
        list(
          summary = sprintf("dedup %d -> %d", before, nrow(candidates)),
          result = list(before = before, after = nrow(candidates), dropped = before - nrow(candidates))
        )
      }
    ),
    rank_news = tool_spec(
      name = "rank_news",
      description = "mock rank",
      parameters = list(),
      validate = function(args, state, config) list(ok = TRUE),
      run = function(args, state, config, memory) {
        candidates <- state$candidates
        if (nrow(candidates) == 0) {
          state$ranked <- candidates |>
            dplyr::mutate(score = numeric(), topic = character(), justification = character(), canonical_id = character())
          state$selected <- state$ranked
          state$ranked_done <- TRUE
          return(list(summary = "no candidates", result = list(ranked = 0L, selected = 0L)))
        }
        n_sel <- min(scenario$selected_n %||% nrow(candidates), nrow(candidates))
        ranked <- candidates |>
          dplyr::mutate(score = 90, topic = "interesse publico", justification = "relevante", canonical_id = .data$id)
        selected <- ranked |> utils::head(n_sel)
        state$ranked <- ranked
        state$selected <- selected
        state$ranked_done <- TRUE
        list(summary = sprintf("ranked %d selected %d", nrow(ranked), nrow(selected)),
             result = list(ranked = nrow(ranked), selected = nrow(selected)))
      }
    ),
    verify_source = tool_spec(
      name = "verify_source",
      description = "mock verify",
      parameters = list(
        list(name = "url", type = "string", required = TRUE),
        list(name = "source", type = "string", required = FALSE, default = NULL),
        list(name = "claim", type = "string", required = FALSE, default = NULL)
      ),
      validate = function(args, state, config) {
        if (!nzchar(args$url %||% "")) return(list(ok = FALSE, error = "url required"))
        list(ok = TRUE)
      },
      run = function(args, state, config, memory) {
        state$verify_attempted <- TRUE
        quality <- scenario$verify_quality
        status <- scenario$claim_status %||% "corroborated"
        state$evidence[[length(state$evidence) + 1L]] <- list(
          url = args$url %||% "", evidence_quality = quality, claim_status = status
        )
        if (!is.null(args$claim) || !is.null(scenario$claim_status)) {
          state$claims[[length(state$claims) + 1L]] <- list(
            claim = args$claim %||% "claim", url = args$url %||% "",
            evidence_quality = quality, status = status
          )
        }
        list(summary = sprintf("verified %s", quality), result = list(evidence_quality = quality, claim_status = status))
      }
    ),
    summarize_article = tool_spec(
      name = "summarize_article",
      description = "mock summarize",
      parameters = list(list(name = "ids", type = "string[]", required = FALSE, default = NULL)),
      validate = function(args, state, config) list(ok = TRUE),
      run = function(args, state, config, memory) {
        selected <- state$selected
        summarized <- selected |>
          dplyr::mutate(
            title_final = .data$title, summary = "resumo", why_matters = "importa",
            caveat = "", article_text = ""
          )
        state$summarized <- summarized
        state$summarized_done <- TRUE
        list(summary = sprintf("summarized %d", nrow(summarized)),
             result = list(summarized = nrow(summarized), ids = summarized$id))
      }
    ),
    generate_report = tool_spec(
      name = "generate_report",
      description = "mock report",
      parameters = list(),
      validate = function(args, state, config) list(ok = TRUE),
      run = function(args, state, config, memory) {
        state$report_generated <- TRUE
        state$html <- "<html/>"
        state$html_path <- tempfile(fileext = ".html")
        state$audit <- list(csv_path = tempfile(fileext = ".csv"), json_path = tempfile(fileext = ".json"))
        list(summary = "report generated", result = list(generated = TRUE, html_path = state$html_path))
      }
    ),
    send_report = tool_spec(
      name = "send_report",
      description = "mock send",
      parameters = list(),
      validate = function(args, state, config) list(ok = TRUE),
      run = function(args, state, config, memory) {
        state$send_attempted <- TRUE
        state$sent <- TRUE
        state$send_result <- list(any_success = TRUE, dry_run = config$dry_run)
        state$report_path <- tempfile(fileext = ".json")
        list(summary = "sent", result = list(any_success = TRUE, dry_run = config$dry_run, recipients = config$send_recipients))
      }
    )
  )
}

run_agent_scenario <- function(scenario, overrides = list()) {
  cfg <- load_config(dry_run = TRUE, now = lubridate::ymd_hms("2026-07-05 18:00:00", tz = "America/Sao_Paulo"))
  cfg$deepseek_api_key <- ""
  cfg$max_iterations <- 20L
  cfg$min_articles_goal <- scenario$min_articles_goal
  cfg$max_repeated_action <- 3L
  cfg$output_dir <- tempfile("agent_eval_out")
  cfg$memory_path <- file.path(cfg$output_dir, "agent-memory.json")
  for (nm in names(overrides)) cfg[[nm]] <- overrides[[nm]]

  run_agent(config = cfg, registry = make_mock_registry(scenario))
}

trajectory_tools <- function(res) {
  res$trajectory$tool
}

expect_replanned <- function(res) {
  testthat::expect_true(any(res$trajectory$is_replan, na.rm = TRUE),
                        info = "expected at least one replan in the trajectory")
}

expect_no_replan <- function(res) {
  testthat::expect_false(any(res$trajectory$is_replan, na.rm = TRUE),
                         info = "expected no replan in the trajectory")
}

expect_tool_used <- function(res, tool) {
  testthat::expect_true(tool %in% trajectory_tools(res), info = sprintf("expected tool %s", tool))
}

expect_tool_not_used <- function(res, tool) {
  testthat::expect_false(tool %in% trajectory_tools(res), info = sprintf("did not expect tool %s", tool))
}
