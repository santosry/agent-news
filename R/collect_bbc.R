collect_bbc <- function(config) {
  # Strategy: try RSS feeds first, fall back to HTML scraping
  rows <- collect_bbc_rss(config)

  if (nrow(rows) == 0) {
    log_info("BBC RSS feeds returned no items, falling back to HTML scraping")
    rows <- collect_bbc_html(config)
  }

  rows <- rows |>
    dplyr::filter(!is.na(.data$title), .data$title != "", !is.na(.data$url), .data$url != "") |>
    dplyr::distinct(.data$url, .keep_all = TRUE)

  finish_source_result("BBC News", rows, raw_count = nrow(rows), config = config)
}

collect_bbc_rss <- function(config) {
  feeds <- c(
    "https://feeds.bbci.co.uk/news/rss.xml",
    "https://feeds.bbci.co.uk/news/world/rss.xml",
    "https://feeds.bbci.co.uk/news/business/rss.xml",
    "https://feeds.bbci.co.uk/news/health/rss.xml",
    "https://feeds.bbci.co.uk/news/science_and_environment/rss.xml",
    "https://feeds.bbci.co.uk/news/technology/rss.xml",
    "https://feeds.bbci.co.uk/news/politics/rss.xml"
  )

  purrr::map(feeds, function(feed) {
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
}

collect_bbc_html <- function(config) {
  # Fallback: scrape BBC News homepage sections
  sections <- c(
    "https://www.bbc.com/news",
    "https://www.bbc.com/news/world",
    "https://www.bbc.com/news/health",
    "https://www.bbc.com/news/science_and_environment",
    "https://www.bbc.com/news/technology",
    "https://www.bbc.com/news/business"
  )

  purrr::map(sections, function(section_url) {
    tryCatch({
      doc <- read_html_url(section_url, timeout = config$source_timeout)
      # BBC uses script[type="application/ld+json"] for article metadata
      json_ld <- extract_json_ld(doc)
      article_data <- purrr::keep(json_ld, ~ !is.null(.x$`@type`) && .x$`@type` == "NewsArticle")

      if (length(article_data) == 0) {
        # Fallback: extract links from headline elements
        links <- rvest::html_elements(doc, "a[href]")
        href <- rvest::html_attr(links, "href")
        url <- xml2::url_absolute(href, section_url)
        title <- clean_text(rvest::html_text2(links))
        news_pattern <- "^https://www[.]bbc[.]com/news/articles/"
        news_idx <- stringr::str_detect(url, news_pattern) & nzchar(title) & nchar(title) >= 20
        url <- url[news_idx]
        title <- title[news_idx]

        if (length(url) == 0) return(tibble::tibble())

        purrr::map2_dfr(url, title, function(u, t) {
          tibble::tibble(
            id = stable_id("BBC News", u),
            source = "BBC News",
            title = t,
            url = u,
            published_at = as.POSIXct(NA, tz = config$timezone),
            modified_at = as.POSIXct(NA),
            date_kind = "published",
            date_source = "html_fallback_no_date",
            excerpt = "",
            keywords = "",
            raw_source = section_url,
            discard_reason = NA_character_
          )
        })
      } else {
        purrr::map_dfr(article_data, function(ad) {
          pub_str <- ad$datePublished %||% ad$dateModified %||% NA_character_
          pub_date <- parse_datetime_sao(pub_str, tz = config$timezone)
          tibble::tibble(
            id = stable_id("BBC News", ad$url %||% ""),
            source = "BBC News",
            title = clean_text(ad$headline %||% ad$name %||% ""),
            url = ad$url %||% "",
            published_at = pub_date,
            modified_at = parse_datetime_sao(ad$dateModified %||% NA_character_, tz = config$timezone),
            date_kind = "published",
            date_source = "html_json_ld",
            excerpt = clean_text(ad$description %||% ""),
            keywords = "",
            raw_source = section_url,
            discard_reason = NA_character_
          )
        })
      }
    }, error = function(e) {
      log_warn("BBC HTML fallback failed for {section_url}: {conditionMessage(e)}")
      tibble::tibble()
    })
  }) |>
    dplyr::bind_rows()
}
