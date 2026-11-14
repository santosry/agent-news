#!/usr/bin/env Rscript
#
# Diagnóstico de metadados dos secrets do Gmail, sem imprimir valores.
# Uso local:
#   GMAILR_KEY=... GMAILR_TOKEN_ENC_B64=... Rscript scripts/diagnose_secrets.R

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

# Reutiliza o leitor robusto (gzip/RDS) do código de envio.
if (file.exists("R/send_email.R")) source("R/send_email.R")

describe_raw <- function(raw) {
  if (is.null(raw)) return("NULL")
  n <- min(8L, length(raw))
  if (n == 0L) return("bytes=0")
  paste0(
    "bytes=", length(raw),
    "; first_hex=", paste(sprintf("%02x", as.integer(raw[seq_len(n)])), collapse = "")
  )
}

inspect_b64 <- function(name, value, kind) {
  cat("== ", name, " ==\n", sep = "")
  cat("nchar=", nchar(value), " configured=", nzchar(value), "\n", sep = "")
  if (!nzchar(value)) return(invisible(NULL))

  raw <- tryCatch(jsonlite::base64_dec(value), error = function(e) NULL)
  if (is.null(raw)) {
    cat("base64_decode=FAILED\n")
    return(invisible(NULL))
  }
  cat("base64_decode=OK; ", describe_raw(raw), "\n", sep = "")

  obj <- tryCatch(read_rds_raw(raw), error = function(e) {
    cat("readRDS=FAILED: ", conditionMessage(e), "\n", sep = "")
    NULL
  })

  if (!is.null(obj)) {
    cat("readRDS=OK; class=", paste(class(obj), collapse = "/"),
        "; names=", paste(names(obj), collapse = ","), "\n", sep = "")
    if (identical(kind, "payload")) {
      cat("payload_version=", obj$version %||% NA,
          "; cipher=", obj$cipher %||% NA,
          "; has_iv=", !is.null(obj$iv),
          "; has_data=", !is.null(obj$data), "\n", sep = "")
    }
    return(invisible(obj))
  }

  preview <- tryCatch(rawToChar(raw[seq_len(min(length(raw), 200L))]), error = function(e) "")
  cat("looks_like_json=", grepl("^[[:space:]]*[{]", preview), "\n", sep = "")
  invisible(NULL)
}

token_payload <- inspect_b64("GMAILR_TOKEN_ENC_B64", Sys.getenv("GMAILR_TOKEN_ENC_B64"), "payload")
inspect_b64("GMAIL_OAUTH_B64", Sys.getenv("GMAIL_OAUTH_B64"), "oauth")

key_text <- Sys.getenv("GMAILR_KEY")
if (!is.null(token_payload) && nzchar(key_text) && !is.null(token_payload$iv) && !is.null(token_payload$data)) {
  token <- tryCatch({
    key <- openssl::sha256(charToRaw(key_text))
    unserialize(openssl::aes_cbc_decrypt(token_payload$data, key = key, iv = token_payload$iv))
  }, error = function(e) {
    cat("decrypt=FAILED: ", conditionMessage(e), "\n", sep = "")
    NULL
  })
  if (!is.null(token)) {
    cat("decrypt=OK; email=", token$email %||% "unknown",
        "; has_access_token=", !is.null(token$auth_token$access_token),
        "; has_refresh_token=", !is.null(token$auth_token$refresh_token), "\n", sep = "")
  }
}
