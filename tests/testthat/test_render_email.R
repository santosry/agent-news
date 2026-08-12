test_that("email rendering includes priority section, grouped sources, and links", {
  cfg <- load_config(dry_run = TRUE, now = lubridate::ymd_hms("2026-07-05 18:00:00", tz = "America/Sao_Paulo"))
  news <- tibble::tibble(
    id = c("1", "2", "3"),
    source = c("J3News", "BBC News", "CNN Brasil"),
    title_final = c("Sa\u00fade em Campos", "Climate policy", "Economia p\u00fablica"),
    url = c("https://j3news.com/a", "https://www.bbc.com/news/a", "https://www.cnnbrasil.com.br/a/"),
    published_at = lubridate::ymd_hms(rep("2026-07-05 10:00:00", 3), tz = "America/Sao_Paulo"),
    topic = c("sa\u00fade", "clima", "economia"),
    score = c(99, 88, 77),
    summary = c("Resumo 1", "Resumo 2", "Resumo 3"),
    why_matters = c("Importa 1", "Importa 2", "Importa 3"),
    caveat = c("Sem ressalva material.", "Dados preliminares.", "Fonte \u00fanica."),
    justification = c("Prioridade m\u00e1xima", "Impacto clim\u00e1tico", "Impacto econ\u00f4mico")
  )
  status <- tibble::tibble(
    source = source_order(),
    status = rep("ok", length(source_order())),
    raw_count = 10L,
    valid_date_count = 8L,
    in_window_count = 5L,
    elapsed_sec = 1.5,
    diagnostics = NA_character_
  )
  html <- render_email_html(news, status, cfg)
  expect_match(html, "Leia estas 3 primeiro", fixed = TRUE)
  expect_no_match(html, "Ryan", fixed = TRUE)
  expect_match(html, "J3News", fixed = TRUE)
  expect_match(html, "Folha1", fixed = TRUE)
  expect_match(html, "IFF", fixed = TRUE)
  expect_match(html, "UENF", fixed = TRUE)
  expect_match(html, "https://j3news.com/a", fixed = TRUE)
  expect_match(html, "Status da coleta", fixed = TRUE)
})

test_that("email rendering declares deterministic method when DeepSeek is disabled", {
  withr::local_envvar(c(DEEPSEEK_API_KEY = "", ALLOW_NO_DEEPSEEK = "true"))
  cfg <- load_config(dry_run = TRUE, now = lubridate::ymd_hms("2026-07-05 18:00:00", tz = "America/Sao_Paulo"))
  news <- tibble::tibble(
    id = "1",
    source = "J3News",
    title_final = "Saude em Campos",
    url = "https://j3news.com/a",
    published_at = lubridate::ymd_hms("2026-07-05 10:00:00", tz = "America/Sao_Paulo"),
    topic = "saude",
    score = 99,
    summary = "Resumo",
    why_matters = "Importa",
    caveat = "Sem ressalva material.",
    justification = "Prioridade"
  )
  status <- tibble::tibble(
    source = source_order(),
    status = "ok",
    raw_count = 10L,
    valid_date_count = 8L,
    in_window_count = 5L,
    elapsed_sec = 1.5,
    diagnostics = NA_character_
  )
  html <- render_email_html(news, status, cfg)
  expect_match(html, "Status da coleta", fixed = TRUE)
  expect_no_match(html, "DEEPSEEK_API_KEY", fixed = TRUE)
  expect_no_match(html, "Ranking heur", fixed = TRUE)
  expect_no_match(html, "Ressalva:", fixed = TRUE)
})
