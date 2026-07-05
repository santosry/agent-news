collect_source_safely <- function(source_name, fun, config) {
  started <- Sys.time()
  log_info("Starting source: {source_name}")

  result <- tryCatch(
    fun(config),
    error = function(e) {
      list(
        source = source_name,
        status = "failed",
        items = empty_news_tbl(),
        raw_count = 0L,
        valid_date_count = 0L,
        in_window_count = 0L,
        diagnostics = conditionMessage(e),
        started_at = started,
        ended_at = Sys.time()
      )
    }
  )

  result$started_at <- started
  result$ended_at <- Sys.time()
  result$elapsed_sec <- as.numeric(difftime(result$ended_at, result$started_at, units = "secs"))

  log_info(
    "{source_name}: status={result$status}; raw={result$raw_count}; valid_date={result$valid_date_count}; in_window={result$in_window_count}; elapsed={round(result$elapsed_sec, 1)}s"
  )
  result
}

finish_source_result <- function(source_name, rows, raw_count, config) {
  if (is.null(rows) || nrow(rows) == 0) {
    return(list(
      source = source_name,
      status = "no_items",
      items = empty_news_tbl(),
      raw_count = raw_count,
      valid_date_count = 0L,
      in_window_count = 0L,
      diagnostics = "No candidate items discovered.",
      started_at = Sys.time(),
      ended_at = Sys.time()
    ))
  }

  rows <- normalize_news_tbl(rows)
  valid_date_count <- sum(!is.na(rows$published_at))
  rows <- rows |>
    dplyr::mutate(
      discard_reason = dplyr::case_when(
        is.na(.data$published_at) ~ "date_not_validated",
        !is_in_window(.data$published_at, config$window_start, config$window_end) ~ "outside_7_day_window",
        TRUE ~ .data$discard_reason
      )
    )

  in_window <- rows |>
    dplyr::filter(is.na(.data$discard_reason) | .data$discard_reason == "")

  status <- dplyr::case_when(
    valid_date_count == 0 ~ "no_valid_dates",
    nrow(in_window) == 0 ~ "no_window_items",
    TRUE ~ "ok"
  )

  list(
    source = source_name,
    status = status,
    items = rows,
    raw_count = raw_count,
    valid_date_count = valid_date_count,
    in_window_count = nrow(in_window),
    diagnostics = NA_character_,
    started_at = Sys.time(),
    ended_at = Sys.time()
  )
}

empty_news_tbl <- function() {
  tibble::tibble(
    id = character(),
    source = character(),
    title = character(),
    url = character(),
    published_at = as.POSIXct(character()),
    modified_at = as.POSIXct(character()),
    date_kind = character(),
    date_source = character(),
    excerpt = character(),
    keywords = character(),
    raw_source = character(),
    discard_reason = character()
  )
}

normalize_news_tbl <- function(rows) {
  rows |>
    dplyr::mutate(
      title = clean_text(.data$title),
      url = clean_text(.data$url),
      excerpt = clean_text(.data$excerpt),
      keywords = clean_text(.data$keywords),
      title_norm = normalize_title(.data$title)
    ) |>
    dplyr::filter(.data$title != "", .data$url != "") |>
    dplyr::distinct(.data$url, .keep_all = TRUE)
}
