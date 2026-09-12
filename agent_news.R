#!/usr/bin/env Rscript

source_files <- list.files("R", pattern = "[.]R$", full.names = TRUE, recursive = TRUE)
for (file in sort(source_files)) {
  source(file, local = FALSE)
}

args <- parse_args(commandArgs(trailingOnly = TRUE))
config <- load_config(
  dry_run = args$dry_run,
  test_mode = args$test_mode,
  mode = args$mode
)

result <- tryCatch(
  run_agent(config = config),
  error = function(e) {
    list(
      ok = FALSE,
      message = paste0("Agent failed: ", conditionMessage(e)),
      status = NULL,
      error = conditionMessage(e)
    )
  }
)

if (!isTRUE(result$ok)) {
  stop(result$message, call. = FALSE)
}

cat(result$message, "\n")
if (!is.null(result$html_path)) {
  cat("HTML:", result$html_path, "\n")
}
if (!is.null(result$audit_path)) {
  cat("Audit:", result$audit_path, "\n")
}
if (!is.null(result$report_path)) {
  cat("Run report:", result$report_path, "\n")
}
if (!is.null(result$agent_audit_path)) {
  cat("Agent audit:", result$agent_audit_path, "\n")
}
