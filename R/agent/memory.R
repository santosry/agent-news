# Memória persistente ----------------------------------------------------------
#
# Armazenamento leve e auditável em um único arquivo JSON (nenhuma dependência
# extra além de `jsonlite`). As "tabelas" são listas nomeadas:
#   articles, sources, events, claims, evidence, agent_runs, agent_actions,
#   agent_decisions.
#
# Regra de higiene: não armazenamos o conteúdo integral das páginas — apenas
# identificadores, hashes, URLs, datas, metadados, resultados e o necessário
# para auditoria e para evitar reprocessamento.

agent_memory_tables <- function() {
  c(
    "articles", "sources", "events", "claims", "evidence",
    "agent_runs", "agent_actions", "agent_decisions"
  )
}

empty_memory <- function() {
  stats::setNames(
    lapply(agent_memory_tables(), function(x) list()),
    agent_memory_tables()
  )
}

memory_open <- function(config) {
  path <- config$memory_path
  if (is.null(path) || !nzchar(path)) {
    return(empty_memory())
  }

  if (file.exists(path)) {
    loaded <- tryCatch(
      jsonlite::fromJSON(path, simplifyVector = FALSE),
      error = function(e) NULL
    )
    if (is.list(loaded) && !is.null(names(loaded))) {
      base <- empty_memory()
      for (table in names(base)) {
        if (!is.null(loaded[[table]]) && is.list(loaded[[table]])) {
          base[[table]] <- loaded[[table]]
        }
      }
      return(base)
    }
  }

  empty_memory()
}

memory_save <- function(memory, config) {
  path <- config$memory_path
  if (is.null(path) || !nzchar(path)) return(invisible(memory))
  dir.create(dirname(path), showWarnings = FALSE, recursive = TRUE)
  jsonlite::write_json(memory, path, pretty = TRUE, auto_unbox = TRUE, null = "null")
  invisible(memory)
}

memory_append <- function(memory, table, row) {
  if (!table %in% agent_memory_tables()) {
    stop("Unknown memory table: ", table, call. = FALSE)
  }
  memory[[table]][[length(memory[[table]]) + 1L]] <- row
  invisible(memory)
}

memory_read <- function(memory, table) {
  if (!table %in% agent_memory_tables()) {
    stop("Unknown memory table: ", table, call. = FALSE)
  }
  rows <- memory[[table]] %||% list()
  if (length(rows) == 0) return(tibble::tibble())
  jsonlite::fromJSON(jsonlite::toJSON(rows, auto_unbox = TRUE), simplifyVector = TRUE, flatten = TRUE)
}

memory_count <- function(memory, table) {
  length(memory[[table]] %||% list())
}

# Artigos já vistos em execuções anteriores (por URL e por hash).
memory_seen_articles <- function(memory) {
  rows <- memory_read(memory, "articles")
  if (nrow(rows) == 0 || !all(c("url", "content_hash") %in% names(rows))) {
    return(list(url = character(), hash = character()))
  }
  list(
    url = unique(rows$url[!is.na(rows$url)]),
    hash = unique(rows$content_hash[!is.na(rows$content_hash)])
  )
}
