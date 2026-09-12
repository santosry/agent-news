`%||%` <- function(x, y) {
  if (is.null(x) || length(x) == 0 || all(is.na(x))) y else x
}

as_bool <- function(x, default = FALSE) {
  if (is.null(x) || length(x) == 0 || is.na(x) || identical(x, "")) return(default)
  tolower(trimws(as.character(x))) %in% c("1", "true", "yes", "y", "sim")
}

default_recipients <- function() {
  c("seu.email@exemplo.com")
}

# E-mail de teste permanente: usado SOMENTE em test_mode e em desenvolvimento.
test_recipient <- function() {
  "ryandpaulosantos@gmail.com"
}

# Destinatários permanentes que SEMPRE entram na lista normal de envio.
permanent_recipients <- function() {
  "thaynafarias2007@gmail.com"
}

# Resolve a lista efetiva de destinatários de acordo com o modo de execução.
#
# Regras explícitas (sem ambiguidade):
#   - dry_run   => character(0)  (nenhum envio)
#   - test_mode => c(test_recipient())  (envia somente para o e-mail de teste)
#   - normal    => lista configurada + destinatários permanentes
resolve_send_recipients <- function(valid_recipients, dry_run = FALSE, test_mode = FALSE) {
  if (isTRUE(dry_run)) {
    return(character())
  }
  if (isTRUE(test_mode)) {
    return(test_recipient())
  }
  unique(c(valid_recipients, permanent_recipients()))
}

parse_recipients <- function(value, default = default_recipients()) {
  value <- value %||% ""
  if (!nzchar(value)) {
    candidates <- default
  } else {
    candidates <- unlist(strsplit(value, "[,;]", perl = TRUE), use.names = FALSE)
  }

  recipients <- candidates |>
    trimws() |>
    tolower()
  recipients <- recipients[nzchar(recipients)]
  recipients <- unique(recipients)

  valid <- stringr::str_detect(
    recipients,
    "^[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}$"
  )

  list(
    valid = recipients[valid],
    invalid = recipients[!valid]
  )
}

load_config <- function(dry_run = NULL, test_mode = NULL, mode = NULL, now = Sys.time()) {
  tz <- Sys.getenv("NEWS_TZ", "America/Sao_Paulo")
  dry <- dry_run %||% as_bool(Sys.getenv("DRY_RUN"), default = TRUE)
  test_mode <- test_mode %||% as_bool(
    Sys.getenv("AGENT_TEST_MODE"),
    default = as_bool(Sys.getenv("TEST_MODE"), default = FALSE)
  )
  now_tz <- lubridate::with_tz(now, tz)
  lookback_days <- as.integer(Sys.getenv("NEWS_LOOKBACK_DAYS", "30"))
  recipients <- parse_recipients(Sys.getenv("EMAIL_TO", ""))
  all_recipients <- unique(c(recipients$valid, permanent_recipients()))
  send_recipients <- resolve_send_recipients(recipients$valid, dry, test_mode)
  output_dir <- Sys.getenv("OUTPUT_DIR", "outputs")

  list(
    timezone = tz,
    timezone_label = Sys.getenv("NEWS_TIMEZONE_LABEL", "Horário de Brasília"),
    now = now_tz,
    window_start = now_tz - lubridate::days(lookback_days),
    window_end = now_tz,
    lookback_days = lookback_days,
    dry_run = dry,
    test_mode = test_mode,
    mode = tolower(mode %||% Sys.getenv("AGENT_MODE", "monitor")),
    email_from = Sys.getenv("EMAIL_FROM", ""),
    recipients = recipients$valid,
    all_recipients = all_recipients,
    send_recipients = send_recipients,
    invalid_recipients = recipients$invalid,
    email_transport = tolower(Sys.getenv("EMAIL_TRANSPORT", "gmailr")),
    deepseek_api_key = Sys.getenv("DEEPSEEK_API_KEY", ""),
    allow_no_deepseek = as_bool(Sys.getenv("ALLOW_NO_DEEPSEEK"), default = as_bool(Sys.getenv("ALLOW_NO_OPENAI"), default = FALSE)),
    rank_model = Sys.getenv("DEEPSEEK_RANK_MODEL", "deepseek-chat"),
    summary_model = Sys.getenv("DEEPSEEK_SUMMARY_MODEL", "deepseek-chat"),
    planner_model = Sys.getenv("DEEPSEEK_PLANNER_MODEL", "deepseek-chat"),
    deepseek_reasoning_effort = Sys.getenv("DEEPSEEK_REASONING_EFFORT", "low"),
    max_iterations = as.integer(Sys.getenv("AGENT_MAX_ITERATIONS", "12")),
    max_llm_calls = as.integer(Sys.getenv("AGENT_MAX_LLM_CALLS", "40")),
    tool_timeout_seconds = as.integer(Sys.getenv("AGENT_TOOL_TIMEOUT_SECONDS", "120")),
    min_articles_goal = as.integer(Sys.getenv("AGENT_MIN_ARTICLES", "5")),
    max_repeated_action = as.integer(Sys.getenv("AGENT_MAX_REPEATED_ACTION", "3")),
    schedule = Sys.getenv("AGENT_SCHEDULE", ""),
    min_score = as.numeric(Sys.getenv("NEWS_MIN_SCORE", "45")),
    source_min_score = as.numeric(Sys.getenv("NEWS_SOURCE_MIN_SCORE", "30")),
    min_news_per_source = as.integer(Sys.getenv("NEWS_MIN_NEWS_PER_SOURCE", "5")),
    max_candidates_per_source = as.integer(Sys.getenv("MAX_CANDIDATES_PER_SOURCE", "60")),
    news_per_source = as.integer(Sys.getenv("NEWS_PER_SOURCE", "10")),
    max_selected = as.integer(Sys.getenv("MAX_SELECTED_NEWS", "50")),
    source_timeout = as.integer(Sys.getenv("SOURCE_TIMEOUT_SECONDS", "20")),
    j3_max_pages = as.integer(Sys.getenv("J3_MAX_PAGES", "20")),
    iff_max_pages = as.integer(Sys.getenv("IFF_MAX_PAGES", "5")),
    uenf_max_pages = as.integer(Sys.getenv("UENF_MAX_PAGES", "5")),
    cnn_max_pages = as.integer(Sys.getenv("CNN_MAX_PUBLIC_PAGES", "4")),
    output_dir = output_dir,
    memory_path = Sys.getenv("AGENT_MEMORY_PATH", file.path(output_dir, "agent-memory.json")),
    gmail_token_path = Sys.getenv("GMAIL_TOKEN_PATH", "secrets/gmailr-token.rds"),
    gmail_encrypted_token_path = Sys.getenv("GMAIL_ENCRYPTED_TOKEN_PATH", "secrets/gmailr-token.rds.enc"),
    gmail_oauth_client = Sys.getenv("GMAIL_OAUTH_CLIENT", "oauth_client.json"),
    gmail_key = Sys.getenv("GMAILR_KEY", ""),
    gmail_token_enc_b64 = Sys.getenv("GMAILR_TOKEN_ENC_B64", "")
  )
}

source_order <- function() {
  c("J3News", "Folha1", "IFF", "UENF", "BBC News", "CNN Brasil", "Cofen", "MEC", "Ministério da Saúde", "Coren-RJ", "CNPq", "FAPERJ", "CAPES", "IBM", "AHA")
}
