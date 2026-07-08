collect_uenf <- function(config) {
  feed_url <- "https://uenf.br/portal/categoria/noticias/feed/"

  feed_rows <- tryCatch({
    collect_uenf_feed(feed_url, config)
  }, error = function(e) {
    log_warn("UENF feed failed: {feed_url} - {conditionMessage(e)}")
    tibble::tibble()
  })

  page_rows <- purrr::map_dfr(seq_len(config$uenf_max_pages), function(page) {
    url <- if (page == 1L) "https://uenf.br/portal/noticias/" else paste0("https://uenf.br/portal/noticias/", page, "/")
    tryCatch(collect_uenf_page(url, config), error = function(e) {
      log_warn("UENF page failed: {url} - {conditionMessage(e)}")
      tibble::tibble()
    })
  })

  rows <- dplyr::bind_rows(feed_rows, page_rows) |>
    dplyr::filter(!is.na(.data$title), .data$title != "", !is.na(.data$url), .data$url != "") |>
    dplyr::distinct(.data$url, .keep_all = TRUE) |>
    dplyr::arrange(dplyr::desc(.data$published_at)) |>
    utils::head(config$max_candidates_per_source)

  finish_source_result("UENF", rows, raw_count = nrow(feed_rows) + nrow(page_rows), config = config)
}

collect_uenf_feed <- function(feed_url, config) {
  resp <- http_get(feed_url, timeout = config$source_timeout, accept = "application/rss+xml,text/xml,application/xml")
  doc <- xml2::read_xml(response_text(resp))
  items <- xml2::xml_find_all(doc, "//item")

  purrr::map_dfr(seq_along(items), function(i) {
    item <- items[[i]]
    title <- clean_text(xml2::xml_text(xml2::xml_find_first(item, "title")))
    link <- clean_text(xml2::xml_text(xml2::xml_find_first(item, "link")))
    description <- clean_text(strip_html(xml2::xml_text(xml2::xml_find_first(item, "description"))))
    content <- clean_text(strip_html(xml2::xml_text(xml2::xml_find_first(item, ".//*[local-name()='encoded']"))))
    pub_date <- clean_text(xml2::xml_text(xml2::xml_find_first(item, "pubDate")))
    published_at <- parse_datetime_sao(pub_date, tz = config$timezone)
    categories <- clean_text(paste(xml2::xml_text(xml2::xml_find_all(item, "category")), collapse = ", "))

    tibble::tibble(
      id = stable_id("UENF", link),
      source = "UENF",
      title = title,
      url = link,
      published_at = published_at,
      modified_at = as.POSIXct(NA),
      date_kind = "published",
      date_source = "rss_pubDate",
      excerpt = if (!is.na(content) && nzchar(content)) substr(content, 1, 1200) else description,
      keywords = categories,
      raw_source = feed_url,
      discard_reason = NA_character_
    )
  })
}

collect_uenf_page <- function(url, config) {
  doc <- read_html_url(url, timeout = config$source_timeout)
  blocks <- rvest::html_elements(doc, xpath = "//*[contains(concat(' ', normalize-space(@class), ' '), ' e-loop-item ') and contains(concat(' ', normalize-space(@class), ' '), ' category-noticias ')]")
  if (length(blocks) == 0) return(tibble::tibble())

  purrr::map_dfr(seq_along(blocks), function(i) {
    block <- blocks[[i]]
    link_node <- rvest::html_element(block, "h2 a[href]")
    title <- clean_text(rvest::html_text2(link_node))
    link <- clean_text(xml2::url_absolute(rvest::html_attr(link_node, "href"), url))
    block_text <- clean_text(rvest::html_text2(block))
    date_value <- stringr::str_match(block_text, "([0-9]{2}/[0-9]{2}/[0-9]{4})")[, 2]
    excerpt <- clean_text(rvest::html_text2(rvest::html_element(block, ".elementor-widget-theme-post-excerpt, .elementor-post__excerpt")))
    if (is.na(excerpt) || !nzchar(excerpt)) {
      excerpt <- clean_text(stringr::str_remove(block_text, "^Notícias\\s+"))
      excerpt <- stringr::str_remove(excerpt, paste0("^", stringr::str_replace_all(title, "([\\W])", "\\\\\\1"), "\\s*"))
      excerpt <- stringr::str_remove(excerpt, "[0-9]{2}/[0-9]{2}/[0-9]{4}\\s*$")
    }

    tibble::tibble(
      id = stable_id("UENF", link),
      source = "UENF",
      title = title,
      url = link,
      published_at = parse_datetime_sao(date_value, tz = config$timezone, date_only_hour = 12),
      modified_at = as.POSIXct(NA),
      date_kind = "published",
      date_source = "uenf_listing_date",
      excerpt = excerpt,
      keywords = "Notícias",
      raw_source = url,
      discard_reason = NA_character_
    )
  })
}
