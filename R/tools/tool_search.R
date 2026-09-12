# Tool: search_news ------------------------------------------------------------
#
# Busca determinística por termo dentro dos itens já coletados (título/excerpt).
# Útil no modo "investigate" para localizar evidência antes de ranquear/resumir.

tool_search_news <- function() {
  tool_spec(
    name = "search_news",
    description = "Search already-collected news items by keyword (normalized, whole-term match) with an optional source filter.",
    parameters = list(
      list(name = "query", type = "string", required = TRUE,
           description = "Keyword(s) to search for in title/excerpt."),
      list(name = "source", type = "string", required = FALSE,
           description = "Optional source name filter.", default = NULL)
    ),
    validate = function(args, state, config) list(ok = TRUE),
    run = function(args, state, config, memory) {
      state$search_attempted <- TRUE

      pool <- state$items
      if (nrow(pool) == 0) {
        return(list(
          summary = "No collected items to search.",
          result = list(matches = character(), n = 0L)
        ))
      }

      if (!is.null(args$source) && nzchar(args$source)) {
        pool <- pool |> dplyr::filter(.data$source == args$source)
      }

      text <- normalize_title(paste(pool$title, pool$excerpt))
      hits <- has_normalized_term(text, args$query)

      matches <- pool |>
        dplyr::filter(hits) |>
        dplyr::arrange(dplyr::desc(.data$published_at)) |>
        dplyr::select("id", "source", "title", "url", "published_at")

      list(
        summary = sprintf("Found %d item(s) matching query '%s'.", sum(hits), args$query),
        result = list(
          n = sum(hits),
          matches = matches
        )
      )
    }
  )
}
