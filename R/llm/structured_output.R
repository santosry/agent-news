# Saída estruturada ------------------------------------------------------------
#
# Funções para descrever, recuperar e normalizar decisões JSON vindas do LLM.
# O executor continua sendo a autoridade final de validação (allowlist + tipos).

decision_schema <- function(registry) {
  list(
    type = "object",
    additionalProperties = FALSE,
    required = list("action", "reasoning_summary", "done"),
    properties = list(
      action = list(type = "string", enum = c(names(registry), "finalize")),
      arguments = list(type = "object"),
      reasoning_summary = list(type = "string"),
      expected_result = list(type = "string"),
      done = list(type = "boolean")
    )
  )
}

# Extrai um objeto JSON de texto livre (aceita markdown fences e texto ao redor).
parse_llm_json <- function(text) {
  if (is.null(text) || !is.character(text) || length(text) != 1 || is.na(text) || !nzchar(text)) {
    return(NULL)
  }

  cleaned <- trimws(text)
  cleaned <- stringr::str_replace_all(cleaned, "^```json\\s*|^```\\s*", "")
  cleaned <- stringr::str_replace_all(cleaned, "```$", "")

  parsed <- tryCatch(
    jsonlite::fromJSON(cleaned, simplifyVector = FALSE),
    error = function(e) NULL
  )
  if (is.list(parsed) && !is.null(names(parsed))) {
    return(parsed)
  }

  # Recuperação segura: primeiro `{` até o último `}`.
  start <- regexpr("{", cleaned, fixed = TRUE)[[1]]
  if (start > 0) {
    last <- regexpr("}([^}]*)$", cleaned)[[1]]
    if (last > start) {
      candidate <- substr(cleaned, start, last)
      parsed2 <- tryCatch(
        jsonlite::fromJSON(candidate, simplifyVector = FALSE),
        error = function(e) NULL
      )
      if (is.list(parsed2) && !is.null(names(parsed2))) {
        return(parsed2)
      }
    }
  }

  NULL
}

# Normaliza uma decisão (parsed JSON) em uma lista tipada e segura.
# Não valida a allowlist aqui — isso é papel de validate_action().
normalize_decision <- function(parsed) {
  if (is.null(parsed) || !is.list(parsed)) {
    return(list(valid = FALSE, error = "decision is not a JSON object"))
  }

  action <- parsed$action
  if (is.null(action) || !is.character(action) || length(action) != 1 || is.na(action) || !nzchar(action)) {
    return(list(valid = FALSE, error = "decision.action missing or invalid"))
  }

  args <- parsed$arguments %||% list()
  if (!is.list(args)) {
    args <- list()
  }

  list(
    valid = TRUE,
    action = action,
    arguments = args,
    reasoning_summary = as.character(parsed$reasoning_summary %||% NA_character_)[[1]],
    expected_result = as.character(parsed$expected_result %||% NA_character_)[[1]],
    done = isTRUE(parsed$done)
  )
}
