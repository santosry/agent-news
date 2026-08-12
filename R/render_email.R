render_email_html <- function(news, status_tbl, config) {
  top <- top_three(news)

  source_colors <- list(
    "J3News" = "#b91c1c",
    "Folha1" = "#c2410c",
    "IFF" = "#047857",
    "UENF" = "#1d4ed8",
    "BBC News" = "#7c3aed",
    "CNN Brasil" = "#be123c",
    "Cofen" = "#0e7490",
    "MEC" = "#15803d",
    "Minist\u00e9rio da Sa\u00fade" = "#0891b2",
    "Coren-RJ" = "#a21caf"
  )

  source_blocks <- purrr::map_chr(source_order(), function(source_name) {
    source_news <- news |>
      dplyr::filter(.data$source == source_name) |>
      dplyr::arrange(dplyr::desc(.data$score))
    status <- status_tbl |>
      dplyr::filter(.data$source == source_name) |>
      dplyr::slice_head(n = 1)

    accent <- source_colors[[source_name]] %||% "#6b7280"

    if (nrow(source_news) == 0) {
      reason <- source_empty_message(status)
      return(glue::glue(
        "<div style='border-left:4px solid {accent};padding:12px 16px;margin:0 0 16px;background:#f9fafb;border-radius:0 8px 8px 0'>",
        "<h2 style='font-size:18px;margin:0 0 4px;color:{accent}'>{source_name}</h2>",
        "<p style='margin:0;color:#6b7280;font-size:13px'>{htmltools::htmlEscape(reason)}</p>",
        "</div>"
      ))
    }

    cards <- purrr::map_chr(seq_len(nrow(source_news)), function(i) {
      item <- source_news[i, ]
      summary_text <- trim_summary(item$summary, 500)
      glue::glue(
        "<div style='border-bottom:1px solid #e5e7eb;padding:14px 0'>",
        "<h3 style='font-size:16px;margin:0 0 6px;line-height:1.4'>",
        "<a href=\"{htmltools::htmlEscape(item$url)}\" target='_blank' style='color:#1a56db;font-weight:600'>{htmltools::htmlEscape(item$title_final)}</a>",
        "</h3>",
        "<p style='margin:0 0 8px;color:#9ca3af;font-size:12px'>{item$source} &middot; {format(item$published_at, '%d/%m/%Y')} &middot; {htmltools::htmlEscape(item$topic)}</p>",
        "<p style='margin:0;color:#374151;font-size:14px;line-height:1.6'>{htmltools::htmlEscape(summary_text)}</p>",
        "</div>"
      )
    })

    paste0(
      glue::glue("<h2 style='font-size:19px;margin:28px 0 10px;color:{accent};border-left:4px solid {accent};padding-left:12px'>{source_name}</h2>"),
      paste(cards, collapse = "\n")
    )
  })

  top_block <- if (nrow(top) == 0) {
    "<p style='margin:0;color:#6b7280'>Nenhuma not\u00edcia atingiu o limiar editorial nesta execu\u00e7\u00e3o.</p>"
  } else {
    paste(purrr::map_chr(seq_len(nrow(top)), function(i) {
      item <- top[i, ]
      top_accent <- source_colors[[item$source[[1]]]] %||% "#b91c1c"
      glue::glue(
        "<li style='margin:0 0 14px;padding:8px 0'>",
        "<a href=\"{htmltools::htmlEscape(item$url)}\" target='_blank' style='color:#1a56db;font-weight:bold;font-size:15px'>{htmltools::htmlEscape(item$title_final)}</a>",
        "<br><span style='color:#9ca3af;font-size:12px'>{item$source} &middot; {format(item$published_at, '%d/%m/%Y')}</span>",
        "<br><span style='color:#4b5563;font-size:13px'>{htmltools::htmlEscape(trim_summary(item$summary, 200))}</span>",
        "</li>"
      )
    }), collapse = "\n")
  }

  period <- glue::glue("{format(config$window_start, '%d/%m/%Y')} a {format(config$window_end, '%d/%m/%Y')} ({config$timezone_label})")

  paste0(
    "<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'></head>",
    "<body style='margin:0;background:#f1f5f9;padding:0;font-family:Arial,Helvetica,sans-serif'>",
    "<div style='display:none;max-height:0;overflow:hidden'>Clipping semanal de not\u00edcias selecionadas.</div>",
    "<div style='max-width:720px;margin:0 auto;background:#ffffff;padding:32px 24px'>",

    "<div style='background:linear-gradient(135deg,#1e293b,#334155);padding:28px 24px;margin:-32px -24px 24px;border-radius:0'>",
    "<h1 style='font-size:26px;margin:0 0 4px;color:#ffffff'>Radar Semanal de Not\u00edcias</h1>",
    "<p style='margin:0;color:#94a3b8;font-size:14px'>Per\u00edodo: ", period, "</p>",
    "</div>",

    "<div style='background:#fef2f2;border-left:4px solid #b91c1c;padding:20px;margin:0 0 28px;border-radius:0 8px 8px 0'>",
    "<h2 style='font-size:19px;margin:0 0 14px;color:#991b1b'>Leia estas 3 primeiro</h2>",
    if (nrow(top) > 0) paste0("<ol style='padding-left:20px;margin:0;color:#1f2937'>", top_block, "</ol>") else top_block,
    "</div>",

    paste(source_blocks, collapse = "\n"),

    # Source status footer
    render_status_table(status_tbl),

    "<div style='border-top:2px solid #e5e7eb;margin-top:32px;padding-top:18px;color:#9ca3af;font-size:12px;text-align:center'>",
    "Agent News &middot; Curadoria automatizada por IA &middot; ",
    format(config$now, "%d/%m/%Y %H:%M"),
    "</div>",

    "</div></body></html>"
  )
}

