# Tool: verify_source ----------------------------------------------------------
#
# Verificação determinística de fonte/evidência. Não depende do LLM: verifica
# alcançabilidade da URL, reconhece domínios configurados e registra a evidência
# (e opcionalmente uma claim) no estado, para auditoria de qualidade.

verify_known_domains <- function() {
  c(
    "j3news.com",
    "folha1.com.br",
    "portal1.iff.edu.br",
    "uenf.br",
    "bbc.com",
    "bbci.co.uk",
    "cnnbrasil.com.br",
    "cofen.gov.br",
    "gov.br",
    "coren-rj.org.br",
    "faperj.br",
    "ibm.com",
    "heart.org",
    "ahajournals.org"
  )
}

domain_is_known <- function(url) {
  host <- tryCatch(httr2::url_parse(url)$hostname %||% "", error = function(e) "")
  if (!nzchar(host)) return(FALSE)
  any(vapply(verify_known_domains(), function(d) {
    identical(host, d) || endsWith(host, paste0(".", d))
  }, logical(1)))
}

tool_verify_source <- function() {
  tool_spec(
    name = "verify_source",
    description = "Verify that a source URL is reachable and whether it belongs to a configured/trusted domain; record evidence and optional claim.",
    parameters = list(
      list(name = "url", type = "string", required = TRUE, description = "URL to verify."),
      list(name = "source", type = "string", required = FALSE,
           description = "Known source name (optional, used for labelling).", default = NULL),
      list(name = "claim", type = "string", required = FALSE,
           description = "Optional factual claim to associate with this evidence.", default = NULL)
    ),
    validate = function(args, state, config) {
      if (!nzchar(args$url)) return(list(ok = FALSE, error = "url is required"))
      list(ok = TRUE)
    },
    run = function(args, state, config, memory) {
      state$verify_attempted <- TRUE

      url <- args$url
      reachable <- FALSE
      error <- NA_character_
      status <- NA_integer_
      body_text <- ""
      resp <- NULL

      tryCatch(
        {
          resp <- http_get(url, timeout = 15, accept = "text/html")
          status <- httr2::resp_status(resp)
          reachable <- status < 400
          if (reachable) {
            body_text <- tryCatch(response_text(resp), error = function(e) "")
          }
        },
        error = function(e) {
          error <<- conditionMessage(e)
          reachable <<- FALSE
        }
      )

      known <- domain_is_known(url)
      reliability <- if (known) "known_configured_source" else "external_unverified"
      evidence_quality <- if (reachable && known) "high" else if (reachable) "medium" else "low"

      # Verificação determinística de uma claim contra o texto recuperado.
      claim_status <- "unverified"
      if (!is.null(args$claim) && nzchar(args$claim)) {
        if (nzchar(body_text)) {
          claim_tokens <- token_set(args$claim)
          if (length(claim_tokens) > 0) {
            hits <- vapply(claim_tokens, function(t) has_normalized_term(normalize_title(body_text), t), logical(1))
            claim_status <- if (any(hits)) "corroborated" else "unsupported"
          }
        }
      }

      evidence <- list(
        url = url,
        source = args$source %||% NA_character_,
        reachable = reachable,
        http_status = status,
        known_domain = known,
        reliability = reliability,
        evidence_quality = evidence_quality,
        claim_status = claim_status,
        error = error,
        verified_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
      )
      state$evidence[[length(state$evidence) + 1L]] <- evidence

      if (!is.null(args$claim) && nzchar(args$claim)) {
        state$claims[[length(state$claims) + 1L]] <- list(
          claim = args$claim,
          url = url,
          reliability = reliability,
          evidence_quality = evidence_quality,
          status = claim_status,
          recorded_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
        )
      }

      list(
        summary = sprintf("Source %s: reachable=%s, domain_known=%s, evidence_quality=%s, claim_status=%s.",
                          url, reachable, known, evidence_quality, claim_status),
        result = evidence
      )
    }
  )
}
