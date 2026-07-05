send_clipping <- function(html, config) {
  if (config$dry_run) {
    log_info("Dry run enabled. Email sending skipped.")
    return(list(any_success = TRUE, dry_run = TRUE, per_recipient = tibble::tibble()))
  }

  if (length(config$recipients) == 0) {
    return(list(any_success = FALSE, dry_run = FALSE, per_recipient = tibble::tibble()))
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

  if (file.exists(config$gmail_encrypted_token_path)) {
    if (!nzchar(config$gmail_key)) {
      stop("GMAILR_KEY is required to decrypt the Gmail token.", call. = FALSE)
    }
    payload <- readRDS(config$gmail_encrypted_token_path)
    key <- openssl::sha256(charToRaw(config$gmail_key))
    token <- unserialize(openssl::aes_cbc_decrypt(payload$data, key = key, iv = payload$iv))
    gmailr::gm_auth(token = token)
    return(invisible(TRUE))
  }

  stop("No Gmail token found. Run setup_gmail_token.R and configure secrets.", call. = FALSE)
}
