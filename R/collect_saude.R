collect_saude <- function(config) {
  # gov.br Saude uses the same Plone tileItem structure as MEC and IFF
  base_urls <- c(
    "https://www.gov.br/saude/pt-br/assuntos/noticias-ms",
    "https://www.gov.br/saude/pt-br/assuntos/noticias",
    "https://www.gov.br/saude/pt-br/assuntos/noticias/ultimas-noticias"
  )

  all_rows <- tibble::tibble()
  raw_count <- 0L

  for (base in base_urls) {
    per_page <- 30L
    for (page in seq_len(3L)) {
      offset <- (page - 1L) * per_page
      url <- paste0(base, "?b_start:int=", offset)

      page_rows <- tryCatch({
        doc <- read_html_url(url, timeout = config$source_timeout)
        articles <- rvest::html_elements(doc, xpath = "//*[contains(concat(' ', normalize-space(@class), ' '), ' tileItem ')]")
        if (length(articles) == 0) return(tibble::tibble())

        purrr::map_dfr(seq_along(articles), function(i) {
          article <- articles[[i]]
          link_node <- rvest::html_element(article, "h2 a[href]")
          title <- clean_text(rvest::html_text2(link_node))
          link <- clean_text(xml2::url_absolute(rvest::html_attr(link_node, "href"), base))
          excerpt <- clean_text(rvest::html_text2(rvest::html_element(article, ".description")))
          keywords <- clean_text(paste(rvest::html_text2(rvest::html_elements(article, ".keywords a")), collapse = ", "))
          meta <- clean_text(rvest::html_text2(rvest::html_elements(article, ".summary-view-icon")))
          date_text <- meta[stringr::str_detect(meta, "^[0-9]{2}/[0-9]{2}/[0-9]{4}$")][[1]] %||% NA_character_
          hour_text <- meta[stringr::str_detect(meta, "^[0-9]{1,2}h[0-9]{2}$")][[1]] %||% "12h00"
          published_at <- parse_iff_datetime(date_text, hour_text, config$timezone)

          tibble::tibble(
            id = stable_id("Ministerio da Saude", link),
            source = "Minist\u00e9rio da Sa\u00fade",
            title = title,
            url = link,
            published_at = published_at,
            modified_at = as.POSIXct(NA),
            date_kind = "published",
            date_source = "plone_summary_view_icon",
            excerpt = excerpt,
            keywords = keywords,
            raw_source = url,
            discard_reason = NA_character_
          )
        })
      }, error = function(e) {
        log_warn("Saude page failed: {url} - {conditionMessage(e)}")
        tibble::tibble()
      })

      raw_count <- raw_count + nrow(page_rows)
      all_rows <- dplyr::bind_rows(all_rows, page_rows)

      page_dates <- page_rows$published_at[!is.na(page_rows$published_at)]
      if (nrow(page_rows) == 0 || (length(page_dates) > 0 && max(page_dates) < config$window_start)) {
        break
      }
    }

    # If we got results from the first URL, skip the alternative
    if (nrow(all_rows) > 0) break
  }

  all_rows <- all_rows |>
    dplyr::filter(!is.na(.data$title), .data$title != "", !is.na(.data$url), .data$url != "") |>
    dplyr::distinct(.data$url, .keep_all = TRUE) |>
    utils::head(config$max_candidates_per_source)

  finish_source_result("Minist\u00e9rio da Sa\u00fade", all_rows, raw_count = raw_count, config = config)
}
