# Tool: collect_news -----------------------------------------------------------
#
# Coleta notícias das fontes configuradas (ou de um subconjunto explícito).
# Preserva os coletores existentes (collect_j3, collect_bbc, ...) e a coleta
# paralela segura com fallback.

tool_collect_news <- function() {
  tool_spec(
    name = "collect_news",
    description = "Collect news from configured sources (all or a subset) within the configured lookback window.",
    parameters = list(
      list(name = "sources", type = "string[]", required = FALSE,
           description = "Optional vector of source names to collect. Defaults to all configured sources.",
           default = NULL),
      list(name = "force", type = "boolean", required = FALSE,
           description = "If TRUE, re-collect even if sources were already collected.", default = FALSE)
    ),
    validate = function(args, state, config) list(ok = TRUE),
    run = function(args, state, config, memory) {
      if (isTRUE(state$collected) && !isTRUE(args$force)) {
        return(list(
          summary = "Collection already performed; skipping (use force=TRUE to re-collect).",
          result = list(already_collected = TRUE, source_status = state$status_tbl)
        ))
      }

      if (isTRUE(state$collected)) {
        state$recollect_attempted <- TRUE
      }

      collectors <- news_collectors()
      if (!is.null(args$sources) && length(args$sources) > 0) {
        unknown <- setdiff(args$sources, names(collectors))
        if (length(unknown) > 0) {
          stop("Unknown source(s): ", paste(unknown, collapse = ", "), call. = FALSE)
        }
        collectors <- collectors[args$sources]
      }

      source_results <- collect_sources(collectors, config)
      status_tbl <- source_status_table(source_results)
      all_items <- purrr::map_dfr(source_results, "items")

      state$status_tbl <- status_tbl
      state$items <- all_items
      state$collected <- TRUE

      ok <- any_source_collected(status_tbl)

      list(
        summary = sprintf(
          "Collected %d raw items from %d source(s); %d source(s) returned usable items.",
          nrow(all_items),
          length(collectors),
          sum(status_tbl$status %in% c("ok", "no_window_items", "no_valid_dates"))
        ),
        result = list(
          ok = ok,
          n_items = nrow(all_items),
          n_sources = length(collectors),
          source_status = status_tbl
        )
      )
    }
  )
}
