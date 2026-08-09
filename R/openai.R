deepseek_available <- function(config) {
  nzchar(config$deepseek_api_key)
}

# Keep backward-compatible alias
openai_available <- function(config) {
  deepseek_available(config)
}

json_schema_to_text <- function(schema, indent = 0) {
  # Convert JSON schema to a compact text description for the prompt
  lines <- c()
  if (!is.null(schema$properties)) {
    props <- names(schema$properties)
    for (i in seq_along(props)) {
      prop <- props[[i]]
      prop_schema <- schema$properties[[prop]]
      comma <- if (i < length(props)) "," else ""
      type_str <- prop_schema$type
      if (type_str == "array" && !is.null(prop_schema$items)) {
        if (!is.null(prop_schema$items$properties)) {
          item_props <- names(prop_schema$items$properties)
          type_str <- paste0("array of {", paste(item_props, collapse = ", "), "}")
        } else {
          type_str <- paste0("array of ", prop_schema$items$type)
        }
      }
      lines <- c(lines, paste0('"', prop, '": ', type_str, comma))
    }
  }
  paste0("{", paste(lines, collapse = " "), "}")
}

deepseek_chat_completions <- function(config, model, system_prompt, user_prompt, schema_name, schema, max_tries = 3) {
  # DeepSeek supports json_object but NOT json_schema strict mode.
  # We inject the expected schema into the system prompt.
  schema_text <- json_schema_to_text(schema)
  schema_instruction <- paste0(
    "\n\nYou MUST respond with a single JSON object matching this exact schema.\n",
    "Do NOT wrap the JSON in markdown code blocks. Output ONLY raw JSON.\n",
    "Schema:\n", schema_text
  )

  body <- list(
    model = model,
    messages = list(
      list(role = "system", content = paste0(system_prompt, schema_instruction)),
      list(role = "user", content = user_prompt)
    ),
    response_format = list(type = "json_object"),
    temperature = 0.1,
    max_tokens = 8192
  )

  if (stringr::str_detect(model, "deepseek-reasoner")) {
    body$reasoning_effort <- config$deepseek_reasoning_effort
  }

  last_error <- NULL
  for (attempt in seq_len(max_tries)) {
    resp <- tryCatch({
      httr2::request("https://api.deepseek.com/v1/chat/completions") |>
        httr2::req_auth_bearer_token(config$deepseek_api_key) |>
        httr2::req_headers(
          "Content-Type" = "application/json",
          "Accept" = "application/json"
        ) |>
        httr2::req_timeout(120) |>
        httr2::req_body_json(body, auto_unbox = TRUE) |>
        httr2::req_perform()
    }, error = function(e) {
      last_error <<- conditionMessage(e)
      NULL
    })

    if (!is.null(resp) && httr2::resp_status(resp) < 400) {
      raw_body <- httr2::resp_body_string(resp)
      parsed <- tryCatch(
        jsonlite::fromJSON(raw_body, simplifyVector = FALSE),
        error = function(e) NULL
      )

      if (is.null(parsed)) {
        last_error <- paste("DeepSeek response was not valid JSON:", substr(raw_body, 1, 300))
      } else {
        content_message <- parsed$choices[[1]]$message$content

        if (is.null(content_message) || !nzchar(content_message)) {
          last_error <- "DeepSeek response did not contain message content."
        } else {
          # Parse the JSON from the content (handle possible markdown wrapping)
          cleaned <- stringr::str_replace_all(content_message, "^```json\\s*|```$", "")
          cleaned <- trimws(cleaned)

          parsed_json <- tryCatch(
            jsonlite::fromJSON(cleaned, simplifyVector = FALSE),
            error = function(e) {
              # Try harder: find first { and last }
              start <- regexpr("{", cleaned, fixed = TRUE)[[1]]
              end <- regexpr("}([^}]*)$", cleaned)[[1]]
              if (start > 0 && end > start) {
                json_str <- substr(cleaned, start, end)
                jsonlite::fromJSON(json_str, simplifyVector = FALSE)
              } else {
                stop("Could not extract JSON from response")
              }
            }
          )
          return(parsed_json)
        }
      }
    } else if (!is.null(resp)) {
      body_str <- tryCatch(httr2::resp_body_string(resp), error = function(e) "unreadable body")
      error_details <- tryCatch({
        err <- jsonlite::fromJSON(body_str, simplifyVector = FALSE)
        err$error$message %||% body_str
      }, error = function(e) body_str)
      last_error <- paste("DeepSeek HTTP", httr2::resp_status(resp), "-", substr(error_details, 1, 500))
    }

    Sys.sleep(min(8, 2 ^ attempt))
  }

  stop("DeepSeek request failed after retries: ", last_error, call. = FALSE)
}
