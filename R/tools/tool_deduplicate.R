# Tool: deduplicate_news -------------------------------------------------------
#
# Executa a deduplicação exata existente e, opcionalmente, remove itens já
# processados em execuções anteriores (via memória persistente).

tool_deduplicate_news <- function() {
  tool_spec(
    name = "deduplicate_news",
    description = "Deduplicate collected items (exact URL/title) and optionally drop articles already processed in previous runs.",
    parameters = list(
      list(name = "use_memory", type = "boolean", required = FALSE,
           description = "If TRUE, also drop articles seen in previous runs (from persistent memory).",
           default = FALSE)
    ),
    validate = function(args, state, config) list(ok = TRUE),
    run = function(args, state, config, memory) {
      pool <- state$items
      if (nrow(pool) == 0) {
        return(list(
          summary = "No items to deduplicate.",
          result = list(before = 0L, after = 0L, dropped = 0L)
        ))
      }

      before <- nrow(pool)
      candidates <- pool |>
        dplyr::filter(is.na(.data$discard_reason) | .data$discard_reason == "") |>
        deduplicate_exact() |>
        filter_blocked_topics()

      # Itens elegíveis para dedup por memória: exclui política/eleições (bloqueio
      # rígido) e mantém apenas itens sem descarte.
      eligible <- candidates |>
        dplyr::filter(is.na(.data$discard_reason) | .data$discard_reason == "")

      if (isTRUE(args$use_memory) && !is.null(memory)) {
        seen <- memory_seen_articles(memory)
        fresh <- eligible |>
          dplyr::filter(!.data$url %in% seen$url)

        # Garante pelo menos 1 item por fonte: quando uma fonte não tem item
        # "novo", recupera o melhor item elegível (não político) mesmo que já
        # tenha sido visto em execuções anteriores — fonte coletada nunca fica vazia.
        missing_sources <- setdiff(unique(eligible$source), unique(fresh$source))
        if (length(missing_sources) > 0) {
          rescue <- eligible |>
            dplyr::filter(.data$source %in% missing_sources) |>
            dplyr::group_by(.data$source) |>
            dplyr::arrange(dplyr::desc(.data$published_at), .by_group = TRUE) |>
            dplyr::slice_head(n = 1) |>
            dplyr::ungroup()
          fresh <- dplyr::bind_rows(fresh, rescue) |>
            dplyr::distinct(.data$url, .keep_all = TRUE)
        }
        candidates <- fresh
      }

      state$candidates <- candidates
      state$deduplicated <- TRUE

      list(
        summary = sprintf("Deduplicated %d items down to %d candidates.", before, nrow(candidates)),
        result = list(before = before, after = nrow(candidates), dropped = before - nrow(candidates))
      )
    }
  )
}
