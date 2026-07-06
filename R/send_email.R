send_clipping <- function(html, config) {
  if (config$dry_run) {
    log_info("Dry run enabled. Email sending skipped.")
    return(list(any_success = TRUE, dry_run = TRUE, per_recipient = tibble::tibble()))
  }

  if (length(config$recipients) == 0) {
    return(list(any_success = FALSE, dry_run = FALSE, per_recipient = tibble::tibble()))
  }

  if (identical(config$email_transport, "outlook")) {
    return(send_clipping_outlook(html, config))
  }

  if (!identical(config$email_transport, "gmailr")) {
    stop("Unsupported EMAIL_TRANSPORT: ", config$email_transport, call. = FALSE)
  }

  authenticate_gmail(config)

  results <- purrr::map_dfr(config$recipients, function(recipient) {
    tryCatch({
      msg <- gmailr::gm_mime() |>
        gmailr::gm_from(config$email_from) |>
        gmailr::gm_to(recipient) |>
        gmailr::gm_subject(glue::glue("Radar semanal de notícias - {format(config$now, '%d/%m/%Y')}")) |>
        gmailr::gm_html_body(html)
      sent <- gmailr::gm_send_message(msg)
      log_info("Email sent to {recipient}")
      tibble::tibble(recipient = recipient, status = "sent", message_id = sent$id %||% NA_character_)
    }, error = function(e) {
      log_warn("Email failed for {recipient}: {conditionMessage(e)}")
      tibble::tibble(recipient = recipient, status = "failed", message_id = NA_character_, error = conditionMessage(e))
    })
  })

  list(any_success = any(results$status == "sent"), dry_run = FALSE, per_recipient = results)
}

send_clipping_outlook <- function(html, config) {
  script <- normalizePath(file.path("scripts", "send_outlook.ps1"), winslash = "\\", mustWork = TRUE)
  html_path <- tempfile("weekly-news-email-", fileext = ".html")
  writeLines(html, html_path, useBytes = TRUE)

  results <- purrr::map_dfr(config$recipients, function(recipient) {
    subject <- glue::glue("Radar semanal de notícias - {format(config$now, '%d/%m/%Y')}")
    command <- glue::glue(
      "& {ps_quote(script)} -To {ps_quote(recipient)} -Subject {ps_quote(as.character(subject))} -HtmlPath {ps_quote(normalizePath(html_path, winslash = '\\\\', mustWork = TRUE))} -From {ps_quote(config$email_from)}"
    )
    encoded <- encode_powershell_command(command)

    output <- tryCatch(
      system2("powershell", args = c("-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded), stdout = TRUE, stderr = TRUE),
      error = function(e) structure(conditionMessage(e), status = 1)
    )

    status_code <- attr(output, "status") %||% 0
    if (identical(as.integer(status_code), 0L)) {
      log_info("Email sent through Outlook to {recipient}")
      tibble::tibble(recipient = recipient, status = "sent", message_id = NA_character_, transport = "outlook")
    } else {
      error_text <- clean_powershell_output(output)
      log_warn("Outlook email failed for {recipient}: {error_text}")
      tibble::tibble(recipient = recipient, status = "failed", message_id = NA_character_, transport = "outlook", error = error_text)
    }
  })

  list(any_success = any(results$status == "sent"), dry_run = FALSE, per_recipient = results)
}

ps_quote <- function(x) {
  paste0("'", gsub("'", "''", x, fixed = TRUE), "'")
}

encode_powershell_command <- function(command) {
  codepoints <- utf8ToInt(enc2utf8(command))
  con <- rawConnection(raw(0), "wb")
  on.exit(close(con), add = TRUE)

  for (codepoint in codepoints) {
    if (codepoint <= 0xFFFF) {
      writeBin(as.integer(codepoint), con, size = 2, endian = "little")
    } else {
      codepoint <- codepoint - 0x10000
      high <- bitwOr(0xD800, bitwShiftR(codepoint, 10))
      low <- bitwOr(0xDC00, bitwAnd(codepoint, 0x3FF))
      writeBin(as.integer(c(high, low)), con, size = 2, endian = "little")
    }
  }

  gsub("[\r\n]", "", jsonlite::base64_enc(rawConnectionValue(con)))
}

clean_powershell_output <- function(output) {
  text <- paste(output, collapse = " ")
  text <- gsub("_x000D__x000A_", " ", text, fixed = TRUE)
  text <- gsub("\\s+", " ", text)
  if (grepl("NoCOMClassIdentified|REGDB_E_CLASSNOTREG|Classe n.o registrada|80040154", text, ignore.case = TRUE)) {
    return("Microsoft Outlook desktop is not installed or Outlook COM automation is not registered for this Windows user profile.")
  }
  trimws(text)
}

authenticate_gmail <- function(config) {
  if (!requireNamespace("gmailr", quietly = TRUE)) {
    stop("Package gmailr is required to send email.", call. = FALSE)
  }

  if (file.exists(config$gmail_oauth_client)) {
    gmailr::gm_auth_configure(path = config$gmail_oauth_client)
  }

  if (file.exists(config$gmail_token_path)) {
    token <- readRDS(config$gmail_token_path)
    gmailr::gm_auth(token = token)
    return(invisible(TRUE))
  }

  if (nzchar(config$gmail_token_enc_b64)) {
    if (!nzchar(config$gmail_key)) {
      stop("GMAILR_KEY is required to decrypt the Gmail token.", call. = FALSE)
    }
    raw_payload <- jsonlite::base64_dec(config$gmail_token_enc_b64)
    con <- rawConnection(raw_payload, "rb")
    on.exit(close(con), add = TRUE)
    payload <- readRDS(con)
    token <- decrypt_gmail_payload(payload, config$gmail_key)
    gmailr::gm_auth(token = token)
    return(invisible(TRUE))
  }

  if (file.exists(config$gmail_encrypted_token_path)) {
    if (!nzchar(config$gmail_key)) {
      stop("GMAILR_KEY is required to decrypt the Gmail token.", call. = FALSE)
    }
    payload <- readRDS(config$gmail_encrypted_token_path)
    token <- decrypt_gmail_payload(payload, config$gmail_key)
    gmailr::gm_auth(token = token)
    return(invisible(TRUE))
  }

  stop("No Gmail token found. Run setup_gmail_token.R and configure secrets.", call. = FALSE)
}

decrypt_gmail_payload <- function(payload, key_text) {
  key <- openssl::sha256(charToRaw(key_text))
  unserialize(openssl::aes_cbc_decrypt(payload$data, key = key, iv = payload$iv))
}
