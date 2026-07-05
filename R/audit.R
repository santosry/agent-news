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
