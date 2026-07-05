test_that("email rendering includes priority section, grouped sources, and links", {
  cfg <- load_config(dry_run = TRUE, now = lubridate::ymd_hms("2026-07-05 18:00:00", tz = "America/Sao_Paulo"))
  news <- tibble::tibble(
    id = c("1", "2", "3"),
    source = c("J3News", "BBC News", "CNN Brasil"),
    title_final = c("Saúde em Campos", "Climate policy", "Economia pública"),
    url = c("https://j3news.com/a", "https://www.bbc.com/news/a", "https://www.cnnbrasil.com.br/a/"),
    published_at = lubridate::ymd_hms(rep("2026-07-05 10:00:00", 3), tz = "America/Sao_Paulo"),
    topic = c("saúde", "clima", "economia"),
    score = c(99, 88, 77),
    summary = c("Resumo 1", "Resumo 2", "Resumo 3"),
    why_matters = c("Importa 1", "Importa 2", "Importa 3"),
    caveat = c("Sem ressalva material.", "Dados preliminares.", "Fonte única."),
    justification = c("Prioridade máxima", "Impacto climático", "Impacto econômico")
  )
  status <- tibble::tibble(
    source = source_order(),
    status = c("ok", "ok", "ok", "ok"),
    diagnostics = NA_character_
  )
  html <- render_email_html(news, status, cfg)
  expect_match(html, "Ryan, leia estas 3", fixed = TRUE)
  expect_match(html, "J3News", fixed = TRUE)
  expect_match(html, "Folha1", fixed = TRUE)
  expect_match(html, "https://j3news.com/a", fixed = TRUE)
  expect_match(html, "Nota metodológica", fixed = TRUE)
})
