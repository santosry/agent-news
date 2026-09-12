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
