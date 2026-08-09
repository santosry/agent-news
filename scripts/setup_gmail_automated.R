#!/usr/bin/env Rscript
#
# setup_gmail_automated.R
# Interactive script to configure Gmail OAuth for automated sending.
#
# Prerequisites:
# 1. Create a Google Cloud project at https://console.cloud.google.com
# 2. Enable Gmail API
# 3. Create an OAuth 2.0 Client ID (Desktop application)
# 4. Download the JSON and save it as oauth_client.json in the project root
#
# This script supports both:
# - GUI mode (opens browser for auth)
# - Headless/terminal mode (uses out-of-band device flow)
#
# Outputs:
# - secrets/gmailr-token.rds        (plain token, git-ignored)
# - secrets/gmailr-token.rds.enc    (encrypted token)
# - secrets/token_base64.txt        (base64-encoded encrypted token for GitHub Secrets)
#
# Usage:
#   Rscript scripts/setup_gmail_automated.R
#   EMAIL_FROM=myemail@gmail.com Rscript scripts/setup_gmail_automated.R

suppressPackageStartupMessages({
  library(gmailr)
  library(openssl)
})

# ---- Configuration -----------------------------------------------------------
email <- Sys.getenv("EMAIL_FROM", "arquivosryansantos@gmail.com")
client_path <- Sys.getenv("GMAIL_OAUTH_CLIENT", "oauth_client.json")
token_path <- Sys.getenv("GMAIL_TOKEN_PATH", "secrets/gmailr-token.rds")
encrypted_path <- Sys.getenv("GMAIL_ENCRYPTED_TOKEN_PATH", "secrets/gmailr-token.rds.enc")
b64_path <- "secrets/token_base64.txt"

dir.create("secrets", showWarnings = FALSE)

# ---- Step 1: Check oauth_client.json -----------------------------------------
cat("\n========================================\n")
cat("  GMAIL AUTOMATED SETUP\n")
cat("========================================\n\n")

if (!file.exists(client_path)) {
  cat("ERROR: oauth_client.json not found at '", client_path, "'.\n\n", sep = "")
  cat("HOW TO CREATE IT:\n")
  cat("1. Go to https://console.cloud.google.com\n")
  cat("2. Create a new project (or select an existing one)\n")
  cat("3. Go to 'APIs & Services' > 'Library'\n")
  cat("4. Search for 'Gmail API' and enable it\n")
  cat("5. Go to 'APIs & Services' > 'Credentials'\n")
  cat("6. Click 'Create Credentials' > 'OAuth client ID'\n")
  cat("7. Choose 'Desktop application' as application type\n")
  cat("8. Give it a name (e.g., 'Agent News Gmail')\n")
  cat("9. Click 'Create' and download the JSON file\n")
  cat("10. Save the downloaded file as 'oauth_client.json' in the project root\n")
  cat("11. Run this script again.\n\n")

  cat("\nOAuth scope required: https://www.googleapis.com/auth/gmail.send\n")
  cat("IMPORTANT: If Google requires verification, go to 'OAuth consent screen'\n")
  cat("and add your email as a test user. No verification is needed for test mode.\n\n")
  quit(status = 1)
}

cat("[OK] oauth_client.json found.\n\n")

# ---- Step 2: Configure OAuth client ------------------------------------------
cat("Configuring OAuth client...\n")
gm_auth_configure(path = client_path)

# ---- Step 3: Choose authentication flow --------------------------------------
cat("\nWhich authentication flow do you want to use?\n")
cat("  1. Browser-based (opens a browser window; requires GUI)\n")
cat("  2. Out-of-band / device flow (copies a URL to terminal; works headless)\n")
cat("  3. Auto-detect (tries browser first, falls back to out-of-band)\n")
cat("\nEnter choice [1/2/3, default=3]: ")
choice <- trimws(readLines(con = "stdin", n = 1))
if (!choice %in% c("1", "2", "3")) choice <- "3"

use_oob <- FALSE
if (choice == "2") {
  use_oob <- TRUE
  cat("Using out-of-band (terminal) flow.\n")
} else if (choice == "3") {
  has_display <- !identical(Sys.getenv("DISPLAY"), "") ||
    !identical(Sys.getenv("WAYLAND_DISPLAY"), "") ||
    .Platform$OS.type == "windows"
  if (!has_display) {
    use_oob <- TRUE
    cat("No display detected. Using out-of-band (terminal) flow.\n")
  } else {
    cat("Display detected. Trying browser-based flow.\n")
  }
}

# ---- Step 4: Authenticate ----------------------------------------------------
cat("\nAuthenticating...\n")
cat("Email: ", email, "\n", sep = "")
cat("Scope : https://www.googleapis.com/auth/gmail.send\n\n")

if (use_oob) {
  # Use gargle's device flow for headless environments
  if (requireNamespace("gargle", quietly = TRUE)) {
    old_ooob <- getOption("gargle_oauth_client_type")
    options(gargle_oauth_client_type = "installed")
    on.exit(options(gargle_oauth_client_type = old_ooob), add = TRUE)

    cat("Using out-of-band device flow.\n")
    cat("A URL will be displayed. Open it in a browser, authorize, and paste the code here.\n\n")

    # gm_auth with use_oob via gargle under the hood
    gm_auth(
      email = email,
      cache = FALSE,
      use_oob = TRUE
    )
  } else {
    cat("gargle package not available. Trying gm_auth with use_oob = TRUE...\n")
    gm_auth(
      email = email,
      cache = FALSE,
      use_oob = TRUE
    )
  }
} else {
  gm_auth(
    email = email,
    cache = FALSE
  )
}

