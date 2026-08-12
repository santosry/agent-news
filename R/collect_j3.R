collect_j3 <- function(config) {
  # Strategy: WordPress REST API first, HTML scraping as fallback
  rows <- collect_j3_api(config)
  if (nrow(rows) == 0) {
    log_info("J3News API returned no items, falling back to HTML scraping")
    rows <- collect_j3_html(config)
  }
  finish_source_result("J3News", rows, raw_count = nrow(rows), config = config)
}

collect_j3_api <- function(config) {
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

    resp <- tryCatch(http_get(url, timeout = config$source_timeout), error = function(e) {
      log_warn("J3News API page {page} failed: {conditionMessage(e)}")
      NULL
    })
    if (is.null(resp)) break

    page_items <- tryCatch(jsonlite::fromJSON(response_text(resp), simplifyVector = FALSE), error = function(e) {
      log_warn("J3News API page {page} JSON parse failed: {conditionMessage(e)}")
      list()
    })
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
    if (length(page_dates) > 0 && max(page_dates) < config$window_start) break

    total_pages <- suppressWarnings(as.integer(httr2::resp_header(resp, "x-wp-totalpages")))
    if (!is.na(total_pages) && page >= total_pages) break
  }

  dplyr::bind_rows(rows)
}

collect_j3_html <- function(config) {
  pages <- c("https://j3news.com/", "https://j3news.com/ultimas-noticias/")
  purrr::map(pages, function(page_url) {
    tryCatch({
      doc <- read_html_url(page_url, timeout = config$source_timeout)
      links <- rvest::html_elements(doc, "a[href]")
      href <- rvest::html_attr(links, "href")
      title <- clean_text(rvest::html_text2(links))
      url <- xml2::url_absolute(href, page_url)
      news_pattern <- stringr::str_detect(url, "j3news[.]com/") & nzchar(title) & nchar(title) >= 20
      url <- unique(url[news_pattern])
      title <- title[news_pattern]

      if (length(url) == 0) return(tibble::tibble())

      unique_idx <- !duplicated(url)
      url <- url[unique_idx]
      title <- title[unique_idx]

      purrr::map2_dfr(utils::head(url, 30), utils::head(title, 30), function(u, t) {
        tibble::tibble(
          id = stable_id("J3News", u),
          source = "J3News",
          title = t,
          url = u,
          published_at = as.POSIXct(NA, tz = config$timezone),
          modified_at = as.POSIXct(NA),
          date_kind = "published",
          date_source = "html_fallback_no_date",
          excerpt = "",
          keywords = "",
          raw_source = page_url,
          discard_reason = NA_character_
        )
      })
    }, error = function(e) {
      log_warn("J3News HTML fallback failed for {page_url}: {conditionMessage(e)}")
      tibble::tibble()
    })
  }) |> dplyr::bind_rows()
}
