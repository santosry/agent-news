normalize_title <- function(x) {
  x |>
    stringi::stri_trans_general("Latin-ASCII") |>
    tolower() |>
    stringr::str_replace_all("&[a-z]+;", " ") |>
    stringr::str_replace_all("[^a-z0-9]+", " ") |>
    stringr::str_squish()
}

token_set <- function(x) {
  toks <- unlist(strsplit(normalize_title(x), "\\s+"), use.names = FALSE)
  toks <- toks[nchar(toks) >= 3]
  toks <- ifelse(nchar(toks) > 5, substr(toks, 1, 5), toks)
  setdiff(unique(toks), c("para", "com", "sem", "por", "que", "uma", "dos", "das", "nos", "nas", "aos", "sobre"))
}

title_similarity <- function(a, b) {
  a <- normalize_title(a)
  b <- normalize_title(b)
  if (!nzchar(a) || !nzchar(b)) return(0)
  dist <- utils::adist(a, b)[1, 1]
  edit_sim <- 1 - dist / max(nchar(a), nchar(b), 1)

  max(edit_sim, token_similarity(a, b))
}

token_similarity <- function(a, b) {
  ta <- token_set(a)
  tb <- token_set(b)
  jaccard <- if (length(union(ta, tb)) == 0) 0 else length(intersect(ta, tb)) / length(union(ta, tb))
  containment <- if (min(length(ta), length(tb)) == 0) 0 else length(intersect(ta, tb)) / min(length(ta), length(tb))
  max(jaccard, containment)
}

deduplicate_exact <- function(items) {
  if (nrow(items) == 0) return(items)
  items |>
    dplyr::arrange(.data$source, dplyr::desc(.data$published_at)) |>
    dplyr::distinct(.data$url, .keep_all = TRUE) |>
    dplyr::distinct(.data$source, .data$title_norm, .keep_all = TRUE)
}

deduplicate_ranked <- function(items, threshold = 0.82) {
  if (nrow(items) <= 1) {
    items$canonical_id <- items$id
    return(items)
  }

  items <- items |>
    dplyr::arrange(dplyr::desc(.data$score), dplyr::desc(.data$published_at))
  keep <- rep(TRUE, nrow(items))
  canonical <- items$id
  title_tokens <- lapply(items$title, token_set)

  for (i in seq_len(nrow(items))) {
    if (!keep[[i]]) next
    for (j in seq_len(nrow(items))) {
      if (j <= i || !keep[[j]]) next
      if (length(intersect(title_tokens[[i]], title_tokens[[j]])) < 2) next
      sim <- max(
        title_similarity(items$title[[i]], items$title[[j]]),
        token_similarity(
          paste(items$title[[i]], items$excerpt[[i]]),
          paste(items$title[[j]], items$excerpt[[j]])
        )
      )
      if (sim >= threshold) {
        keep[[j]] <- FALSE
        canonical[[j]] <- items$id[[i]]
      }
    }
  }

  items$canonical_id <- canonical
  items$discard_reason[!keep] <- "duplicate_or_same_event"
  items
}
