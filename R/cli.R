# Argumentos de linha de comando ----------------------------------------------

parse_args <- function(args) {
  mode_value <- NULL
  mode_idx <- which(args == "--mode")
  if (length(mode_idx) > 0 && mode_idx[[1]] < length(args)) {
    mode_value <- args[[mode_idx[[1]] + 1L]]
  }

  list(
    dry_run = if ("--dry-run" %in% args) TRUE else if ("--send" %in% args) FALSE else NULL,
    test_mode = if ("--test" %in% args) TRUE else NULL,
    mode = mode_value
  )
}
