# Coletor: CNPq ---------------------------------------------------------------
#
# Fonte editorial: Conselho Nacional de Desenvolvimento Científico e Tecnológico (CNPq)
# Domínio: www.gov.br/cnpq
#
# Método primário: RSS/Atom oficial do portal gov.br (Plone).
#   Endpoint: https://www.gov.br/cnpq/rss.xml (retorna Atom <feed>/<entry>).
# Método de fallback: scraping HTML da página principal (destaques de notícias).
#
# Estratégia de extração: título, link e data (<published>) de cada <entry>,
#   reutilizando parse_feed_entries().
# Estratégia de data: <published> (ISO 8601 com offset) via parse_datetime_sao().
# Limitações conhecidas:
#   - A seção de notícias (/assuntos/noticias) responde "Conteúdo Restrito".
#   - O feed é site-wide e inclui itens administrativos (PDFs, "Áreas e Avaliação").
#   - Filtramos entradas sem título e URLs de PDF; o ranking/deduplicação faz o
#     filtro editorial restante.

collect_cnpq <- function(config) {
  rows <- collect_cnpq_feed(config)
  if (nrow(rows) == 0) {
    log_info("CNPq feed returned no items, falling back to HTML scraping")
    rows <- collect_cnpq_html(config)
  }
  finish_source_result("CNPq", rows, raw_count = nrow(rows), config = config)
}

collect_cnpq_feed <- function(config) {
  feed_url <- "https://www.gov.br/cnpq/rss.xml"
  tryCatch({
    resp <- http_get(
      feed_url,
      timeout = config$source_timeout,
      accept = "application/atom+xml,application/rss+xml,text/xml,application/xml"
    )
    parse_cnpq_feed(response_text(resp), config)
  }, error = function(e) {
    log_warn("CNPq feed failed: {feed_url} - {conditionMessage(e)}")
    tibble::tibble()
  })
}

# Pure parse: converte o XML do feed em linhas do schema canônico.
parse_cnpq_feed <- function(xml_text, config) {
  rows <- parse_feed_entries(xml_text, "CNPq", config)
  if (nrow(rows) == 0) return(rows)
  rows |>
    dplyr::filter(!stringr::str_detect(tolower(.data$url), "[.]pdf(\\?|$)|/@@download|/view$"))
}

collect_cnpq_html <- function(config) {
  pages <- c(
    "https://www.gov.br/cnpq/pt-br",
    "https://www.gov.br/cnpq/pt-br/assuntos/noticias/cnpq-em-acao"
  )
  purrr::map(pages, function(page_url) {
    tryCatch({
      doc <- read_html_url(page_url, timeout = config$source_timeout)
      parse_cnpq_html(doc, page_url, config)
    }, error = function(e) {
      log_warn("CNPq HTML fallback failed for {page_url}: {conditionMessage(e)}")
      tibble::tibble()
    })
  }) |>
    dplyr::bind_rows() |>
    dplyr::distinct(.data$url, .keep_all = TRUE)
}

parse_cnpq_html <- function(doc, base, config) {
  links <- rvest::html_elements(doc, "a[href]")
  href <- rvest::html_attr(links, "href")
  title <- clean_text(rvest::html_text2(links))
  url <- xml2::url_absolute(href, base)
  keep <- stringr::str_detect(url, "gov[.]br/cnpq/") &
    stringr::str_detect(url, "noticias|chamadas") &
    nzchar(title) &
    nchar(title) >= 20
  url <- unique(url[keep])
  title <- title[keep]
  if (length(url) == 0) return(empty_news_tbl())

  n <- min(length(url), config$max_candidates_per_source)
  purrr::map2_dfr(utils::head(url, n), utils::head(title, n), function(u, t) {
    tibble::tibble(
      id = stable_id("CNPq", u),
      source = "CNPq",
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
