collect_folha1 <- function(config) {
  discovery_pages <- c(
    "https://www.folha1.com.br/",
    "https://www.folha1.com.br/geral/",
    "https://www.folha1.com.br/politica/",
    "https://www.folha1.com.br/economia/",
    "https://www.folha1.com.br/ultimas/",
    "https://www.folha1.com.br/cidade/",
    "https://www.folha1.com.br/norte-fluminense/",
    "https://www.folha1.com.br/blogs/"
  )

  candidates <- purrr::map(discovery_pages, function(page) {
    tryCatch({
      doc <- read_html_url(page, timeout = config$source_timeout)
      links <- rvest::html_elements(doc, "a[href]")
      href <- rvest::html_attr(links, "href")
      title <- clean_text(rvest::html_text2(links))
      url <- xml2::url_absolute(href, page)
      keep <- stringr::str_detect(url, "/20[0-9]{2}/[0-9]{2}/[0-9]+-.*[.]html$")
      tibble::tibble(url = url[keep], title_hint = title[keep], raw_source = page)
    }, error = function(e) {
      log_warn("Folha1 discovery failed: {page} - {conditionMessage(e)}")
      tibble::tibble(url = character(), title_hint = character(), raw_source = character())
    })
  }) |>
    dplyr::bind_rows() |>
    dplyr::filter(!is.na(.data$url), .data$url != "") |>
    dplyr::distinct(.data$url, .keep_all = TRUE) |>
    utils::head(config$max_candidates_per_source)

  rows <- purrr::map_dfr(seq_len(nrow(candidates)), function(i) {
    url <- candidates$url[[i]]
    tryCatch({
      doc <- read_html_url(url, timeout = config$source_timeout)
      title <- extract_meta(doc, name = "twitter:title")
      if (is.na(title)) title <- extract_meta(doc, property = "og:title")
      if (is.na(title)) title <- xml2::xml_text(xml2::xml_find_first(doc, "//title"))
      title <- clean_text(stringr::str_remove(title, "\\s*Folha1\\s*-.*$"))

      desc <- extract_meta(doc, name = "description")
      if (is.na(desc)) desc <- extract_meta(doc, property = "og:description")
      date_value <- extract_meta(doc, name = "DC.date.created")
      date_kind <- "published"
      date_source <- "html_meta_DC.date.created"

      if (is.na(date_value)) {
        date_value <- stringr::str_match(url, "/(20[0-9]{2})/([0-9]{2})/")[, 1]
        date_kind <- "inferred"
        date_source <- "url_year_month_only"
      }

      published_at <- parse_datetime_sao(date_value, tz = config$timezone, date_only_hour = 12)
      if (date_source == "url_year_month_only") {
        published_at <- as.POSIXct(NA)
      }

      tibble::tibble(
        id = stable_id("Folha1", url),
        source = "Folha1",
        title = title,
        url = url,
        published_at = published_at,
        modified_at = as.POSIXct(NA),
        date_kind = date_kind,
        date_source = date_source,
        excerpt = clean_text(desc),
        keywords = "",
        raw_source = candidates$raw_source[[i]],
        discard_reason = NA_character_
      )
    }, error = function(e) {
      log_warn("Folha1 article failed: {url} - {conditionMessage(e)}")
      tibble::tibble()
    })
  })

  finish_source_result("Folha1", rows, raw_count = nrow(candidates), config = config)
}
