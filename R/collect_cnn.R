collect_cnn <- function(config) {
  sitemap_url <- "https://admin.cnnbrasil.com.br/sitemap-news.xml"

  sitemap_rows <- tryCatch({
    resp <- http_get(sitemap_url, timeout = config$source_timeout)
    doc <- xml2::read_xml(response_text(resp))
    ns <- c(
      sm = "http://www.sitemaps.org/schemas/sitemap/0.9",
      news = "http://www.google.com/schemas/sitemap-news/0.9"
    )
    urls <- xml2::xml_find_all(doc, ".//sm:url", ns)

    purrr::map_dfr(seq_along(urls), function(i) {
      node <- urls[[i]]
      url <- clean_text(xml2::xml_text(xml2::xml_find_first(node, "sm:loc", ns)))
      title <- clean_text(xml2::xml_text(xml2::xml_find_first(node, ".//news:title", ns)))
      keywords <- clean_text(xml2::xml_text(xml2::xml_find_first(node, ".//news:keywords", ns)))
      pub <- clean_text(xml2::xml_text(xml2::xml_find_first(node, ".//news:publication_date", ns)))
      published_at <- parse_datetime_sao(pub, tz = config$timezone)
      modified_at <- parse_datetime_sao(clean_text(xml2::xml_text(xml2::xml_find_first(node, "sm:lastmod", ns))), tz = config$timezone)

      tibble::tibble(
        id = stable_id("CNN Brasil", url),
        source = "CNN Brasil",
        title = title,
        url = url,
        published_at = published_at,
        modified_at = modified_at,
        date_kind = "published",
        date_source = "news_sitemap_publication_date",
        excerpt = keywords,
        keywords = keywords,
        raw_source = sitemap_url,
        discard_reason = NA_character_
      )
    })
  }, error = function(e) {
    log_warn("CNN sitemap failed: {conditionMessage(e)}")
    tibble::tibble()
  })

  page_rows <- collect_cnn_public_pages(config)

  rows <- dplyr::bind_rows(sitemap_rows, page_rows)
  rows <- rows |>
    dplyr::filter(!is.na(.data$title), .data$title != "", !is.na(.data$url), .data$url != "") |>
    dplyr::distinct(.data$url, .keep_all = TRUE)

  finish_source_result("CNN Brasil", rows, raw_count = nrow(sitemap_rows) + nrow(page_rows), config = config)
}

collect_cnn_public_pages <- function(config) {
  rows <- list()
  seen <- character()

  for (page in seq_len(config$cnn_max_pages)) {
    page_url <- if (page == 1) {
      "https://www.cnnbrasil.com.br/ultimas-noticias/"
    } else {
      paste0("https://www.cnnbrasil.com.br/ultimas-noticias/pagina/", page, "/")
    }

    links <- tryCatch({
      doc <- read_html_url(page_url, timeout = config$source_timeout)
      href <- rvest::html_attr(rvest::html_elements(doc, "a[href]"), "href")
      url <- xml2::url_absolute(href, page_url)
      url <- url[stringr::str_detect(url, "^https://www[.]cnnbrasil[.]com[.]br/.+/$")]
      url <- url[!stringr::str_detect(url, "/(ultimas-noticias|ao-vivo|tudo-sobre|tag|author|videos|newsletter|podcasts|termos-de-uso|politica-de-privacidade)(/|$)")]
      unique(url)
    }, error = function(e) {
      log_warn("CNN public page failed: {page_url} - {conditionMessage(e)}")
      character()
    })

    links <- setdiff(links, seen)
    seen <- union(seen, links)
    links <- utils::head(links, 24)
    if (length(links) == 0) next

    page_items <- purrr::map_dfr(links, fetch_cnn_article_metadata, config = config, raw_source = page_url)
    rows[[page]] <- page_items

    valid_dates <- page_items$published_at[!is.na(page_items$published_at)]
    if (page > 1 && length(valid_dates) > 0 && max(valid_dates) < config$window_start) {
      break
    }
  }

  dplyr::bind_rows(rows)
}

fetch_cnn_article_metadata <- function(url, config, raw_source) {
  tryCatch({
    doc <- read_html_url(url, timeout = config$source_timeout)
    title <- extract_meta(doc, property = "og:title")
    if (is.na(title)) title <- xml2::xml_text(xml2::xml_find_first(doc, "//title"))
    title <- clean_text(stringr::str_remove(title, "\\s*\\|\\s*CNN Brasil\\s*$"))
    excerpt <- extract_meta(doc, property = "og:description")
    if (is.na(excerpt)) excerpt <- extract_meta(doc, name = "description")
    published <- extract_meta(doc, property = "article:published_time")
    modified <- extract_meta(doc, property = "article:modified_time")

    tibble::tibble(
      id = stable_id("CNN Brasil", url),
      source = "CNN Brasil",
      title = title,
      url = url,
      published_at = parse_datetime_sao(published, tz = config$timezone),
      modified_at = parse_datetime_sao(modified, tz = config$timezone),
      date_kind = "published",
      date_source = "html_meta_article:published_time",
      excerpt = clean_text(excerpt),
      keywords = "",
      raw_source = raw_source,
      discard_reason = NA_character_
    )
  }, error = function(e) {
    log_warn("CNN article metadata failed: {url} - {conditionMessage(e)}")
    tibble::tibble()
  })
}
