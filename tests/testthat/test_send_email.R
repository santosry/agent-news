test_that("raw email encodes HTML part as base64 so links and emojis survive", {
  html <- "<a href='https://example.com/a'>Not\u00edcia \u2705</a><span>\u26a0\ufe0f</span>"
  raw <- build_raw_email("remetente@example.com", "destino@example.com", "Assunto com acento", html)

  # O corpo HTML deve ser enviado em base64 (preserva UTF-8), nunca em
  # quoted-printable sem codificar (o que corrompia emojis e atributos com "=").
  expect_match(raw, "Content-Transfer-Encoding: base64", fixed = TRUE)
  expect_no_match(raw, "quoted-printable", fixed = TRUE)

  html_b64 <- base64enc::base64encode(charToRaw(enc2utf8(html)))
  expect_match(raw, html_b64, fixed = TRUE)

  decoded <- rawToChar(base64enc::base64decode(html_b64))
  Encoding(decoded) <- "UTF-8"
  expect_equal(decoded, html)
  expect_match(decoded, "<a href='https://example.com/a'>", fixed = TRUE)
  expect_match(decoded, "\u2705", fixed = TRUE)
})

test_that("load_gmail_token lê token RDS comprimido em base64 (gzip) no formato do setup", {
  token <- list(
    email = "test@gmail.com",
    auth_token = list(access_token = "access", refresh_token = "refresh")
  )
  key_text <- "chave-de-teste-123"
  key <- openssl::sha256(charToRaw(key_text))
  iv <- openssl::rand_bytes(16)
  encrypted <- openssl::aes_cbc_encrypt(serialize(token, NULL), key = key, iv = iv)
  payload <- list(version = 1L, cipher = "aes-256-cbc", iv = iv, data = encrypted)

  path <- tempfile(fileext = ".rds")
  saveRDS(payload, path)
  raw <- readBin(path, what = "raw", n = file.info(path)$size)
  b64 <- jsonlite::base64_enc(raw)
  unlink(path)

  cfg <- load_config(dry_run = TRUE)
  cfg$gmail_token_path <- tempfile(fileext = ".rds") # inexistente
  cfg$gmail_key <- key_text
  cfg$gmail_token_enc_b64 <- b64
  cfg$gmail_encrypted_token_path <- tempfile(fileext = ".rds") # inexistente

  loaded <- load_gmail_token(cfg)
  expect_equal(loaded$email, "test@gmail.com")
  expect_equal(loaded$auth_token$access_token, "access")
  expect_equal(loaded$auth_token$refresh_token, "refresh")
})
