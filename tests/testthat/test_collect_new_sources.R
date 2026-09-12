# Testes dos coletores das cinco novas fontes (CNPq, FAPERJ, CAPES, IBM, AHA).
#
# São testes determinísticos: usam fixtures/mocks locais, sem acesso à internet.
# Cada parser puro (parse_*) é exercitado com HTML/XML de exemplo para validar
# schema canônico, identificação de fonte, URL, título e tratamento de data.

make_test_config <- function() {
  load_config(dry_run = TRUE, now = lubridate::ymd_hms("2026-09-12 18:00:00", tz = "America/Sao_Paulo"))
}

test_that("CNPq: Atom feed parse returns canonical schema and filters PDFs/empty titles", {
  cfg <- make_test_config()
  xml <- paste0(
    '<?xml version="1.0" encoding="utf-8"?>',
    '<feed xmlns="http://www.w3.org/2005/Atom">',
    '<entry>',
    '<title>CNPq lança nova chamada de bolsas</title>',
    '<link rel="alternate" href="https://www.gov.br/cnpq/pt-br/assuntos/noticias/cnpq-em-acao/chamada-bolsas"/>',
    '<published>2026-09-10T10:00:00-03:00</published>',
    '<summary>Chamada pública para bolsas de pesquisa.</summary>',
    '</entry>',
    '<entry><title></title>',
    '<link rel="alternate" href="https://www.gov.br/cnpq/x"/>',
    '<published>2026-09-10T10:00:00-03:00</published></entry>',
    '<entry><title>Chamada 18/2026 (PDF)</title>',
    '<link rel="alternate" href="https://www.gov.br/cnpq/pt-br/chamadas/chamada-18.pdf/view"/>',
    '<published>2026-09-10T10:00:00-03:00</published></entry>',
    '</feed>'
  )

  rows <- parse_cnpq_feed(xml, cfg)

  expect_true(all(c("source", "title", "url", "published_at", "discard_reason") %in% names(rows)))
  expect_equal(nrow(rows), 1L)
  expect_equal(rows$source[[1]], "CNPq")
  expect_equal(rows$title[[1]], "CNPq lança nova chamada de bolsas")
  expect_true(!is.na(rows$published_at[[1]]))
  expect_true(is_in_window(rows$published_at[[1]], cfg$window_start, cfg$window_end))
})

test_that("CNPq: invalid/empty feed returns empty canonical table", {
  cfg <- make_test_config()
  expect_equal(nrow(parse_cnpq_feed("", cfg)), 0L)
  expect_equal(nrow(parse_cnpq_feed("not xml at all", cfg)), 0L)
  expect_equal(nrow(parse_cnpq_feed(NA_character_, cfg)), 0L)
})

test_that("FAPERJ: archive parse extracts title, url, date and regional keyword", {
  cfg <- make_test_config()
  html <- paste0(
    '<html><body>',
    '<blockquote><div style="font-weight:bold;"><a href="/?id=1100.7.8">FAPERJ divulga lista de aprovados</a></div>',
    '<div class="data-arquivo">01/09/2026</div><div>Empresas selecionadas no programa.</div></blockquote>',
    '<blockquote><div style="font-weight:bold;"><a href="/?id=1101.7.0">Pesquisa sobre hepatite B</a></div>',
    '<div class="data-arquivo">10/09/2026</div><div>Projeto da Fiocruz.</div></blockquote>',
    '</body></html>'
  )
  doc <- xml2::read_html(html, encoding = "UTF-8")
  rows <- parse_faperj_archive(doc, "https://www.faperj.br/?id=35.5.3", cfg)

  expect_equal(nrow(rows), 2L)
  expect_true(all(rows$source == "FAPERJ"))
  expect_equal(rows$url[[1]], "https://www.faperj.br/?id=1100.7.8")
  expect_equal(rows$title[[1]], "FAPERJ divulga lista de aprovados")
  expect_true(all(rows$keywords == "Rio de Janeiro"))
  expect_false(any(is.na(rows$published_at)))
  expect_true(all(is_in_window(rows$published_at, cfg$window_start, cfg$window_end)))
})

test_that("CAPES: article parse extracts og:title and effective date", {
  cfg <- make_test_config()
  html <- paste0(
    '<html><head>',
    '<meta property="og:title" content="Programas AmSud abrem nova seleção"/>',
    '<meta property="og:description" content="Seleção para pesquisadores."/>',
    '</head><body>{"effective":"2026-09-11T17:01:05+00:00"}</body></html>'
  )
  rows <- parse_capes_article(html, "https://www.gov.br/capes/pt-br/assuntos/noticias-defeso-eleitoral/programas-amsud", cfg)

  expect_equal(nrow(rows), 1L)
  expect_equal(rows$source[[1]], "CAPES")
  expect_equal(rows$title[[1]], "Programas AmSud abrem nova seleção")
  expect_true(!is.na(rows$published_at[[1]]))
  expect_true(is_in_window(rows$published_at[[1]], cfg$window_start, cfg$window_end))
})

