run_news_agent <- function(config = load_config()) {
  run_started_at <- Sys.time()
  log_info("Weekly news agent started. dry_run={config$dry_run}")
  log_info("Window: {format(config$window_start, '%Y-%m-%d %H:%M:%S %Z')} to {format(config$window_end, '%Y-%m-%d %H:%M:%S %Z')} ({config$timezone_label})")
  log_info("DeepSeek ranking model: {config$rank_model}; summary model: {config$summary_model}")
  log_info("Recipients: {paste(config$recipients, collapse = ', ')}")

  if (length(config$invalid_recipients) > 0) {
    log_warn("Invalid recipients ignored: {paste(config$invalid_recipients, collapse = ', ')}")
  }

  collectors <- news_collectors()

  source_results <- purrr::imap(collectors, ~ collect_source_safely(.y, .x, config))
  status_tbl <- source_status_table(source_results)
  all_items <- purrr::map_dfr(source_results, "items")
  if (!any_source_collected(status_tbl)) {
    return(list(ok = FALSE, message = "Critical failure: none of the configured sources was collected.", status = status_tbl))
  }

  candidates <- all_items |>
    dplyr::filter(is.na(.data$discard_reason) | .data$discard_reason == "") |>
    deduplicate_exact()

  log_info("Candidates after exact deduplication: {nrow(candidates)}")

  ranked <- rank_news(candidates, config)
  ranked <- deduplicate_ranked(ranked)
  selected <- select_for_clipping(ranked, config)

  log_info("Selected for summary: {nrow(selected)}")

  summarized <- summarize_selected(selected, config)
  invariants <- validate_run_invariants(all_items, ranked, summarized, status_tbl, config)
  if (length(invariants$errors) > 0) {
    stop("Run invariant validation failed: ", paste(invariants$errors, collapse = "; "), call. = FALSE)
  }
  html <- render_email_html(summarized, status_tbl, config)
  html_path <- write_email_html(html, run_started_at, config)

  final_items <- all_items |>
    dplyr::select(-dplyr::any_of(c("score", "topic", "justification", "canonical_id"))) |>
    dplyr::left_join(
      ranked |>
        dplyr::select("id", "score", "topic", "justification", "canonical_id", "discard_reason"),
      by = "id",
      suffix = c("", "_ranked")
    ) |>
    dplyr::mutate(
      score = .data$score %||% NA_real_,
      topic = .data$topic %||% NA_character_,
      discard_reason = dplyr::coalesce(.data$discard_reason_ranked, .data$discard_reason)
    ) |>
    dplyr::select(-dplyr::any_of("discard_reason_ranked"))

  audit <- write_audit(final_items, run_started_at, summarized$id, config)

  send_result <- send_clipping(html, config)
  report_path <- write_run_report(
    status_tbl = status_tbl,
    selected = summarized,
    invariants = invariants,
    send_result = send_result,
    run_started_at = run_started_at,
    config = config,
    html_path = html_path,
    audit_paths = audit
  )

  if (!config$dry_run && !isTRUE(send_result$any_success)) {
    return(list(
      ok = FALSE,
      message = "Critical failure: no recipient could receive the clipping.",
      status = status_tbl,
      html_path = html_path,
      audit_path = audit$csv_path,
      report_path = report_path,
      send_result = send_result
    ))
  }

  list(
    ok = TRUE,
    message = if (config$dry_run) "Dry run completed without sending email." else "Weekly clipping sent.",
    status = status_tbl,
    selected = summarized,
    html_path = html_path,
    audit_path = audit$csv_path,
    audit_json_path = audit$json_path,
    report_path = report_path,
    send_result = send_result
  )
}

news_collectors <- function() {
  list(
    J3News = collect_j3,
    Folha1 = collect_folha1,
    IFF = collect_iff,
    UENF = collect_uenf,
    `BBC News` = collect_bbc,
    `CNN Brasil` = collect_cnn,
    Cofen = collect_cofen,
    MEC = collect_mec,
    `Ministério da Saúde` = collect_saude,
    `Coren-RJ` = collect_coren
  )
}

any_source_collected <- function(status_tbl) {
  any(status_tbl$status %in% c("ok", "no_window_items", "no_valid_dates"))
}

source_status_table <- function(source_results) {
  purrr::map_dfr(source_results, function(x) {
    tibble::tibble(
      source = x$source,
      status = x$status,
      raw_count = x$raw_count,
      valid_date_count = x$valid_date_count,
      in_window_count = x$in_window_count,
      elapsed_sec = round(x$elapsed_sec %||% 0, 1),
      diagnostics = x$diagnostics %||% NA_character_
    )
  }) |>
    dplyr::arrange(match(.data$source, source_order()))
}