trim_summary <- function(text, max_chars = 500) {
  text <- clean_text(text %||% "")
  if (is.na(text) || nchar(text) <= max_chars) return(text %||% "")
  clipped <- substr(text, 1, max_chars)
  clipped <- stringr::str_remove(clipped, "\\s+\\S*$")
  paste0(clipped, "...")
}

source_empty_message <- function(status) {
  if (nrow(status) == 0) return("Fonte n\u00e3o executada.")
  switch(
    status$status[[1]],
    failed = paste("Falha na coleta. A fonte pode estar fora do ar ou com estrutura alterada."),
    no_items = "Nenhum conte\u00fado encontrado nesta semana.",
    no_valid_dates = "Not\u00edcias encontradas, mas sem data de publica\u00e7\u00e3o validada.",
    no_window_items = "Nenhuma not\u00edcia recente encontrada no per\u00edodo.",
    ok = "Fonte coletada, mas nenhuma not\u00edcia atingiu o limiar editorial.",
    "Sem not\u00edcia selecionada nesta execu\u00e7\u00e3o."
  )
}

render_status_table <- function(status_tbl) {
  if (nrow(status_tbl) == 0) return("")
  rows <- purrr::map_chr(seq_len(nrow(status_tbl)), function(i) {
    s <- status_tbl[i, ]
    icon <- dplyr::case_when(
      s$status == "ok" ~ "\u2705",
      s$status %in% c("no_window_items", "no_valid_dates") ~ "\u26a0\ufe0f",
      TRUE ~ "\u274c"
    )
    glue::glue("<tr><td style='padding:2px 8px;font-size:11px'>{icon}</td><td style='padding:2px 8px;font-size:11px'>{s$source}</td><td style='padding:2px 8px;font-size:11px;color:#6b7280'>{s$in_window_count} notícias</td></tr>")
  })
  paste0(
    "<div style='margin-top:24px;padding:12px 16px;background:#f9fafb;border-radius:8px'>",
    "<p style='margin:0 0 8px;font-size:13px;font-weight:600;color:#374151'>Status da coleta:</p>",
    "<table style='border-collapse:collapse'>",
    paste(rows, collapse = "\n"),
    "</table></div>"
  )
}

write_email_html <- function(html, run_started_at, config) {
  dir.create(config$output_dir, showWarnings = FALSE, recursive = TRUE)
  path <- file.path(config$output_dir, paste0("weekly-news-", format(run_started_at, "%Y%m%d-%H%M%S"), ".html"))
  writeLines(html, path, useBytes = TRUE)
  normalizePath(path, winslash = "/", mustWork = FALSE)
}
