log_line <- function(level, message, ..., .envir = parent.frame()) {
  text <- glue::glue(message, ..., .envir = .envir)
  cat(sprintf("[%s] %s %s\n", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), level, text))
}

log_info <- function(message, ...) log_line("INFO", message, ..., .envir = parent.frame())
log_warn <- function(message, ...) log_line("WARN", message, ..., .envir = parent.frame())
