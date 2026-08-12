#!/usr/bin/env Rscript

if (!requireNamespace("gmailr", quietly = TRUE)) {
  stop("Install gmailr before running this setup script.", call. = FALSE)
}
if (!requireNamespace("openssl", quietly = TRUE)) {
  stop("Install openssl before running this setup script.", call. = FALSE)
}

dir.create("secrets", showWarnings = FALSE)

client_path <- Sys.getenv("GMAIL_OAUTH_CLIENT", "oauth_client.json")
plain_token_path <- Sys.getenv("GMAIL_TOKEN_PATH", "secrets/gmailr-token.rds")
encrypted_token_path <- Sys.getenv("GMAIL_ENCRYPTED_TOKEN_PATH", "secrets/gmailr-token.rds.enc")
b64_token_path <- paste0(encrypted_token_path, ".b64.txt")
email <- Sys.getenv("EMAIL_FROM", "")

if (!file.exists(client_path)) {
  stop("oauth_client.json not found. Download the OAuth client from Google Cloud and place it at the project root.", call. = FALSE)
}

gmailr::gm_auth_configure(path = client_path)
gmailr::gm_auth(email = email, cache = FALSE)
token <- gmailr::gm_token()
saveRDS(token, plain_token_path)
message("Plain token saved at ", plain_token_path, ". This file is ignored by git.")

key_text <- Sys.getenv("GMAILR_KEY", "")
if (nzchar(key_text)) {
  key <- openssl::sha256(charToRaw(key_text))
  iv <- openssl::rand_bytes(16)
  encrypted <- openssl::aes_cbc_encrypt(serialize(token, NULL), key = key, iv = iv)
  saveRDS(list(version = 1L, cipher = "aes-256-cbc", iv = iv, data = encrypted), encrypted_token_path)
  encrypted_file <- readBin(encrypted_token_path, what = "raw", n = file.info(encrypted_token_path)$size)
  writeLines(jsonlite::base64_enc(encrypted_file), b64_token_path, useBytes = TRUE)
  message("Encrypted token saved at ", encrypted_token_path, ". Do not commit it.")
  message("Base64 token secret saved at ", b64_token_path, ". Copy its content to GitHub Secrets as GMAILR_TOKEN_ENC_B64.")
} else {
  message("GMAILR_KEY is not set, so no encrypted token was written.")
}
