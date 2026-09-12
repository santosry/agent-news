# Coletor: AHA ----------------------------------------------------------------
#
# Fonte editorial: American Heart Association (AHA)
# Domínio: newsroom.heart.org
#
# Método primário: RSS oficial do newsroom.
#   Endpoint: https://newsroom.heart.org/rss.xml
# Método de fallback: scraping HTML da página de notícias do newsroom.
#
# Estratégia de extração: parse_feed_entries() sobre o RSS 2.0.
# Estratégia de data: <pubDate> (RSS 2.0).
# Limitações conhecidas:
#   - O portal de periódicos (ahajournals.org) é protegido contra bots (403);
#     usamos apenas o newsroom oficial (comunicados e notícias de pesquisa).
#   - Declarações científicas/guidelines completos ficam nos periódicos; o
#     newsroom cobre os comunicados associados.

collect_aha <- function(config) {
  rows <- collect_aha_rss(config)
  if (nrow(rows) == 0) {
    log_info("AHA RSS returned no items, falling back to HTML scraping")
    rows <- collect_aha_html(config)
  }
  finish_source_result("AHA", rows, raw_count = nrow(rows), config = config)
}

collect_aha_rss <- function(config) {
  feed_url <- "https://newsroom.heart.org/rss.xml"
  tryCatch({
    resp <- http_get(
      feed_url,
      timeout = config$source_timeout,
      accept = "application/rss+xml,application/atom+xml,text/xml,application/xml"
    )
    parse_aha_rss(response_text(resp), config)
  }, error = function(e) {
    log_warn("AHA RSS feed failed: {feed_url} - {conditionMessage(e)}")
    tibble::tibble()
  })
}

parse_aha_rss <- function(xml_text, config) {
  rows <- parse_feed_entries(xml_text, "AHA", config)
  if (nrow(rows) == 0) return(rows)
  rows |>
    dplyr::mutate(raw_source = "https://newsroom.heart.org/rss.xml")
}

collect_aha_html <- function(config) {
  pages <- c("https://newsroom.heart.org/news", "https://newsroom.heart.org/rss")
  purrr::map(pages, function(page_url) {
    tryCatch({
      doc <- read_html_url(page_url, timeout = config$source_timeout)
      parse_aha_html(doc, page_url, config)
    }, error = function(e) {
      log_warn("AHA HTML fallback failed for {page_url}: {conditionMessage(e)}")
      tibble::tibble()
    })
  }) |>
    dplyr::bind_rows() |>
    dplyr::distinct(.data$url, .keep_all = TRUE)
}

parse_aha_html <- function(doc, base, config) {
  links <- rvest::html_elements(doc, "a[href]")
  href <- rvest::html_attr(links, "href")
  title <- clean_text(rvest::html_text2(links))
  url <- xml2::url_absolute(href, base)
  keep <- stringr::str_detect(url, "newsroom[.]heart[.]org/") &
    nzchar(title) & nchar(title) >= 25
  url <- unique(url[keep])
  title <- title[keep]
  if (length(url) == 0) return(empty_news_tbl())

  n <- min(length(url), config$max_candidates_per_source)
  purrr::map2_dfr(utils::head(url, n), utils::head(title, n), function(u, t) {
    tibble::tibble(
      id = stable_id("AHA", u),
      source = "AHA",
      title = t,
      url = u,
      published_at = as.POSIXct(NA, tz = config$timezone),
      modified_at = as.POSIXct(NA),
      date_kind = "published",
      date_source = "html_fallback_no_date",
      excerpt = "",
      keywords = "",
      raw_source = base,
      discard_reason = NA_character_
    )
  })
}
