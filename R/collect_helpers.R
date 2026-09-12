collect_sources <- function(collectors, config) {
  if (requireNamespace("furrr", quietly = TRUE) && requireNamespace("future", quietly = TRUE) && length(collectors) > 1) {
    tryCatch({
      future::plan(future::multisession, workers = min(6L, length(collectors)))
      on.exit(future::plan(future::sequential), add = TRUE)
      log_info("Collecting from {length(collectors)} sources in parallel")
      furrr::future_imap(collectors, ~ collect_source_safely(.y, .x, config))
    }, error = function(e) {
      log_warn("Parallel collection failed ({conditionMessage(e)}); falling back to sequential collection.")
      future::plan(future::sequential)
      purrr::imap(collectors, ~ collect_source_safely(.y, .x, config))
    })
  } else {
    purrr::imap(collectors, ~ collect_source_safely(.y, .x, config))
  }
}

collect_source_safely <- function(source_name, fun, config) {
  started <- Sys.time()
  log_info("Starting source: {source_name}")

  result <- tryCatch(
    fun(config),
    error = function(e) {
      list(
        source = source_name,
        status = "failed",
        items = empty_news_tbl(),
        raw_count = 0L,
        valid_date_count = 0L,
        in_window_count = 0L,
        diagnostics = conditionMessage(e),
        started_at = started,
        ended_at = Sys.time()
      )
    }
  )

  result$started_at <- started
  result$ended_at <- Sys.time()
  result$elapsed_sec <- as.numeric(difftime(result$ended_at, result$started_at, units = "secs"))

  log_info(
    "{source_name}: status={result$status}; raw={result$raw_count}; valid_date={result$valid_date_count}; in_window={result$in_window_count}; elapsed={round(result$elapsed_sec, 1)}s"
  )
  result
}

finish_source_result <- function(source_name, rows, raw_count, config) {
  if (is.null(rows) || nrow(rows) == 0) {
    return(list(
      source = source_name,
      status = "no_items",
      items = empty_news_tbl(),
      raw_count = raw_count,
      valid_date_count = 0L,
      in_window_count = 0L,
      diagnostics = "No candidate items discovered.",
      started_at = Sys.time(),
      ended_at = Sys.time()
    ))
  }

  rows <- normalize_news_tbl(rows)
  valid_date_count <- sum(!is.na(rows$published_at))
  rows <- rows |>
    dplyr::mutate(
      discard_reason = dplyr::case_when(
        is.na(.data$published_at) ~ "date_not_validated",
        !is_in_window(.data$published_at, config$window_start, config$window_end) ~ "outside_7_day_window",
        TRUE ~ .data$discard_reason
      )
    )

  in_window <- rows |>
    dplyr::filter(is.na(.data$discard_reason) | .data$discard_reason == "")

  status <- dplyr::case_when(
    valid_date_count == 0 ~ "no_valid_dates",
    nrow(in_window) == 0 ~ "no_window_items",
    TRUE ~ "ok"
  )

  list(
    source = source_name,
    status = status,
    items = rows,
    raw_count = raw_count,
    valid_date_count = valid_date_count,
    in_window_count = nrow(in_window),
    diagnostics = NA_character_,
    started_at = Sys.time(),
    ended_at = Sys.time()
  )
}

empty_news_tbl <- function() {
  tibble::tibble(
    id = character(),
    source = character(),
    title = character(),
    url = character(),
    published_at = as.POSIXct(character()),
    modified_at = as.POSIXct(character()),
    date_kind = character(),
    date_source = character(),
    excerpt = character(),
    keywords = character(),
    raw_source = character(),
    discard_reason = character()
  )
}

normalize_news_tbl <- function(rows) {
  rows |>
    dplyr::mutate(
      title = clean_text(.data$title),
      url = clean_text(.data$url),
      excerpt = clean_text(.data$excerpt),
      keywords = clean_text(.data$keywords),
      title_norm = normalize_title(.data$title)
    ) |>
    dplyr::filter(.data$title != "", .data$url != "") |>
    dplyr::distinct(.data$url, .keep_all = TRUE)
}

# Parsing genérico de feeds RSS/Atom -----------------------------------------
#
# Converte itens de um feed RSS 2.0 (<item>) ou Atom (<entry>) em linhas do
# schema canônico. É reutilizado pelos coletores que usam canais oficiais em
# RSS/Atom (CNPq, CAPES, IBM, AHA), evitando duplicar lógica de parsing.
#
# - Data: <pubDate> (RSS) ou <published> (Atom), via parse_datetime_sao().
# - Título/URL/excerpt: <title>, <link> (ou <link rel="alternate"> em Atom),
#   <description> (RSS) ou <summary> (Atom).
parse_feed_entries <- function(xml_text, source, config) {
  if (is.null(xml_text) || length(xml_text) == 0 || is.na(xml_text[[1]]) || !nzchar(trimws(xml_text[[1]]))) {
    return(empty_news_tbl())
  }

  doc <- tryCatch(xml2::read_xml(xml_text[[1]]), error = function(e) NULL)
  if (is.null(doc)) return(empty_news_tbl())

  entries <- xml2::xml_find_all(doc, "//*[local-name()='entry']")
  is_atom <- length(entries) > 0L
  if (!is_atom) entries <- xml2::xml_find_all(doc, "//*[local-name()='item']")
  if (length(entries) == 0L) return(empty_news_tbl())

  purrr::map_dfr(entries, function(e) {
    if (is_atom) {
      title <- xml2::xml_text(xml2::xml_find_first(e, "*[local-name()='title']"))
      link_node <- xml2::xml_find_first(e, "*[local-name()='link' and @rel='alternate']")
      if (length(link_node) == 0L || is.na(xml2::xml_attr(link_node, "href"))) {
        link_node <- xml2::xml_find_first(e, "*[local-name()='link']")
      }
      url <- xml2::xml_attr(link_node, "href")
      date <- xml2::xml_text(xml2::xml_find_first(e, "*[local-name()='published']"))
      summary <- xml2::xml_text(xml2::xml_find_first(e, "*[local-name()='summary']"))
    } else {
      title <- xml2::xml_text(xml2::xml_find_first(e, "title"))
      url <- xml2::xml_text(xml2::xml_find_first(e, "link"))
      # Alguns feeds RSS (ex.: gov.br Plone) omitem <link> e usam <guid> como URL.
      if (!nzchar(url %||% "")) {
        url <- xml2::xml_text(xml2::xml_find_first(e, "guid"))
      }
      date <- xml2::xml_text(xml2::xml_find_first(e, "pubDate"))
      summary <- xml2::xml_text(xml2::xml_find_first(e, "description"))
    }

    tibble::tibble(
      id = stable_id(source, url %||% ""),
      source = source,
      title = clean_text(title %||% ""),
      url = clean_text(url %||% ""),
      published_at = parse_datetime_sao(date %||% NA_character_, tz = config$timezone),
      modified_at = as.POSIXct(NA),
      date_kind = "published",
      date_source = if (is_atom) "feed_published" else "rss_pubDate",
      excerpt = clean_text(strip_html(summary %||% "")),
      keywords = "",
      raw_source = NA_character_,
      discard_reason = NA_character_
    )
  }) |>
    dplyr::filter(nzchar(.data$title), nzchar(.data$url))
}
