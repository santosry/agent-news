#!/usr/bin/env Rscript

for (file in sort(list.files("R", pattern = "[.]R$", full.names = TRUE))) {
  source(file, local = FALSE)
}

measure_stage <- function(name, expr) {
  started <- Sys.time()
  timing <- system.time(value <- force(expr))
  list(
    name = name,
    value = value,
    elapsed_sec = unname(timing[["elapsed"]]),
    started_at = format(started, "%Y-%m-%dT%H:%M:%S%z"),
    finished_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
  )
}

config <- load_config(dry_run = TRUE)
config$openai_api_key <- ""
config$max_candidates_per_source <- as.integer(Sys.getenv("BENCHMARK_MAX_CANDIDATES_PER_SOURCE", config$max_candidates_per_source))
config$cnn_max_pages <- as.integer(Sys.getenv("BENCHMARK_CNN_MAX_PUBLIC_PAGES", config$cnn_max_pages))
config$iff_max_pages <- as.integer(Sys.getenv("BENCHMARK_IFF_MAX_PAGES", config$iff_max_pages))
config$uenf_max_pages <- as.integer(Sys.getenv("BENCHMARK_UENF_MAX_PAGES", config$uenf_max_pages))
config$news_per_source <- as.integer(Sys.getenv("BENCHMARK_NEWS_PER_SOURCE", config$news_per_source))
config$max_selected <- as.integer(Sys.getenv("BENCHMARK_MAX_SELECTED_NEWS", config$max_selected))

run_started_at <- Sys.time()
dir.create(config$output_dir, showWarnings = FALSE, recursive = TRUE)

collectors <- news_collectors()

stages <- list()
stages$collect <- measure_stage("collect", {
  purrr::imap(collectors, ~ collect_source_safely(.y, .x, config))
})

source_results <- stages$collect$value
status_tbl <- source_status_table(source_results)
all_items <- purrr::map_dfr(source_results, "items")

stages$deduplicate_exact <- measure_stage("deduplicate_exact", {
  all_items |>
    dplyr::filter(is.na(.data$discard_reason) | .data$discard_reason == "") |>
    deduplicate_exact()
})

candidates <- stages$deduplicate_exact$value
stages$rank <- measure_stage("rank", rank_news(candidates, config))
ranked <- stages$rank$value
stages$deduplicate_fuzzy <- measure_stage("deduplicate_fuzzy", deduplicate_ranked(ranked))
deduped <- stages$deduplicate_fuzzy$value
stages$select <- measure_stage("select", select_for_clipping(deduped, config))
selected <- stages$select$value
stages$summarize <- measure_stage("summarize", summarize_selected(selected, config))
summarized <- stages$summarize$value
stages$render <- measure_stage("render", render_email_html(summarized, status_tbl, config))
html <- stages$render$value
html_path <- write_email_html(html, run_started_at, config)

stage_rows <- tibble::tibble(
  stage = names(stages),
  elapsed_sec = purrr::map_dbl(stages, "elapsed_sec"),
  started_at = purrr::map_chr(stages, "started_at"),
  finished_at = purrr::map_chr(stages, "finished_at")
)

stamp <- format(run_started_at, "%Y%m%d-%H%M%S")
csv_path <- file.path(config$output_dir, paste0("benchmark-", stamp, ".csv"))
json_path <- file.path(config$output_dir, paste0("benchmark-", stamp, ".json"))

utils::write.csv(stage_rows, csv_path, row.names = FALSE, fileEncoding = "UTF-8")
jsonlite::write_json(
  list(
    run_started_at = format(run_started_at, "%Y-%m-%dT%H:%M:%S%z"),
    timezone = config$timezone,
    timezone_label = config$timezone_label,
    limits = list(
      max_candidates_per_source = config$max_candidates_per_source,
      cnn_max_pages = config$cnn_max_pages,
      iff_max_pages = config$iff_max_pages,
      uenf_max_pages = config$uenf_max_pages,
      news_per_source = config$news_per_source,
      max_selected = config$max_selected
    ),
    source_status = status_tbl,
    candidates = nrow(candidates),
    ranked = nrow(ranked),
    selected = nrow(selected),
    stages = stage_rows,
    artifacts = list(html = basename(html_path), benchmark_csv = basename(csv_path))
  ),
  json_path,
  pretty = TRUE,
  auto_unbox = TRUE,
  dataframe = "rows"
)

cat("Benchmark completed.\n")
cat("HTML:", normalizePath(html_path, winslash = "/", mustWork = FALSE), "\n")
cat("Benchmark CSV:", normalizePath(csv_path, winslash = "/", mustWork = FALSE), "\n")
cat("Benchmark JSON:", normalizePath(json_path, winslash = "/", mustWork = FALSE), "\n")