token <- gm_token()
cat("\n[OK] Authentication successful!\n")

# ---- Step 5: Save plain token ------------------------------------------------
saveRDS(token, token_path)
cat("Plain token saved to: ", token_path, "\n", sep = "")

# ---- Step 6: Encrypt and encode token ----------------------------------------
key_text <- Sys.getenv("GMAILR_KEY", "")

if (!nzchar(key_text)) {
  cat("\n========================================\n")
  cat("  GMAILR_KEY IS NOT SET\n")
  cat("========================================\n\n")
  cat("To use encrypted tokens (required for GitHub Actions), set GMAILR_KEY.\n")
  cat("Generate a strong key:\n")
  cat('  Rscript -e "cat(openssl::rand_bytes(32) |> paste(collapse = \'\'), \'\\n\')"\n')
  cat("Then set it:\n")
  cat('  export GMAILR_KEY="your_strong_key_here"\n')
  cat("Or in PowerShell:\n")
  cat('  $env:GMAILR_KEY="your_strong_key_here"\n\n')

  cat("\nWithout GMAILR_KEY, you can still use the token locally.\n")
  cat("The plain token at '", token_path, "' is git-ignored.\n", sep = "")
} else {
  cat("\nEncrypting token with GMAILR_KEY...\n")
  key <- openssl::sha256(charToRaw(key_text))
  iv <- openssl::rand_bytes(16)
  encrypted <- openssl::aes_cbc_encrypt(serialize(token, NULL), key = key, iv = iv)
  payload <- list(version = 1L, cipher = "aes-256-cbc", iv = iv, data = encrypted)
  saveRDS(payload, encrypted_path)
  cat("Encrypted token saved to: ", encrypted_path, "\n", sep = "")

  # Encode to base64
  encrypted_raw <- readBin(encrypted_path, what = "raw", n = file.info(encrypted_path)$size)
  b64_string <- jsonlite::base64_enc(encrypted_raw)
  writeLines(b64_string, b64_path, useBytes = TRUE)
  cat("Base64-encoded token saved to: ", b64_path, "\n", sep = "")

  cat("\n========================================\n")
  cat("  GITHUB SECRETS CONFIGURATION\n")
  cat("========================================\n\n")

  cat("Copy these values to your GitHub repository secrets:\n\n")

  cat("1. Go to: https://github.com/santosry/agent-news/settings/secrets/actions\n")
  cat("2. Create secret GMAILR_KEY with value:\n\n")
  cat("   ", key_text, "\n\n")
  cat("3. Create secret GMAILR_TOKEN_ENC_B64 with value:\n\n")
  cat("   ", b64_string, "\n\n")

  cat("---- OR copy from secrets/token_base64.txt ----\n")

  # Also encode the oauth_client.json for GMAILR_KEY usage
  if (file.exists(client_path)) {
    oauth_raw <- readBin(client_path, what = "raw", n = file.info(client_path)$size)
    oauth_b64 <- jsonlite::base64_enc(oauth_raw)
    cat("\nIf you also want to store oauth_client.json as a secret:\n")
    cat("Create secret GMAIL_OAUTH_B64 with value:\n\n")
    cat("   ", oauth_b64, "\n\n")

    oauth_b64_path <- "secrets/oauth_client_b64.txt"
    writeLines(oauth_b64, oauth_b64_path, useBytes = TRUE)
    cat("Base64-encoded OAuth client saved to: ", oauth_b64_path, "\n", sep = "")
  }
}

# ---- Step 7: Final summary ---------------------------------------------------
cat("\n========================================\n")
cat("  SETUP COMPLETE\n")
cat("========================================\n\n")

cat("Files created (git-ignored):\n")
cat("  ", token_path, " - Plain token for local use\n", sep = "")
if (nzchar(key_text)) {
  cat("  ", encrypted_path, " - Encrypted token\n", sep = "")
  cat("  secrets/token_base64.txt - Base64 for GitHub Secrets\n", sep = "")
  if (file.exists("secrets/oauth_client_b64.txt")) {
    cat("  secrets/oauth_client_b64.txt - OAuth client base64\n")
  }
}

cat("\nEnvironment variables needed:\n")
cat("  GMAILR_KEY          = (your key, also set as GitHub Secret)\n")
cat("  GMAILR_TOKEN_ENC_B64 = (from secrets/token_base64.txt, set as GitHub Secret)\n")
cat("  EMAIL_FROM           = ", email, "\n", sep = "")

cat("\nGitHub Secrets to create:\n")
cat("  GMAILR_KEY            = your encryption key\n")
cat("  GMAILR_TOKEN_ENC_B64   = content of secrets/token_base64.txt\n")
if (file.exists("secrets/oauth_client_b64.txt")) {
  cat("  GMAIL_OAUTH_B64        = content of secrets/oauth_client_b64.txt\n")
}

cat("\nTo test locally:\n")
cat('  DRY_RUN=true Rscript agent_news.R\n')
cat('  DRY_RUN=false EMAIL_FROM=', email, ' Rscript agent_news.R\n', sep = '')

cat("\nDone!\n")
