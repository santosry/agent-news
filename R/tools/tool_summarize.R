# Tool: summarize_article ------------------------------------------------------
#
# Gera resumos analíticos (DeepSeek ou fallback determinístico) para os itens
# selecionados, preservando fonte/URL/data/título e ressalvas explícitas.

tool_summarize_article <- function() {
  tool_spec(
    name = "summarize_article",
    description = "Generate analytical summaries for selected articles (all, or a subset by id).",
    parameters = list(
      list(name = "ids", type = "string[]", required = FALSE,
           description = "Optional vector of selected item ids to summarize. Defaults to all selected items.",
           default = NULL)
    ),
    validate = function(args, state, config) list(ok = TRUE),
    run = function(args, state, config, memory) {
      selected <- state$selected
      if (nrow(selected) == 0) {
        return(list(
          summary = "No selected articles to summarize.",
          result = list(summarized = 0L)
        ))
      }

      if (!is.null(args$ids) && length(args$ids) > 0) {
        selected <- selected |> dplyr::filter(.data$id %in% args$ids)
      }

      summarized <- summarize_selected(selected, config)
      state$summarized <- summarized
      state$summarized_done <- TRUE

      list(
        summary = sprintf("Summarized %d selected article(s).", nrow(summarized)),
        result = list(
          summarized = nrow(summarized),
          ids = summarized$id,
          has_caveat = sum(nzchar(summarized$caveat) & !stringr::str_detect(summarized$caveat, "Nenhuma ressalva"))
        )
      )
    }
  )
}
