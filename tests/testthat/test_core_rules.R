test_that("title normalization preserves semantic text and removes accents", {
  expect_equal(normalize_title("Vacina contra HPV é ampliada em Campos!"), "vacina contra hpv e ampliada em campos")
  expect_equal(normalize_title("  Ação pública: saúde & ciência  "), "acao publica saude ciencia")
})

test_that("recipient parsing normalizes, validates, and deduplicates addresses", {
  parsed <- parse_recipients(" RyanDPAuloSantos@gmail.com ; leticiamariadiasfreitas@gmail.com, bad, ryandpaulosantos@gmail.com ")
  expect_equal(parsed$valid, c("ryandpaulosantos@gmail.com", "leticiamariadiasfreitas@gmail.com"))
  expect_equal(parsed$invalid, "bad")
})

test_that("no-key production mode is explicit", {
  withr::local_envvar(c(
    DRY_RUN = "false",
    ALLOW_NO_DEEPSEEK = "true",
    EMAIL_TRANSPORT = "outlook",
    DEEPSEEK_API_KEY = ""
  ))
  cfg <- load_config()
  expect_false(cfg$dry_run)
  expect_true(cfg$allow_no_deepseek)
  expect_equal(cfg$email_transport, "outlook")
})

test_that("GitHub Actions schedule includes Brasilia Saturday and Wednesday runs", {
  workflow_path <- file.path("..", "..", ".github", "workflows", "weekly-news.yml")
  if (!file.exists(workflow_path)) {
    workflow_path <- file.path(".github", "workflows", "weekly-news.yml")
  }
  workflow <- yaml::read_yaml(workflow_path)
  crons <- purrr::map_chr(workflow[["on"]][["schedule"]], "cron")

  expect_true("0 11 * * 6" %in% crons)
  expect_true("0 20 * * 3" %in% crons)
  expect_equal(workflow$jobs$`weekly-news`$env$NEWS_TZ, "America/Sao_Paulo")
})

test_that("PowerShell command encoding is stable for Outlook transport", {
  encoded <- encode_powershell_command("Write-Output 'ok'")
  decoded <- jsonlite::base64_dec(encoded)
  expect_false(grepl("[\r\n]", encoded))
  expect_equal(as.integer(decoded[1:2]), c(87L, 0L))
})

test_that("Outlook COM failures are summarized without CLIXML noise", {
  output <- c(
    "#< CLIXML",
    "<S S=\"Error\">New-Object : Classe n\u00e3o registrada 80040154 REGDB_E_CLASSNOTREG</S>"
  )
  expect_match(clean_powershell_output(output), "Outlook desktop", fixed = TRUE)
})

test_that("heuristic ranking matches whole normalized terms", {
  items <- tibble::tibble(
    id = c("crime", "sus", "uenf"),
    source = c("Folha1", "Folha1", "UENF"),
    title = c("Jovem suspeito de roubo e preso", "SUS amplia atendimento em Campos", "UENF desenvolve metodologia inovadora"),
    excerpt = c("Caso policial sem relacao sanitaria.", "Politica publica de saude municipal.", "Pesquisa em laboratorio e inovacao."),
    published_at = lubridate::ymd_hms(rep("2026-07-05 10:00:00", 3), tz = "America/Sao_Paulo"),
    discard_reason = NA_character_
  )
  ranked <- heuristic_rank(items)
  expect_equal(ranked$topic[ranked$id == "crime"], "interesse público")
  expect_equal(ranked$topic[ranked$id == "sus"], "saúde pública")
  expect_equal(ranked$topic[ranked$id == "uenf"], "academia e instituições públicas")
  expect_gt(ranked$score[ranked$id == "uenf"], ranked$score[ranked$id == "crime"])
  expect_false(any(stringr::str_detect(ranked$justification, "DEEPSEEK_API_KEY|Ranking heur")))
  expect_true(all(nchar(ranked$justification) > 40))
})

test_that("deterministic fallback summary is editorial, not technical", {
  item <- tibble::tibble(
    id = "uenf",
    source = "UENF",
    title = "UENF abre inscrições para workshop de nanotecnologia",
    excerpt = "Evento reúne pesquisa, inovação e oportunidades acadêmicas.",
    published_at = lubridate::ymd_hms("2026-07-05 10:00:00", tz = "America/Sao_Paulo"),
    score = 90,
    topic = "academia e instituições públicas",
    justification = "teste",
    discard_reason = NA_character_
  )
  out <- fallback_summary(
    item,
    "A UENF abriu inscrições para um workshop interdisciplinar de nanotecnologia e inovação. A programação reúne pesquisadores, estudantes e atividades ligadas a desenvolvimento científico regional."
  )
  expect_match(out$summary, "UENF abriu inscrições", fixed = TRUE)
  expect_match(out$why_matters, "produção científica", fixed = TRUE)
  expect_false(stringr::str_detect(out$why_matters, "DEEPSEEK_API_KEY|heur"))
  expect_false(stringr::str_detect(out$caveat, "chamada à DeepSeek|DEEPSEEK_API_KEY"))
})

