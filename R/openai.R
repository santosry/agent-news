openai_available <- function(config) {
  nzchar(config$openai_api_key)
}

openai_schema_format <- function(name, schema) {
  list(
    type = "json_schema",
    name = name,
    strict = TRUE,
    schema = schema
  )
}

extract_response_output_text <- function(response) {
  output <- response$output %||% list()
  texts <- c()
  for (item in output) {
    content <- item$content %||% list()
    for (part in content) {
      if (!is.null(part$text)) texts <- c(texts, part$text)
    }
  }
  paste(texts, collapse = "\n")
}

openai_responses_json <- function(config, model, instructions, input, schema_name, schema, max_tries = 3) {
  body <- list(
    model = model,
    instructions = instructions,
    input = input,
    text = list(format = openai_schema_format(schema_name, schema)),
    reasoning = list(effort = config$openai_reasoning_effort),
    store = FALSE
  )

  last_error <- NULL
  for (attempt in seq_len(max_tries)) {
    resp <- tryCatch({
      httr2::request("https://api.openai.com/v1/responses") |>
        httr2::req_auth_bearer_token(config$openai_api_key) |>
        httr2::req_headers("Content-Type" = "application/json") |>
        httr2::req_timeout(90) |>
        httr2::req_body_json(body, auto_unbox = TRUE) |>
        httr2::req_perform()
    }, error = function(e) {
      last_error <<- conditionMessage(e)
      NULL
    })

    if (!is.null(resp) && httr2::resp_status(resp) < 400) {
      parsed <- jsonlite::fromJSON(httr2::resp_body_string(resp), simplifyVector = FALSE)
      output_text <- extract_response_output_text(parsed)
      if (!nzchar(output_text)) {
        last_error <- "OpenAI response did not contain output text."
      } else {
        return(jsonlite::fromJSON(output_text, simplifyVector = FALSE))
      }
    } else if (!is.null(resp)) {
      last_error <- paste("OpenAI HTTP", httr2::resp_status(resp), httr2::resp_body_string(resp))
    }

    Sys.sleep(min(8, 2 ^ attempt))
  }

  stop("OpenAI request failed after retries: ", last_error, call. = FALSE)
}
