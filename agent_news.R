#!/usr/bin/env Rscript

source_files <- list.files("R", pattern = "[.]R$", full.names = TRUE)
for (file in sort(source_files)) {
  source(file, local = FALSE)
}

parse_args <- function(args) {
  list(
    dry_run = if ("--dry-run" %in% args) TRUE else if ("--send" %in% args) FALSE else NULL
  )
}

args <- parse_args(commandArgs(trailingOnly = TRUE))
config <- load_config(dry_run = args$dry_run)

result <- run_news_agent(config)

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
