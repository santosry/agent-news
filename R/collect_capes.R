# Coletor: CAPES --------------------------------------------------------------
#
# Fonte editorial: Coordenação de Aperfeiçoamento de Pessoal de Nível Superior (CAPES)
# Domínio: www.gov.br/capes
#
# Método primário: scraping HTML da página principal (destaques de notícias
#   renderizados no servidor) + busca de metadados em cada notícia.
#   Endpoint: https://www.gov.br/capes/pt-br
# Método de fallback: tentativa de RSS oficial (https://www.gov.br/capes/rss.xml)
#   e da página de listagem de notícias.
#
# Estratégia de extração: descobre URLs de notícias (/assuntos/noticias*),
#   então busca título (og:title) e data ("effective") de cada página.
# Estratégia de data: primeiro campo "effective" do JSON embutido (Volto).
# Limitações conhecidas:
#   - Portal React/Volto; a seção de notícias fica sujeita a "defeso eleitoral".
#   - O WAF do gov.br pode bloquear IPs de datacenter (registra falha e tenta
#     o RSS como alternativa).
#   - A página principal expõe poucas notícias por vez.

collect_capes <- function(config) {
  rows <- collect_capes_articles(config)
  if (nrow(rows) == 0) {
    log_info("CAPES article collection returned no items, trying RSS fallback")
    rows <- collect_capes_rss(config)
  }
  finish_source_result("CAPES", rows, raw_count = nrow(rows), config = config)
}

capes_discovery_pages <- function() {
  c(
    "https://www.gov.br/capes/pt-br",
    "https://www.gov.br/capes/pt-br/assuntos/noticias-defeso-eleitoral",
    "https://www.gov.br/capes/pt-br/assuntos/noticias"
  )
}

collect_capes_articles <- function(config) {
  urls <- character()
  for (page in capes_discovery_pages()) {
    tryCatch({
      doc <- read_html_url(page, timeout = config$source_timeout)
      urls <- c(urls, capes_discover_urls(doc, page))
    }, error = function(e) {
      log_warn("CAPES discovery failed for {page}: {conditionMessage(e)}")
    })
  }

  urls <- unique(urls)
  urls <- utils::head(urls, config$max_candidates_per_source)
  if (length(urls) == 0) return(empty_news_tbl())

  purrr::map_dfr(urls, function(u) fetch_capes_article(u, config))
}

capes_discover_urls <- function(doc, base) {
  href <- rvest::html_attr(rvest::html_elements(doc, "a[href]"), "href")
  url <- xml2::url_absolute(href, base)
  # Apenas notícias (pasta + slug), excluindo a pasta de listagem em si.
  url <- url[stringr::str_detect(url, "/assuntos/noticias")]
  url <- url[stringr::str_detect(url, "noticias[^/]*/[a-z0-9][a-z0-9-]+$")]
  unique(url)
}

fetch_capes_article <- function(url, config) {
  tryCatch({
    resp <- http_get(url, timeout = config$source_timeout, accept = "text/html")
    parse_capes_article(response_text(resp), url, config)
  }, error = function(e) {
    log_warn("CAPES article failed: {url} - {conditionMessage(e)}")
    tibble::tibble()
  })
}

parse_capes_article <- function(html_text, url, config) {
  if (is.null(html_text) || length(html_text) == 0 || is.na(html_text[[1]]) || !nzchar(html_text[[1]])) {
    return(empty_news_tbl())
  }
  doc <- tryCatch(xml2::read_html(html_text[[1]], encoding = "UTF-8"), error = function(e) NULL)
  if (is.null(doc)) return(empty_news_tbl())

  title <- extract_meta(doc, property = "og:title")
  if (is.na(title) || !nzchar(title)) {
    title <- clean_text(xml2::xml_text(xml2::xml_find_first(doc, "//h1")))
  }
  excerpt <- extract_meta(doc, property = "og:description")
  effective <- stringr::str_match(html_text[[1]], '"effective"\\s*:\\s*"([^"]+)"')[, 2]

  tibble::tibble(
    id = stable_id("CAPES", url),
    source = "CAPES",
    title = clean_text(title),
    url = url,
    published_at = parse_datetime_sao(effective, tz = config$timezone),
    modified_at = as.POSIXct(NA),
    date_kind = "published",
    date_source = "volto_effective",
    excerpt = clean_text(excerpt),
    keywords = "",
    raw_source = url,
    discard_reason = NA_character_
  ) |>
    dplyr::filter(nzchar(.data$title), nzchar(.data$url))
}

collect_capes_rss <- function(config) {
  feed_url <- "https://www.gov.br/capes/rss.xml"
  tryCatch({
    resp <- http_get(
      feed_url,
      timeout = config$source_timeout,
      accept = "application/atom+xml,application/rss+xml,text/xml,application/xml"
    )
    parse_feed_entries(response_text(resp), "CAPES", config)
  }, error = function(e) {
    log_warn("CAPES RSS fallback failed: {feed_url} - {conditionMessage(e)}")
    tibble::tibble()
  })
}
