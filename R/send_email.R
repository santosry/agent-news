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

  # Try direct Gmail API first (works without gmailr package issues)
  access_token <- authenticate_gmail_api(config)

  if (!is.null(access_token)) {
    log_info("Sending via Gmail REST API")
    return(send_clipping_gmail_api(html, config, access_token))
  }

  # Fallback to gmailr package
  authenticate_gmail_gmailr(config)

  results <- purrr::map_dfr(config$recipients, function(recipient) {
    tryCatch({
      msg <- gmailr::gm_mime() |>
        gmailr::gm_from(config$email_from) |>
        gmailr::gm_to(recipient) |>
        gmailr::gm_subject(glue::glue("Radar semanal de not\u00edcias - {format(config$now, '%d/%m/%Y')}")) |>
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

# ---- Direct Gmail REST API (bypasses gmailr segfault) -----------------

authenticate_gmail_api <- function(config) {
  token <- load_gmail_token(config)
  if (is.null(token)) return(NULL)

  access_token <- token$auth_token$access_token

  # Check if we have OAuth client for refresh
  client_path <- config$gmail_oauth_client
  if (nzchar(client_path) && file.exists(client_path)) {
    client_json <- tryCatch(
      jsonlite::fromJSON(client_path, simplifyVector = FALSE),
      error = function(e) NULL
    )
    if (!is.null(client_json)) {
      client_info <- if (!is.null(client_json$installed)) client_json$installed else client_json$web
      refresh_token <- token$auth_token$refresh_token

      if (!is.null(refresh_token) && nzchar(refresh_token)) {
        log_info("Refreshing Gmail access token...")
        new_token <- refresh_access_token(client_info, refresh_token)
        if (!is.null(new_token)) {
          access_token <- new_token
          # Update token in memory and on disk
          token$auth_token$access_token <- access_token
          save_gmail_token(token, config)
        }
      }
    }
  }

  log_info("Gmail API authenticated: {token$email}")
  access_token
}

load_gmail_token <- function(config) {
  # Step 1: Try plain token file
  if (file.exists(config$gmail_token_path)) {
    log_info("Loading Gmail token from: {config$gmail_token_path}")
    token <- readRDS(config$gmail_token_path)
    if (!is.null(token$auth_token$access_token)) {
      return(token)
    }
  }

  # Step 2: Try base64-encoded encrypted token
  if (nzchar(config$gmail_token_enc_b64)) {
    log_info("Decoding Gmail token from GMAILR_TOKEN_ENC_B64")
    if (!nzchar(config$gmail_key)) {
      stop("GMAILR_KEY is required to decrypt the Gmail token.", call. = FALSE)
    }
    raw_payload <- tryCatch(
      jsonlite::base64_dec(config$gmail_token_enc_b64),
      error = function(e) stop("Failed to decode GMAILR_TOKEN_ENC_B64: ", conditionMessage(e), call. = FALSE)
    )
    con <- rawConnection(raw_payload, "rb")
    on.exit(try(close(con), silent = TRUE), add = TRUE)
    payload <- readRDS(con)
    close(con)
    token <- decrypt_gmail_payload(payload, config$gmail_key)
    if (!is.null(token$auth_token$access_token)) {
      return(token)
    }
  }

  # Step 3: Try encrypted token file
  if (file.exists(config$gmail_encrypted_token_path)) {
    log_info("Loading encrypted Gmail token from: {config$gmail_encrypted_token_path}")
    if (!nzchar(config$gmail_key)) {
      stop("GMAILR_KEY is required to decrypt the Gmail token.", call. = FALSE)
    }
    payload <- readRDS(config$gmail_encrypted_token_path)
    token <- decrypt_gmail_payload(payload, config$gmail_key)
    if (!is.null(token$auth_token$access_token)) {
      return(token)
    }
  }

  NULL
}

save_gmail_token <- function(token, config) {
  saveRDS(token, config$gmail_token_path)

  if (nzchar(config$gmail_key)) {
    key <- openssl::sha256(charToRaw(config$gmail_key))
    iv <- openssl::rand_bytes(16)
    encrypted <- openssl::aes_cbc_encrypt(serialize(token, NULL), key = key, iv = iv)
    payload <- list(version = 1L, cipher = "aes-256-cbc", iv = iv, data = encrypted)
    saveRDS(payload, config$gmail_encrypted_token_path)
  }
}

refresh_access_token <- function(client_info, refresh_token) {
  tryCatch({
    resp <- httr2::request("https://oauth2.googleapis.com/token") |>
      httr2::req_headers("Content-Type" = "application/x-www-form-urlencoded") |>
      httr2::req_body_form(
        refresh_token = refresh_token,
        client_id = client_info$client_id,
        client_secret = client_info$client_secret,
        grant_type = "refresh_token"
      ) |>
      httr2::req_timeout(30) |>
      httr2::req_perform()

    new_token <- jsonlite::fromJSON(httr2::resp_body_string(resp), simplifyVector = FALSE)
    new_token$access_token
  }, error = function(e) {
    log_warn("Token refresh failed: {conditionMessage(e)}")
    NULL
  })
}

send_clipping_gmail_api <- function(html, config, access_token) {
  subject <- glue::glue("Radar semanal de not\u00edcias - {format(config$now, '%d/%m/%Y')}")

  results <- purrr::map_dfr(config$recipients, function(recipient) {
    tryCatch({
      msg_id <- send_email_raw(
        access_token = access_token,
        from = config$email_from,
        to = recipient,
        subject = subject,
        html_body = html
      )
      log_info("Email sent to {recipient} (ID: {msg_id})")
      tibble::tibble(recipient = recipient, status = "sent", message_id = msg_id)
    }, error = function(e) {
      log_warn("Email failed for {recipient}: {conditionMessage(e)}")
      tibble::tibble(recipient = recipient, status = "failed", message_id = NA_character_, error = conditionMessage(e))
    })
  })

  list(any_success = any(results$status == "sent"), dry_run = FALSE, per_recipient = results)
}

send_email_raw <- function(access_token, from, to, subject, html_body) {
  # Build RFC 2822 message
  boundary <- paste0("===============", format(Sys.time(), "%Y%m%d%H%M%S"), "==")

  msg_lines <- c(
    paste0("From: ", from),
    paste0("To: ", to),
    paste0("Subject: =?UTF-8?B?", base64enc::base64encode(charToRaw(subject)), "?="),
    "MIME-Version: 1.0",
    paste0("Content-Type: multipart/alternative; boundary=\"", boundary, "\""),
    "",
    paste0("--", boundary),
    "Content-Type: text/plain; charset=UTF-8",
    "Content-Transfer-Encoding: quoted-printable",
    "",
    "Este e-mail cont=C3=A9m HTML. Abra em um cliente compat=C3=ADvel.",
    "",
    paste0("--", boundary),
    "Content-Type: text/html; charset=UTF-8",
    "Content-Transfer-Encoding: quoted-printable",
    "",
    html_body,
    "",
    paste0("--", boundary, "--")
  )

  raw_msg <- paste(msg_lines, collapse = "\r\n")

  # Base64 URL-safe encode
  b64 <- base64enc::base64encode(charToRaw(raw_msg))
  b64_urlsafe <- gsub("\\+", "-", gsub("/", "_", b64))
  b64_urlsafe <- gsub("=+$", "", b64_urlsafe)

  body <- list(raw = jsonlite::unbox(b64_urlsafe))

  resp <- httr2::request("https://gmail.googleapis.com/gmail/v1/users/me/messages/send") |>
    httr2::req_auth_bearer_token(access_token) |>
    httr2::req_headers("Content-Type" = "application/json") |>
    httr2::req_body_json(body) |>
    httr2::req_timeout(30) |>
    httr2::req_perform()

  result <- jsonlite::fromJSON(httr2::resp_body_string(resp), simplifyVector = FALSE)
  result$id
}

# ---- gmailr fallback --------------------------------------------------------

authenticate_gmail_gmailr <- function(config) {
  if (!requireNamespace("gmailr", quietly = TRUE)) {
    stop("Package gmailr is required to use gmailr transport.", call. = FALSE)
  }

  log_info("Authenticating Gmail via gmailr: email={config$email_from}")

  if (nzchar(config$gmail_oauth_client) && file.exists(config$gmail_oauth_client)) {
    gmailr::gm_auth_configure(path = config$gmail_oauth_client)
  } else if (nzchar(config$gmail_oauth_client)) {
    log_warn("Gmail OAuth client file not found: {config$gmail_oauth_client}")
  }

  if (file.exists(config$gmail_token_path)) {
    token <- readRDS(config$gmail_token_path)
    gmailr::gm_auth(token = token)
    log_info("Gmail authenticated via gmailr.")
    return(invisible(TRUE))
  }

  stop(
    "No Gmail token found. ",
    "Run scripts/setup_gmail_automated.R to create one, ",
    "or configure GitHub Secrets GMAILR_KEY and GMAILR_TOKEN_ENC_B64.",
    call. = FALSE
  )
}

# ---- Outlook transport -------------------------------------------------------

send_clipping_outlook <- function(html, config) {
  script <- normalizePath(file.path("scripts", "send_outlook.ps1"), winslash = "\\", mustWork = TRUE)
  html_path <- tempfile("weekly-news-email-", fileext = ".html")
  writeLines(html, html_path, useBytes = TRUE)

  results <- purrr::map_dfr(config$recipients, function(recipient) {
    subject <- glue::glue("Radar semanal de not\u00edcias - {format(config$now, '%d/%m/%Y')}")
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

decrypt_gmail_payload <- function(payload, key_text) {
  key <- openssl::sha256(charToRaw(key_text))
  unserialize(openssl::aes_cbc_decrypt(payload$data, key = key, iv = payload$iv))
}
