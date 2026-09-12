# Tools: generate_report / send_report -----------------------------------------
#
# Separação explícita entre "produzir o relatório" (HTML + auditoria) e "enviar
# o relatório" (e-mail). O envio usa exclusivamente a lista resolvida pelo modo
# de execução (dry_run / test_mode / normal_mode) — o LLM NÃO define destinatários.

tool_generate_report <- function() {
  tool_spec(
    name = "generate_report",
    description = "Render the HTML report, write the HTML artifact and audit CSV/JSON.",
    parameters = list(),
    validate = function(args, state, config) list(ok = TRUE),
    run = function(args, state, config, memory) {
      if (nrow(state$summarized) == 0 && nrow(state$items) == 0) {
        return(list(
          summary = "Nothing collected; cannot generate a report.",
          result = list(generated = FALSE)
        ))
      }

      invariants <- validate_run_invariants(state$items, state$ranked, state$summarized, state$status_tbl, config)
      if (length(invariants$errors) > 0) {
        stop("Run invariant validation failed: ", paste(invariants$errors, collapse = "; "), call. = FALSE)
      }

      html <- render_email_html(state$summarized, state$status_tbl, config)
      html_path <- write_email_html(html, state$started_at, config)
      final_items <- build_audit_items(state$items, state$ranked)
      audit <- write_audit(final_items, state$started_at, state$summarized$id, config)

      state$html <- html
      state$html_path <- html_path
      state$audit <- audit
      state$report_generated <- TRUE

      list(
        summary = sprintf("Report generated with %d selected item(s).", nrow(state$summarized)),
        result = list(
          generated = TRUE,
          html_path = html_path,
          audit_csv = audit$csv_path,
          audit_json = audit$json_path,
          selected_count = nrow(state$summarized)
        )
      )
    }
  )
}

tool_send_report <- function() {
  tool_spec(
    name = "send_report",
    description = "Send the generated HTML report by email using the configured delivery mode (dry_run sends nothing; test_mode sends only to the test recipient).",
    parameters = list(),
    validate = function(args, state, config) list(ok = TRUE),
    run = function(args, state, config, memory) {
      if (is.null(state$html)) {
        stop("Report has not been generated yet.", call. = FALSE)
      }

      send_result <- send_clipping(state$html, config)
      state$send_result <- send_result
      state$send_attempted <- TRUE
      state$sent <- isTRUE(send_result$any_success)

      invariants <- validate_run_invariants(state$items, state$ranked, state$summarized, state$status_tbl, config)
      report_path <- write_run_report(
        status_tbl = state$status_tbl,
        selected = state$summarized,
        invariants = invariants,
        send_result = send_result,
        run_started_at = state$started_at,
        config = config,
        html_path = state$html_path,
        audit_paths = state$audit
      )
      state$report_path <- report_path

      n_sent <- if (isTRUE(send_result$dry_run)) {
        0L
      } else {
        sum(send_result$per_recipient$status == "sent")
      }

      list(
        summary = sprintf(
          "Email delivery: dry_run=%s, test_mode=%s, sent=%d, recipients=%s.",
          isTRUE(send_result$dry_run),
          isTRUE(config$test_mode),
          n_sent,
          paste(config$send_recipients, collapse = ", ")
        ),
        result = list(
          dry_run = isTRUE(send_result$dry_run),
          any_success = isTRUE(send_result$any_success),
          n_sent = n_sent,
          recipients = config$send_recipients,
          report_path = report_path
        )
      )
    }
  )
}
