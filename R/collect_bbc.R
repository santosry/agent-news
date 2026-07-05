collect_bbc <- function(config) {
  feeds <- c(
    "https://feeds.bbci.co.uk/news/rss.xml",
    "https://feeds.bbci.co.uk/news/world/rss.xml",
    "https://feeds.bbci.co.uk/news/business/rss.xml",
    "https://feeds.bbci.co.uk/news/health/rss.xml",
    "https://feeds.bbci.co.uk/news/science_and_environment/rss.xml",
    "https://feeds.bbci.co.uk/news/technology/rss.xml",
    "https://feeds.bbci.co.uk/news/politics/rss.xml"
  )

  rows <- purrr::map(feeds, function(feed) {
    tryCatch({
      resp <- http_get(feed, timeout = config$source_timeout)
      doc <- xml2::read_xml(response_text(resp))
      items <- xml2::xml_find_all(doc, "//item")

      purrr::map_dfr(seq_along(items), function(i) {
        item <- items[[i]]
        title <- clean_text(xml2::xml_text(xml2::xml_find_first(item, "title")))
        url <- clean_text(xml2::xml_text(xml2::xml_find_first(item, "link")))
        description <- clean_text(strip_html(xml2::xml_text(xml2::xml_find_first(item, "description"))))
        pub_date <- clean_text(xml2::xml_text(xml2::xml_find_first(item, "pubDate")))
        published_at <- parse_datetime_sao(pub_date, tz = config$timezone)

        tibble::tibble(
          id = stable_id("BBC News", url),
          source = "BBC News",
          title = title,
          url = url,
          published_at = published_at,
          modified_at = as.POSIXct(NA),
          date_kind = "published",
          date_source = "rss_pubDate",
          excerpt = description,
          keywords = "",
          raw_source = feed,
          discard_reason = NA_character_
        )
      })
    }, error = function(e) {
      log_warn("BBC feed failed: {feed} - {conditionMessage(e)}")
      tibble::tibble()
    })
  }) |>
    dplyr::bind_rows()

  rows <- rows |>
    dplyr::filter(!is.na(.data$title), .data$title != "", !is.na(.data$url), .data$url != "") |>
    dplyr::distinct(.data$url, .keep_all = TRUE)

  finish_source_result("BBC News", rows, raw_count = nrow(rows), config = config)
}
