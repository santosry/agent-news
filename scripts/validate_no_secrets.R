#!/usr/bin/env Rscript

forbidden_tracked_patterns <- c(
  "^\\.Renviron$",
  "^oauth_client[.]json$",
  "^secrets/(?![.]gitkeep$)"
)

tracked <- system2("git", c("ls-files", "--cached", "--others", "--exclude-standard"), stdout = TRUE)
bad_paths <- tracked[Reduce(`|`, lapply(forbidden_tracked_patterns, function(pattern) {
  grepl(pattern, tracked, perl = TRUE)
}))]

scan_files <- tracked[!grepl("^(outputs|work|[.]git)/", tracked)]
scan_files <- scan_files[file.exists(scan_files)]
patterns <- c(
  "sk-[A-Za-z0-9_-]{20,}",
  "OPENAI_API_KEY\\s*=\\s*(?![.]+)[A-Za-z0-9_-]{16,}",
  "DEEPSEEK_API_KEY\\s*=\\s*(?![.]+)[A-Za-z0-9_-]{16,}",
  "GMAILR_KEY\\s*=\\s*(?![.]+)[A-Za-z0-9_-]{16,}",
  "\"client_secret\"\\s*:",
  "\"refresh_token\"\\s*:",
  "\"access_token\"\\s*:",
  "-----BEGIN [A-Z ]+PRIVATE KEY-----"
)

hits <- character()
for (file in scan_files) {
  text <- tryCatch(readLines(file, warn = FALSE, encoding = "UTF-8"), error = function(e) character())
  if (length(text) == 0) next
  matched <- vapply(patterns, function(pattern) any(grepl(pattern, text, perl = TRUE)), logical(1))
  if (any(matched)) hits <- c(hits, file)
}

if (length(bad_paths) > 0 || length(hits) > 0) {
  message("Secret validation failed.")
  if (length(bad_paths) > 0) message("Forbidden tracked paths: ", paste(unique(bad_paths), collapse = ", "))
  if (length(hits) > 0) message("Potential secret patterns in: ", paste(unique(hits), collapse = ", "))
  quit(status = 1)
}

message("Secret validation OK: no forbidden tracked secrets or secret-like patterns found.")
