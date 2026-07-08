http_user_agent <- function() {
  "agente-news/1.0 (+https://github.com/santosry/agente-news)"
}

http_get <- function(url, timeout = 20, accept = NULL, max_tries = 2) {
  req <- httr2::request(url) |>
    httr2::req_user_agent(http_user_agent()) |>
    httr2::req_timeout(timeout) |>
    httr2::req_retry(max_tries = max_tries, backoff = ~ 1.5^.x)

  if (!is.null(accept)) {
    req <- httr2::req_headers(req, Accept = accept)
  }

  resp <- httr2::req_perform(req)
  status <- httr2::resp_status(resp)
  if (status >= 400) {
    stop("HTTP ", status, " for ", url, call. = FALSE)
  }
  resp
}

detect_charset <- function(content_type, raw = raw()) {
  charset <- NA_character_
  if (!is.null(content_type) && !is.na(content_type)) {
    m <- stringr::str_match(content_type, "charset=([^;]+)")
    if (!is.na(m[, 2])) charset <- trimws(m[, 2])
  }

  if (is.na(charset) && length(raw) > 0) {
    head <- rawToChar(raw[seq_len(min(length(raw), 4000))])
    m <- stringr::str_match(head, "(?i)charset=[\"']?([A-Za-z0-9_\\-]+)")
    if (!is.na(m[, 2])) charset <- trimws(m[, 2])
  }

  charset %||% "UTF-8"
}

response_text <- function(resp) {
  raw <- httr2::resp_body_raw(resp)
  charset <- detect_charset(httr2::resp_header(resp, "content-type"), raw)
  txt <- rawToChar(raw)
  converted <- iconv(txt, from = charset, to = "UTF-8", sub = "byte")
  if (!is.na(converted)) txt <- converted
  Encoding(txt) <- "UTF-8"
  txt
}

read_html_url <- function(url, timeout = 25) {
  resp <- http_get(url, timeout = timeout, accept = "text/html,application/xhtml+xml")
  xml2::read_html(response_text(resp), encoding = "UTF-8")
}

strip_html <- function(x) {
  if (is.null(x) || length(x) == 0) return("")
  purrr::map_chr(as.character(x), function(value) {
    if (!nzchar(value)) return("")
    doc <- tryCatch(xml2::read_html(paste0("<body>", value, "</body>")), error = function(e) NULL)
    if (is.null(doc)) return(value)
    xml2::xml_text(xml2::xml_find_first(doc, "//body"))
  })
}

clean_text <- function(x) {
  if (is.null(x) || length(x) == 0) return("")
  purrr::map_chr(as.character(x), function(value) {
    if (is.na(value)) return(NA_character_)
    decoded <- tryCatch({
      doc <- xml2::read_html(paste0("<body>", value, "</body>"))
      xml2::xml_text(xml2::xml_find_first(doc, "//body"))
    }, error = function(e) {
      value
    })
    decoded <- stringr::str_replace_all(decoded, "\u00a0", " ")
    stringr::str_squish(decoded)
  })
}

parse_datetime_sao <- function(x, tz = "America/Sao_Paulo", date_only_hour = 0) {
  if (is.null(x) || length(x) == 0 || is.na(x) || !nzchar(trimws(x))) {
    return(as.POSIXct(NA, tz = tz))
  }
  x <- trimws(as.character(x[[1]]))

  if (stringr::str_detect(x, "^[A-Za-z]{3},\\s+[0-9]{2}\\s+[A-Za-z]{3}\\s+[0-9]{4}")) {
    compact <- stringr::str_replace(x, "^[A-Za-z]{3},\\s+", "")
    compact <- stringr::str_replace(compact, "\\s+[A-Z]{2,4}$", "")
    rfc <- suppressMessages(suppressWarnings(lubridate::parse_date_time(compact, orders = "d b Y HMS", tz = "UTC", locale = "C")))
    if (!is.na(rfc)) {
      return(lubridate::with_tz(rfc, tz))
    }
  }

  parsed <- tryCatch(
    suppressMessages(suppressWarnings(lubridate::parse_date_time(
      x,
      orders = c("ymd HMS z", "ymd HMS", "ymd HM", "ymd", "dmy HMS", "dmy HM", "dmy", "a, d b Y H:M:S z", "d b Y H:M:S z"),
      tz = tz,
      locale = "C"
    ))),
    error = function(e) as.POSIXct(NA, tz = tz)
  )

  if (is.na(parsed)) {
    return(as.POSIXct(NA, tz = tz))
  }

  if (stringr::str_detect(x, "^[0-9]{4}-[0-9]{2}-[0-9]{2}$") && date_only_hour != 0) {
    parsed <- lubridate::ymd_hms(paste0(x, sprintf(" %02d:00:00", date_only_hour)), tz = tz)
  }
  if (stringr::str_detect(x, "^[0-9]{2}/[0-9]{2}/[0-9]{4}$") && date_only_hour != 0) {
    parsed <- lubridate::dmy_hms(paste0(x, sprintf(" %02d:00:00", date_only_hour)), tz = tz)
  }

  lubridate::with_tz(parsed, tz)
}

is_in_window <- function(x, start, end) {
  !is.na(x) & x >= start & x <= end
}

extract_meta <- function(doc, name = NULL, property = NULL) {
  if (!is.null(name)) {
    nodes <- rvest::html_elements(doc, xpath = sprintf("//meta[translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz')='%s']", tolower(name)))
  } else if (!is.null(property)) {
    nodes <- rvest::html_elements(doc, xpath = sprintf("//meta[translate(@property,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz')='%s']", tolower(property)))
  } else {
    return(NA_character_)
  }
  value <- rvest::html_attr(nodes, "content")
  value <- value[!is.na(value) & nzchar(value)]
  if (length(value) == 0) NA_character_ else clean_text(value[[1]])
}

extract_json_ld <- function(doc) {
  scripts <- rvest::html_elements(doc, xpath = "//script[@type='application/ld+json']")
  texts <- rvest::html_text2(scripts)
  purrr::map(texts, function(txt) {
    tryCatch(jsonlite::fromJSON(txt, simplifyVector = FALSE), error = function(e) NULL)
  }) |>
    purrr::compact()
}

extract_article_text_from_doc <- function(doc, max_chars = 6000) {
  nodes <- rvest::html_elements(doc, xpath = "//article//p | //main//p | //div[contains(@class,'content')]//p | //p")
  paragraphs <- clean_text(rvest::html_text2(nodes))
  paragraphs <- paragraphs[nchar(paragraphs) >= 40]
  paragraphs <- unique(paragraphs)
  text <- paste(paragraphs, collapse = "\n\n")
  substr(text, 1, max_chars)
}

stable_id <- function(source, value) {
  raw <- paste(source, value, sep = "::")
  paste0("n", substr(openssl::md5(charToRaw(raw)), 1, 16))
}
