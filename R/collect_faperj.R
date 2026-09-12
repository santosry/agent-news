# Coletor: FAPERJ -------------------------------------------------------------
#
# Fonte editorial: Fundação Carlos Chagas Filho de Amparo à Pesquisa do Estado
#   do Rio de Janeiro (FAPERJ)
# Domínio: www.faperj.br
#
# Método primário: scraping HTML do "Arquivo de notícias" oficial.
#   Endpoint: https://www.faperj.br/?id=35.5.3
# Método de fallback: scraping do carrossel de notícias da página principal.
#
# Estratégia de extração: cada notícia é um <blockquote> com link, título
#   (<a href="/?id=...">) e data (div.data-arquivo).
# Estratégia de data: "DD/MM/YYYY" em div.data-arquivo (publicação).
# Limitações conhecidas:
#   - O arquivo lista ~15 notícias recentes, sem paginação.
#   - No fallback do carrossel, a data não está disponível (é marcada como
#     não validada pelo finish_source_result()).
#
# Metadata regional: a fonte preserva "Rio de Janeiro" em keywords.

collect_faperj <- function(config) {
  rows <- collect_faperj_archive(config)
  if (nrow(rows) == 0) {
    log_info("FAPERJ archive returned no items, falling back to homepage carousel")
    rows <- collect_faperj_carousel(config)
  }
  finish_source_result("FAPERJ", rows, raw_count = nrow(rows), config = config)
}

collect_faperj_archive <- function(config) {
  url <- "https://www.faperj.br/?id=35.5.3"
  tryCatch({
    doc <- read_html_url(url, timeout = config$source_timeout)
    parse_faperj_archive(doc, url, config)
  }, error = function(e) {
    log_warn("FAPERJ archive failed: {url} - {conditionMessage(e)}")
    tibble::tibble()
  })
}

parse_faperj_archive <- function(doc, base, config) {
  blocks <- rvest::html_elements(doc, "blockquote")
  if (length(blocks) == 0) return(empty_news_tbl())

  rows <- purrr::map_dfr(blocks, function(block) {
    link_node <- rvest::html_element(block, "a[href*='?id=']")
    if (length(link_node) == 0) return(empty_news_tbl())
    title <- clean_text(rvest::html_text2(link_node))
    url <- clean_text(xml2::url_absolute(rvest::html_attr(link_node, "href"), base))
    date_value <- clean_text(rvest::html_text2(rvest::html_element(block, ".data-arquivo")))
    excerpt_node <- xml2::xml_find_first(block, "div[contains(@class,'data-arquivo')]/following-sibling::div[1]")
    excerpt <- clean_text(rvest::html_text2(excerpt_node))

    tibble::tibble(
      id = stable_id("FAPERJ", url),
      source = "FAPERJ",
      title = title,
      url = url,
      published_at = parse_datetime_sao(date_value, tz = config$timezone, date_only_hour = 12),
      modified_at = as.POSIXct(NA),
      date_kind = "published",
      date_source = "faperj_data_arquivo",
      excerpt = excerpt,
      keywords = "Rio de Janeiro",
      raw_source = base,
      discard_reason = NA_character_
    )
  })

  rows |>
    dplyr::filter(nzchar(.data$title), nzchar(.data$url))
}

collect_faperj_carousel <- function(config) {
  url <- "https://www.faperj.br/"
  tryCatch({
    doc <- read_html_url(url, timeout = config$source_timeout)
    parse_faperj_carousel(doc, url, config)
  }, error = function(e) {
    log_warn("FAPERJ carousel failed: {url} - {conditionMessage(e)}")
    tibble::tibble()
  })
}

parse_faperj_carousel <- function(doc, base, config) {
  anchors <- rvest::html_elements(doc, "a[href*='?id=']")
  if (length(anchors) == 0) return(empty_news_tbl())

  rows <- purrr::map_dfr(anchors, function(a) {
    h <- rvest::html_element(a, "h1")
    if (length(h) == 0) return(empty_news_tbl())
    title <- clean_text(rvest::html_text2(h))
    url <- clean_text(xml2::url_absolute(rvest::html_attr(a, "href"), base))
    excerpt_node <- xml2::xml_find_first(a, "following-sibling::p[1]")
    excerpt <- clean_text(rvest::html_text2(excerpt_node))

    tibble::tibble(
      id = stable_id("FAPERJ", url),
      source = "FAPERJ",
      title = title,
      url = url,
      published_at = as.POSIXct(NA, tz = config$timezone),
      modified_at = as.POSIXct(NA),
      date_kind = "published",
      date_source = "faperj_carousel_no_date",
      excerpt = excerpt,
      keywords = "Rio de Janeiro",
      raw_source = base,
      discard_reason = NA_character_
    )
  })

  rows |>
    dplyr::filter(nzchar(.data$title), nzchar(.data$url))
}
