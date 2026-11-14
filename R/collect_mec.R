collect_mec <- function(config) {
  # gov.br MEC uses Plone listagens. O layout atual (2026) usa
  # "collection-item" + <time datetime="...">; o layout antigo usava
  # "tileItem" + summary-view-icon. plone_listing_rows suporta ambos.
  base_urls <- c(
    "https://www.gov.br/mec/pt-br/assuntos/noticias",
    "https://www.gov.br/mec/pt-br/assuntos/noticias/noticias"
  )
  per_page <- 30L
  raw_count <- 0L

  for (base in base_urls) {
    rows <- list()

    for (page in seq_len(3L)) {
      offset <- (page - 1L) * per_page
      url <- paste0(base, "?b_start:int=", offset)

      page_rows <- tryCatch({
        doc <- read_html_url(url, timeout = config$source_timeout)
        plone_listing_rows(doc, "MEC", base, url, config)
      }, error = function(e) {
        log_warn("MEC page failed: {url} - {conditionMessage(e)}")
        empty_news_tbl()
      })

      raw_count <- raw_count + nrow(page_rows)
      rows[[page]] <- page_rows

      page_dates <- page_rows$published_at[!is.na(page_rows$published_at)]
      if (nrow(page_rows) == 0 || (length(page_dates) > 0 && max(page_dates) < config$window_start)) {
        break
      }
    }

    all_rows <- dplyr::bind_rows(rows) |>
      dplyr::filter(!is.na(.data$title), .data$title != "", !is.na(.data$url), .data$url != "") |>
      dplyr::distinct(.data$url, .keep_all = TRUE)

    if (nrow(all_rows) > 0) {
      return(finish_source_result(
        "MEC",
        utils::head(all_rows, config$max_candidates_per_source),
        raw_count = raw_count,
        config = config
      ))
    }
  }

  finish_source_result("MEC", empty_news_tbl(), raw_count = raw_count, config = config)
}
