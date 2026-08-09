audit_rows <- function(items, run_started_at, selected_ids = character()) {
  if (nrow(items) == 0) {
    return(tibble::tibble())
  }

  items |>
    dplyr::mutate(
      run_started_at = format(run_started_at, "%Y-%m-%dT%H:%M:%S%z"),
      published_at = format(.data$published_at, "%Y-%m-%dT%H:%M:%S%z"),
      selected = .data$id %in% selected_ids
    ) |>
    dplyr::select(
      "run_started_at",
      "source",
      "title",
      "url",
      "published_at",
      "score",
      "topic",
      "selected",
      "discard_reason"
    )
}

write_audit <- function(items, run_started_at, selected_ids, config) {
  dir.create(config$output_dir, showWarnings = FALSE, recursive = TRUE)
  stamp <- format(run_started_at, "%Y%m%d-%H%M%S")
  rows <- audit_rows(items, run_started_at, selected_ids)
  csv_path <- file.path(config$output_dir, paste0("news-audit-", stamp, ".csv"))
  json_path <- file.path(config$output_dir, paste0("news-audit-", stamp, ".json"))

  utils::write.csv(rows, csv_path, row.names = FALSE, fileEncoding = "UTF-8")
  jsonlite::write_json(rows, json_path, pretty = TRUE, auto_unbox = TRUE, dataframe = "rows")

  list(csv_path = normalizePath(csv_path, winslash = "/", mustWork = FALSE),
       json_path = normalizePath(json_path, winslash = "/", mustWork = FALSE))
}

write_run_report <- function(status_tbl, selected, invariants, send_result, run_started_at, config, html_path, audit_paths) {
  dir.create(config$output_dir, showWarnings = FALSE, recursive = TRUE)
  stamp <- format(run_started_at, "%Y%m%d-%H%M%S")
  path <- file.path(config$output_dir, paste0("news-run-report-", stamp, ".json"))

  send_tbl <- send_result$per_recipient %||% tibble::tibble()
  safe_send <- if (nrow(send_tbl) == 0) {
    list()
  } else {
    apply(send_tbl, 1, as.list)
  }

  report <- list(
    run_started_at = format(run_started_at, "%Y-%m-%dT%H:%M:%S%z"),
    run_finished_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
    timezone = config$timezone,
    timezone_label = config$timezone_label,
    dry_run = config$dry_run,
    window_start = format(config$window_start, "%Y-%m-%dT%H:%M:%S%z"),
    window_end = format(config$window_end, "%Y-%m-%dT%H:%M:%S%z"),
    rank_model = config$rank_model,
    summary_model = config$summary_model,
    deepseek_configured = deepseek_available(config),
    allow_no_deepseek = isTRUE(config$allow_no_deepseek),
    email_transport = config$email_transport,
    recipients = config$recipients,
    invalid_recipients = config$invalid_recipients,
    source_status = status_tbl,
    selected_count = nrow(selected),
    selected_ids = selected$id %||% character(),
    invariants = invariants,
    send = list(
      dry_run = isTRUE(send_result$dry_run),
      any_success = isTRUE(send_result$any_success),
      per_recipient = safe_send
    ),
    artifacts = list(
      html = basename(html_path),
      audit_csv = basename(audit_paths$csv_path),
      audit_json = basename(audit_paths$json_path)
    )
  )

  jsonlite::write_json(report, path, pretty = TRUE, auto_unbox = TRUE, dataframe = "rows", null = "null")
  normalizePath(path, winslash = "/", mustWork = FALSE)
}
