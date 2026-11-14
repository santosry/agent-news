collect_saude <- function(config) {
  # gov.br Saude usa o mesmo Plone do MEC. O helper cobre tanto o layout
  # antigo (tileItem) quanto o novo (collection-item).
  base_urls <- c(
    "https://www.gov.br/saude/pt-br/assuntos/noticias-ms",
    "https://www.gov.br/saude/pt-br/assuntos/noticias",
    "https://www.gov.br/saude/pt-br/assuntos/noticias/ultimas-noticias"
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
        plone_listing_rows(doc, "Minist\u00e9rio da Sa\u00fade", base, url, config)
      }, error = function(e) {
        log_warn("Saude page failed: {url} - {conditionMessage(e)}")
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
        "Minist\u00e9rio da Sa\u00fade",
        utils::head(all_rows, config$max_candidates_per_source),
        raw_count = raw_count,
        config = config
      ))
    }
  }

  finish_source_result("Minist\u00e9rio da Sa\u00fade", empty_news_tbl(), raw_count = raw_count, config = config)
}
