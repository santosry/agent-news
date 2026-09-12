# Tool: fetch_article ----------------------------------------------------------
#
# Recupera o texto completo de um artigo (reaproveita fetch_article_text do
# pipeline) e o guarda como evidência para resumo e verificação.

tool_fetch_article <- function() {
  tool_spec(
    name = "fetch_article",
    description = "Fetch the full article text for a collected item by id or url and store it as evidence.",
    parameters = list(
      list(name = "id", type = "string", required = FALSE,
           description = "Item id to fetch.", default = NULL),
      list(name = "url", type = "string", required = FALSE,
           description = "Item url to fetch (used when id is absent).", default = NULL)
    ),
    validate = function(args, state, config) {
      if (is.null(args$id) && is.null(args$url)) {
        return(list(ok = FALSE, error = "one of 'id' or 'url' is required"))
      }
      list(ok = TRUE)
    },
    run = function(args, state, config, memory) {
      pool <- state$items
      if (nrow(pool) == 0 && is.null(args$url)) {
        return(list(summary = "No collected items and no url supplied.", result = list(fetched = FALSE)))
      }

      item <- NULL
      if (!is.null(args$id) && nrow(pool) > 0 && args$id %in% pool$id) {
        item <- pool[pool$id == args$id, ][1, ]
      } else if (!is.null(args$url)) {
        idx <- which(pool$url == args$url)
        if (length(idx) > 0) {
          item <- pool[idx[1], ]
        } else {
          # Synthetic item when the url is not in the current collection.
          item <- tibble::tibble(
            id = stable_id("external", args$url),
            source = args$url,
            title = args$url,
            url = args$url,
            published_at = as.POSIXct(NA, tz = config$timezone),
            excerpt = "",
            discard_reason = NA_character_
          )
        }
      }

      if (is.null(item)) {
        return(list(summary = "Article not found in collected items.", result = list(fetched = FALSE)))
      }

      text <- fetch_article_text(item)
      key <- item$id[[1]]
      state$article_texts[[key]] <- text
      state$evidence[[key]] <- list(
        id = key,
        source = item$source[[1]],
        url = item$url[[1]],
        fetched_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
        n_chars = nchar(text %||% "")
      )

      list(
        summary = sprintf("Fetched %d characters of text for %s.", nchar(text %||% ""), key),
        result = list(
          fetched = nzchar(text %||% ""),
          id = key,
          url = item$url[[1]],
          n_chars = nchar(text %||% ""),
          preview = substr(text %||% "", 1, 240)
        )
      )
    }
  )
}
