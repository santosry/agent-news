collect_j3 <- function(config) {
  base <- "https://j3news.com/wp-json/wp/v2/posts"
  per_page <- 50L
  max_pages <- config$j3_max_pages
  rows <- list()
  raw_count <- 0L

  for (page in seq_len(max_pages)) {
    url <- paste0(
      base,
      "?per_page=", per_page,
      "&page=", page,
      "&_fields=id,date,date_gmt,modified,title,excerpt,link"
    )

    resp <- http_get(url, timeout = config$source_timeout)
    page_items <- jsonlite::fromJSON(response_text(resp), simplifyVector = FALSE)
    if (length(page_items) == 0) break
    raw_count <- raw_count + length(page_items)

    page_rows <- purrr::map_dfr(page_items, function(item) {
      title <- clean_text(strip_html(item$title$rendered %||% ""))
      excerpt <- clean_text(strip_html(item$excerpt$rendered %||% ""))
      published_at <- parse_datetime_sao(item$date %||% NA_character_, tz = config$timezone)
      modified_at <- parse_datetime_sao(item$modified %||% NA_character_, tz = config$timezone)
      link <- item$link %||% ""

      tibble::tibble(
        id = paste0("j3-", item$id %||% stable_id("J3News", link)),
        source = "J3News",
        title = title,
        url = link,
        published_at = published_at,
        modified_at = modified_at,
        date_kind = "published",
        date_source = "wordpress_date",
        excerpt = excerpt,
        keywords = "",
        raw_source = base,
        discard_reason = NA_character_
      )
    })

    rows[[page]] <- page_rows

    page_dates <- page_rows$published_at[!is.na(page_rows$published_at)]
    if (length(page_dates) > 0 && max(page_dates) < config$window_start) {
      break
    }

    total_pages <- suppressWarnings(as.integer(httr2::resp_header(resp, "x-wp-totalpages")))
    if (!is.na(total_pages) && page >= total_pages) break
  }

  all_rows <- dplyr::bind_rows(rows)
  finish_source_result("J3News", all_rows, raw_count = raw_count, config = config)
}
