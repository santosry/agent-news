# Executor e registry de ferramentas ------------------------------------------
#
# O executor é a única porta de entrada para a execução de operações. O LLM
# (planner) NUNCA recebe código R: ele só pode escolher, por nome, uma das
# ferramentas registradas abaixo e fornecer argumentos estruturados.
#
# Nenhuma função deste arquivo usa eval/parse em conteúdo vindo do modelo.

tool_spec <- function(name, description, parameters = list(), validate = NULL, run = NULL) {
  list(
    name = name,
    description = description,
    parameters = parameters,
    validate = validate,
    run = run
  )
}

tool_registry <- function() {
  list(
    collect_news = tool_collect_news(),
    search_news = tool_search_news(),
    fetch_article = tool_fetch_article(),
    deduplicate_news = tool_deduplicate_news(),
    rank_news = tool_rank_news(),
    verify_source = tool_verify_source(),
    summarize_article = tool_summarize_article(),
    generate_report = tool_generate_report(),
    send_report = tool_send_report()
  )
}

tool_names <- function(registry) {
  names(registry)
}

# Assinatura canônica de uma ação, para detecção de loops improdutivos.
action_signature <- function(action) {
  args <- action$arguments %||% list()
  if (length(args) > 0) {
    args <- args[order(names(args))]
  }
  paste0(action$tool %||% "?", ":", jsonlite::toJSON(args, auto_unbox = TRUE, null = "null"))
}

# Descrição compacta das ferramentas para o prompt do planner.
tools_description <- function(registry) {
  purrr::map_chr(registry, function(tool) {
    params <- if (length(tool$parameters) == 0) {
      "no arguments"
    } else {
      paste(
        purrr::map_chr(tool$parameters, function(p) {
          paste0(p$name, " (", p$type, if (isTRUE(p$required)) ", required" else ", optional", ")")
        }),
        collapse = ", "
      )
    }
    paste0("- ", tool$name, ": ", tool$description, " [", params, "]")
  })
}

is_atomic_arg <- function(x) {
  is.character(x) || is.numeric(x) || is.logical(x)
}

validate_tool_args <- function(tool, args) {
  args <- args %||% list()
  if (!is.list(args) || (length(args) > 0 && is.null(names(args)))) {
    return(list(ok = FALSE, error = "arguments must be a named list"))
  }

  allowed <- vapply(tool$parameters, function(p) p$name, character(1))
  unknown <- setdiff(names(args), allowed)
  if (length(unknown) > 0) {
    return(list(ok = FALSE, error = paste("unknown argument(s):", paste(unknown, collapse = ", "))))
  }

  normalized <- list()
  for (param in tool$parameters) {
    pname <- param$name
    if (isTRUE(param$required) && !pname %in% names(args)) {
      return(list(ok = FALSE, error = paste("missing required argument:", pname)))
    }
    if (!pname %in% names(args) || is.null(args[[pname]])) {
      if (!is.null(param$default)) {
        normalized[[pname]] <- param$default
      }
      next
    }

    value <- args[[pname]]
    if (!is_atomic_arg(value) || anyNA(value)) {
      return(list(ok = FALSE, error = paste("argument", pname, "must be a scalar character/numeric/logical")))
    }
    if (length(value) != 1 && !identical(param$type, "string[]")) {
      return(list(ok = FALSE, error = paste("argument", pname, "must be a single value")))
    }

    type_ok <- switch(
      param$type,
      string = is.character(value),
      `string[]` = is.character(value),
      number = is.numeric(value),
      integer = is.numeric(value) && (length(value) == 1) && (value == as.integer(value)),
      boolean = is.logical(value),
      FALSE
    )
    if (!type_ok) {
      return(list(ok = FALSE, error = paste("argument", pname, "must be of type", param$type)))
    }

    if (!is.null(param$allowed)) {
      value_chr <- if (param$type == "boolean") as.character(value) else value
      bad <- setdiff(as.character(value_chr), as.character(param$allowed))
      if (length(bad) > 0) {
        return(list(ok = FALSE, error = paste("argument", pname, "has disallowed value(s):", paste(bad, collapse = ", "))))
      }
    }

    normalized[[pname]] <- value
  }

  list(ok = TRUE, error = NULL, args = normalized)
}

# Valida uma decisão vinda do planner e a converte em uma ação executável.
validate_action <- function(decision, registry = tool_registry()) {
  if (!is.list(decision)) {
    return(list(ok = FALSE, error = "decision must be a JSON object"))
  }

  action_name <- decision$action
  if (is.null(action_name) || !is.character(action_name) || length(action_name) != 1 || is.na(action_name)) {
    return(list(ok = FALSE, error = "decision.action is required and must be a string"))
  }

  if (identical(action_name, "finalize")) {
    return(list(
      ok = TRUE,
      error = NULL,
      action = list(
        tool = "finalize",
        arguments = list(),
        reasoning_summary = decision$reasoning_summary %||% NA_character_,
        expected_result = decision$expected_result %||% NA_character_,
        done = TRUE
      )
    ))
  }

  if (!action_name %in% names(registry)) {
    return(list(ok = FALSE, error = paste("unknown tool:", action_name)))
  }

  tool <- registry[[action_name]]
  checked <- validate_tool_args(tool, decision$arguments %||% list())
  if (!checked$ok) {
    return(list(ok = FALSE, error = checked$error))
  }

  list(
    ok = TRUE,
    error = NULL,
    action = list(
      tool = action_name,
      arguments = checked$args,
      reasoning_summary = decision$reasoning_summary %||% NA_character_,
      expected_result = decision$expected_result %||% NA_character_,
      done = isTRUE(decision$done)
    )
  )
}

# Executa uma ação já validada. Envolve timeout e captura de erro. Nunca avalia
# código arbitrário: chama somente a função registrada da ferramenta.
execute_action <- function(action, state, config, registry = tool_registry(), memory = NULL) {
  started <- Sys.time()

  if (identical(action$tool, "finalize")) {
    return(list(
      ok = TRUE,
      tool = "finalize",
      elapsed_sec = as.numeric(difftime(Sys.time(), started, units = "secs")),
      summary = "Finalized by planner/evaluator.",
      result = list(done = TRUE)
    ))
  }

  tool <- registry[[action$tool]]
  if (is.null(tool)) {
    return(list(
      ok = FALSE,
      tool = action$tool,
      elapsed_sec = as.numeric(difftime(Sys.time(), started, units = "secs")),
      summary = "Tool not found in registry.",
      error = "tool_not_registered"
    ))
  }

  result <- tryCatch(
    {
      run_fun <- tool$run
      out <- run_fun(action$arguments, state, config, memory)
      list(
        ok = TRUE,
        tool = action$tool,
        elapsed_sec = as.numeric(difftime(Sys.time(), started, units = "secs")),
        summary = out$summary %||% NA_character_,
        result = out$result %||% out
      )
    },
    error = function(e) {
      list(
        ok = FALSE,
        tool = action$tool,
        elapsed_sec = as.numeric(difftime(Sys.time(), started, units = "secs")),
        summary = "Tool execution failed.",
        error = conditionMessage(e)
      )
    }
  )

  result
}
