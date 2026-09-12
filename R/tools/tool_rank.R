# Tool: rank_news --------------------------------------------------------------
#
# Ranqueia os candidatos (DeepSeek ou heurístico), aplica deduplicação fuzzy e
# seleciona o conjunto para o clipping — preservando o pipeline existente.

tool_rank_news <- function() {
  tool_spec(
    name = "rank_news",
    description = "Rank deduplicated candidates, fuzzy-deduplicate, and select the clipping set by relevance with source diversity.",
    parameters = list(),
    validate = function(args, state, config) list(ok = TRUE),
    run = function(args, state, config, memory) {
      candidates <- state$candidates
      if (nrow(candidates) == 0) {
        return(list(
          summary = "No candidates to rank.",
          result = list(ranked = 0L, selected = 0L)
        ))
      }

      ranked <- rank_news(candidates, config)
      ranked <- deduplicate_ranked(ranked)
      selected <- select_for_clipping(ranked, config)

      state$ranked <- ranked
      state$selected <- selected
      state$ranked_done <- TRUE

      list(
        summary = sprintf("Ranked %d candidates; selected %d for summary.", nrow(ranked), nrow(selected)),
        result = list(
          ranked = nrow(ranked),
          selected = nrow(selected),
          selected_sources = if (nrow(selected) > 0) sort(unique(selected$source)) else character()
        )
      )
    }
  )
}