test_that("selection protects one relevant item per source before filling by score", {
  ranked <- tibble::tibble(
    id = c("j1", "j2", "f1", "i1", "u1", "b1", "c1"),
    source = c("J3News", "J3News", "Folha1", "IFF", "UENF", "BBC News", "CNN Brasil"),
    title = c("J1", "J2", "F1", "I1", "U1", "B1", "C1"),
    excerpt = "",
    published_at = lubridate::ymd_hms(rep("2026-07-05 10:00:00", 7), tz = "America/Sao_Paulo"),
    score = c(90, 88, 43, 44, 45, 42, 41),
    topic = "interesse público",
    justification = "teste",
    discard_reason = NA_character_
  )
  cfg <- load_config(dry_run = TRUE)
  cfg$min_score <- 55
  cfg$source_min_score <- 40
  cfg$min_news_per_source <- 1
  cfg$news_per_source <- 4
  cfg$max_selected <- 6
  selected <- select_for_clipping(ranked, cfg)
  expect_setequal(selected$source, c("J3News", "Folha1", "IFF", "UENF", "BBC News", "CNN Brasil"))
})

test_that("dates parse with timezone and respect seven day window", {
  tz <- "America/Sao_Paulo"
  now <- lubridate::ymd_hms("2026-07-05 18:00:00", tz = tz)
  start <- now - lubridate::days(7)
  expect_true(is_in_window(parse_datetime_sao("2026-07-05T18:09:44-03:00", tz), start, now + lubridate::hours(1)))
  expect_true(is_in_window(parse_datetime_sao("Sun, 05 Jul 2026 19:22:47 GMT", tz), start, now))
  expect_true(is_in_window(parse_datetime_sao("05/07/2026", tz, date_only_hour = 12), start, now))
  expect_true(is_in_window(parse_iff_datetime("05/07/2026", "13h45", tz), start, now))
  expect_false(is_in_window(parse_datetime_sao("2026-06-20T10:00:00-03:00", tz), start, now))
  expect_true(is.na(parse_datetime_sao("", tz)))
})

test_that("HTML and entity cleanup keeps accents readable", {
  expect_equal(clean_text("Jovem de 18 anos &eacute; morto em Guarus"), "Jovem de 18 anos é morto em Guarus")
})

test_that("fuzzy deduplication marks similar events", {
  items <- tibble::tibble(
    id = c("a", "b", "c"),
    source = c("J3News", "Folha1", "BBC News"),
    title = c(
      "Vacina contra HPV é ampliada para jovens",
      "HPV: vacinação é ampliada para adolescentes",
      "Central bank announces rate decision"
    ),
    excerpt = c("Campanha de vacinação contra HPV foi ampliada.", "Vacinação contra HPV passa a incluir adolescentes.", "Economy story."),
    published_at = lubridate::ymd_hms(c("2026-07-05 10:00:00", "2026-07-05 11:00:00", "2026-07-05 12:00:00"), tz = "America/Sao_Paulo"),
    score = c(90, 80, 70),
    topic = c("saúde", "saúde", "economia"),
    justification = c("a", "b", "c"),
    discard_reason = NA_character_
  )
  deduped <- deduplicate_ranked(items, threshold = 0.55)
  expect_equal(sum(deduped$discard_reason == "duplicate_or_same_event", na.rm = TRUE), 1)
})

test_that("top three selection is global by score", {
  selected <- tibble::tibble(
    id = letters[1:4],
    score = c(70, 95, 80, 90),
    published_at = lubridate::ymd_hms(rep("2026-07-05 10:00:00", 4), tz = "America/Sao_Paulo")
  )
  expect_equal(top_three(selected)$id, c("b", "d", "c"))
})

test_that("source failures are explicit and all-source failure is critical", {
  cfg <- load_config(dry_run = TRUE, now = lubridate::ymd_hms("2026-07-05 18:00:00", tz = "America/Sao_Paulo"))
  failed <- collect_source_safely("Fonte", function(config) stop("boom", call. = FALSE), cfg)
  expect_equal(failed$status, "failed")
  expect_true(all(c("IFF", "UENF") %in% source_order()))
  status_tbl <- tibble::tibble(source = source_order(), status = rep("failed", length(source_order())))
  expect_false(any_source_collected(status_tbl))
})