test_that("CAPES: discover URLs keeps only news articles (not the listing folder)", {
  doc <- xml2::read_html(paste0(
    '<html><body>',
    '<a href="/capes/pt-br/assuntos/noticias-defeso-eleitoral">Listagem</a>',
    '<a href="/capes/pt-br/assuntos/noticias-defeso-eleitoral/slug-de-noticia">Notícia</a>',
    '<a href="/capes/pt-br/assuntos/servicos">Serviço</a>',
    '</body></html>'
  ), encoding = "UTF-8")

  urls <- capes_discover_urls(doc, "https://www.gov.br/capes/pt-br")
  expect_equal(length(urls), 1L)
  expect_true(grepl("slug-de-noticia", urls))
})

test_that("IBM: RSS parse returns canonical schema with valid dates", {
  cfg <- make_test_config()
  xml <- paste0(
    '<?xml version="1.0"?><rss version="2.0"><channel><title>IBM Research</title>',
    '<item><title><![CDATA[IBM and NASA release open-source AI model]]></title>',
    '<link>https://newsroom.ibm.com/2026-09-10-ibm-nasa-ai-model</link>',
    '<pubDate>Thu, 10 Sep 2026 08:00:00 -0400</pubDate>',
    '<description>Open-source AI model for lunar exploration.</description></item>',
    '</channel></rss>'
  )
  rows <- parse_ibm_rss(xml, cfg)

  expect_equal(nrow(rows), 1L)
  expect_true(all(rows$source == "IBM"))
  expect_true(all(c("title", "url", "published_at", "excerpt") %in% names(rows)))
  expect_true(!is.na(rows$published_at[[1]]))
  expect_true(is_in_window(rows$published_at[[1]], cfg$window_start, cfg$window_end))
})

test_that("AHA: RSS parse returns canonical schema with valid dates", {
  cfg <- make_test_config()
  xml <- paste0(
    '<?xml version="1.0"?><rss version="2.0"><channel><title>American Heart Association</title>',
    '<item><title>American Heart Association PREVENT equations integrated</title>',
    '<link>https://newsroom.heart.org/news/prevent-equations-integrated</link>',
    '<pubDate>Thu, 10 Sep 2026 12:00:00 GMT</pubDate>',
    '<description>PREVENT equations integrated into EHR platform.</description></item>',
    '</channel></rss>'
  )
  rows <- parse_aha_rss(xml, cfg)

  expect_equal(nrow(rows), 1L)
  expect_true(all(rows$source == "AHA"))
  expect_true(!is.na(rows$published_at[[1]]))
  expect_true(is_in_window(rows$published_at[[1]], cfg$window_start, cfg$window_end))
})

test_that("new sources are registered as distinct collectors and ordered", {
  collectors <- news_collectors()
  order <- source_order()

  expect_true(all(c("CNPq", "FAPERJ", "CAPES", "IBM", "AHA") %in% names(collectors)))
  expect_true(all(c("CNPq", "FAPERJ", "CAPES", "IBM", "AHA") %in% order))
  expect_equal(length(order), length(unique(order)))
  expect_equal(sort(names(collectors)), sort(order))
  expect_equal(length(order), 15L)
})

test_that("new domains are recognized as configured sources", {
  expect_true(domain_is_known("https://www.faperj.br/?id=1.2.3"))
  expect_true(domain_is_known("https://research.ibm.com/blog/x"))
  expect_true(domain_is_known("https://newsroom.ibm.com/announcements"))
  expect_true(domain_is_known("https://newsroom.heart.org/news/x"))
  expect_true(domain_is_known("https://www.gov.br/cnpq/pt-br"))
  expect_true(domain_is_known("https://www.gov.br/capes/pt-br"))
})

test_that("a failing new-source collector registers an explicit failure, not success", {
  cfg <- make_test_config()
  result <- collect_source_safely("CNPq", function(config) stop("boom", call. = FALSE), cfg)
  expect_equal(result$status, "failed")
  expect_match(result$diagnostics, "boom")
  expect_equal(nrow(result$items), 0L)
})

test_that("new-source items without a validated date are discarded, not silently accepted", {
  cfg <- make_test_config()
  rows <- tibble::tibble(
    id = "x",
    source = "AHA",
    title = "Sem data",
    url = "https://newsroom.heart.org/news/x",
    published_at = as.POSIXct(NA, tz = cfg$timezone),
    modified_at = as.POSIXct(NA),
    date_kind = "published",
    date_source = "none",
    excerpt = "",
    keywords = "",
    raw_source = "fixture",
    discard_reason = NA_character_
  )
  finished <- finish_source_result("AHA", rows, raw_count = 1L, config = cfg)
  expect_equal(finished$valid_date_count, 0L)
  expect_equal(finished$status, "no_valid_dates")
  expect_true(all(finished$items$discard_reason == "date_not_validated"))
})
