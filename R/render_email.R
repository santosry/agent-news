render_email_html <- function(news, status_tbl, config) {
  top <- top_three(news)
  css <- paste(
    "font-family:Arial,Helvetica,sans-serif;color:#1f2933;line-height:1.5;",
    sep = ""
  )

  source_blocks <- purrr::map_chr(source_order(), function(source_name) {
    source_news <- news |>
      dplyr::filter(.data$source == source_name) |>
      dplyr::arrange(dplyr::desc(.data$score))
    status <- status_tbl |>
      dplyr::filter(.data$source == source_name) |>
      dplyr::slice_head(n = 1)

    if (nrow(source_news) == 0) {
      reason <- source_empty_message(status)
      return(glue::glue(
        "<h2 style='font-size:20px;margin:28px 0 8px;color:#111827'>{source_name}</h2>",
        "<p style='margin:0 0 16px;color:#6b7280'>{htmltools::htmlEscape(reason)}</p>"
      ))
    }

    cards <- purrr::map_chr(seq_len(nrow(source_news)), function(i) {
      item <- source_news[i, ]
      glue::glue(
        "<article style='border-top:1px solid #e5e7eb;padding:18px 0'>",
        "<h3 style='font-size:18px;margin:0 0 6px;color:#111827'><a href='{htmltools::htmlEscape(item$url)}' style='color:#111827;text-decoration:none'>{htmltools::htmlEscape(item$title_final)}</a></h3>",
        "<p style='margin:0 0 10px;color:#6b7280;font-size:13px'>{item$source} · {format(item$published_at, '%d/%m/%Y')} · {htmltools::htmlEscape(item$topic)} · escore {round(item$score)}</p>",
        "<p style='margin:0 0 10px'><strong>Resumo:</strong> {htmltools::htmlEscape(item$summary)}</p>",
        "<p style='margin:0 0 10px'><strong>Por que importa:</strong> {htmltools::htmlEscape(item$why_matters)}</p>",
        "<p style='margin:0 0 10px'><strong>Ressalva:</strong> {htmltools::htmlEscape(item$caveat)}</p>",
        "<p style='margin:0'><a href='{htmltools::htmlEscape(item$url)}' style='color:#b91c1c;text-decoration:underline'>Ler na fonte original</a></p>",
        "</article>"
      )
    })

    paste0(
      glue::glue("<h2 style='font-size:20px;margin:28px 0 8px;color:#111827'>{source_name}</h2>"),
      paste(cards, collapse = "\n")
    )
  })

  top_block <- if (nrow(top) == 0) {
    "<p style='margin:0;color:#6b7280'>Nenhuma notícia atingiu o limiar editorial configurado nesta execução.</p>"
  } else {
    paste(purrr::map_chr(seq_len(nrow(top)), function(i) {
      item <- top[i, ]
      glue::glue(
        "<li style='margin:0 0 12px'>",
        "<a href='{htmltools::htmlEscape(item$url)}' style='color:#111827;font-weight:bold;text-decoration:none'>{htmltools::htmlEscape(item$title_final)}</a>",
        "<br><span style='color:#6b7280'>{item$source}</span>",
        "<br><span>{htmltools::htmlEscape(item$justification)}</span>",
        "</li>"
      )
    }), collapse = "\n")
  }

  period <- glue::glue("{format(config$window_start, '%d/%m/%Y')} a {format(config$window_end, '%d/%m/%Y')}")

  paste0(
    "<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width, initial-scale=1'></head>",
    "<body style='margin:0;background:#f8fafc;padding:0'>",
    "<div style='display:none;max-height:0;overflow:hidden'>Clipping semanal de notícias selecionadas por IA.</div>",
    "<main style='", css, "max-width:760px;margin:0 auto;background:#ffffff;padding:28px 20px'>",
    "<h1 style='font-size:24px;margin:0 0 4px;color:#111827'>Radar semanal de notícias</h1>",
    "<p style='margin:0 0 24px;color:#6b7280'>Período observado: ", period, "</p>",
    "<section style='background:#f3f4f6;border-left:4px solid #b91c1c;padding:16px;margin:0 0 24px'>",
    "<h2 style='font-size:20px;margin:0 0 12px;color:#111827'>Ryan, leia estas 3</h2>",
    if (nrow(top) > 0) paste0("<ol style='padding-left:20px;margin:0'>", top_block, "</ol>") else top_block,
    "</section>",
    paste(source_blocks, collapse = "\n"),
    "<footer style='border-top:1px solid #e5e7eb;margin-top:30px;padding-top:16px;color:#6b7280;font-size:13px'>",
    "Nota metodológica: a seleção foi realizada por IA a partir do material público coletado. Consulte as fontes primárias para decisões críticas, uso científico ou confirmação de detalhes.",
    "</footer>",
    "</main></body></html>"
  )
}

source_empty_message <- function(status) {
  if (nrow(status) == 0) return("Fonte não executada.")
  switch(
    status$status[[1]],
    failed = paste("Falha técnica de coleta:", status$diagnostics[[1]]),
    no_items = "Fonte acessada, mas nenhum candidato foi descoberto.",
    no_valid_dates = "Fonte acessada, mas nenhuma notícia teve data de publicação validada.",
    no_window_items = "Fonte acessada, mas não houve notícia com data validada dentro da janela semanal.",
    ok = "Fonte coletada, mas nenhuma notícia atingiu o limiar editorial após ranking e deduplicação.",
    "Sem notícia selecionada nesta execução."
  )
}

write_email_html <- function(html, run_started_at, config) {
  dir.create(config$output_dir, showWarnings = FALSE, recursive = TRUE)
  path <- file.path(config$output_dir, paste0("weekly-news-", format(run_started_at, "%Y%m%d-%H%M%S"), ".html"))
  writeLines(html, path, useBytes = TRUE)
  normalizePath(path, winslash = "/", mustWork = FALSE)
}
