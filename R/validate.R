validate_run_invariants <- function(all_items, ranked, selected, status_tbl, config) {
  errors <- character()
  warnings <- character()

  if (nrow(status_tbl) != length(source_order())) {
    errors <- c(errors, "source_status_count_mismatch")
  }

  missing_sources <- setdiff(source_order(), status_tbl$source)
  if (length(missing_sources) > 0) {
    errors <- c(errors, paste0("missing_source_status:", paste(missing_sources, collapse = ",")))
  }

  if (nrow(all_items) > 0 && anyDuplicated(all_items$id) > 0) {
    warnings <- c(warnings, "duplicate_item_ids_detected")
  }

  if (nrow(selected) > 0) {
    if (any(is.na(selected$published_at))) {
      errors <- c(errors, "selected_item_without_valid_published_at")
    }
    if (any(!is_in_window(selected$published_at, config$window_start, config$window_end))) {
      errors <- c(errors, "selected_item_outside_window")
    }
    if (any(is.na(selected$url) | selected$url == "" | is.na(selected$title) | selected$title == "")) {
      errors <- c(errors, "selected_item_missing_title_or_url")
    }
    if ("canonical_id" %in% names(selected) && anyDuplicated(selected$canonical_id) > 0) {
      warnings <- c(warnings, "selected_items_share_canonical_id")
    }
  }

  if (!config$dry_run && length(config$recipients) == 0) {
    errors <- c(errors, "production_run_without_valid_recipients")
  }

  if (!config$dry_run && !openai_available(config) && !isTRUE(config$allow_no_openai)) {
    errors <- c(errors, "production_run_without_openai_key")
  }

  list(
    ok = length(errors) == 0,
    errors = errors,
    warnings = warnings
  )
}
