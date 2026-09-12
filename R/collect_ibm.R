# Coletor: IBM ----------------------------------------------------------------
#
# Fonte editorial: IBM
# Domínios: newsroom.ibm.com e research.ibm.com
#
# Método primário: feeds RSS oficiais (comunicados + pesquisa).
#   Endpoints:
#     - https://newsroom.ibm.com/announcements?pagetemplate=rss
#     - https://research.ibm.com/rss
# Método de fallback: scraping HTML do newsroom.
#
# Estratégia de extração: parse_feed_entries() sobre os dois feeds RSS.
# Estratégia de data: <pubDate> (RSS 2.0).
# Limitações conhecidas:
#   - O feed de pesquisa (research.ibm.com/rss) exige header Accept apropriado;
#     o newsroom expõe comunicados com <description> resumido.
#   - Conteúdo comercial/produto é preterido em favor de notícias editoriais
#     (research/newsroom); o ranking faz a filtragem final.

collect_ibm <- function(config) {
  rows <- collect_ibm_rss(config)
  if (nrow(rows) == 0) {
    log_info("IBM RSS feeds returned no items, falling back to HTML scraping")
    rows <- collect_ibm_html(config)
  }
  finish_source_result("IBM", rows, raw_count = nrow(rows), config = config)
}

ibm_feed_urls <- function() {
  c(
    "https://newsroom.ibm.com/announcements?pagetemplate=rss",
    "https://research.ibm.com/rss"
  )
}

collect_ibm_rss <- function(config) {
  purrr::map(ibm_feed_urls(), function(feed_url) {
    tryCatch({
      resp <- http_get(
        feed_url,
        timeout = config$source_timeout,
        accept = "application/rss+xml,application/atom+xml,text/xml,application/xml"
      )
      parse_ibm_rss(response_text(resp), config, feed_url)
    }, error = function(e) {
      log_warn("IBM RSS feed failed: {feed_url} - {conditionMessage(e)}")
      tibble::tibble()
    })
  }) |>
    dplyr::bind_rows() |>
    dplyr::distinct(.data$url, .keep_all = TRUE)
}

parse_ibm_rss <- function(xml_text, config, raw_source = "https://newsroom.ibm.com/") {
  rows <- parse_feed_entries(xml_text, "IBM", config)
  if (nrow(rows) == 0) return(rows)
  rows |>
    dplyr::mutate(raw_source = raw_source)
}

collect_ibm_html <- function(config) {
  pages <- c("https://newsroom.ibm.com/", "https://research.ibm.com/blog")
  purrr::map(pages, function(page_url) {
    tryCatch({
      doc <- read_html_url(page_url, timeout = config$source_timeout)
      parse_ibm_html(doc, page_url, config)
    }, error = function(e) {
      log_warn("IBM HTML fallback failed for {page_url}: {conditionMessage(e)}")
      tibble::tibble()
    })
  }) |>
    dplyr::bind_rows() |>
    dplyr::distinct(.data$url, .keep_all = TRUE)
}

parse_ibm_html <- function(doc, base, config) {
  links <- rvest::html_elements(doc, "a[href]")
  href <- rvest::html_attr(links, "href")
  title <- clean_text(rvest::html_text2(links))
  url <- xml2::url_absolute(href, base)
  keep <- (stringr::str_detect(url, "newsroom[.]ibm[.]com/") |
    stringr::str_detect(url, "research[.]ibm[.]com/blog/")) &
    nzchar(title) & nchar(title) >= 20
  url <- unique(url[keep])
  title <- title[keep]
  if (length(url) == 0) return(empty_news_tbl())

  n <- min(length(url), config$max_candidates_per_source)
  purrr::map2_dfr(utils::head(url, n), utils::head(title, n), function(u, t) {
    tibble::tibble(
      id = stable_id("IBM", u),
      source = "IBM",
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
