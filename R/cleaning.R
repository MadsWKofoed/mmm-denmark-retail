# =============================================================================
# R/cleaning.R
#
# Reusable helpers for scripts/01_ingest_clean.R: parsing messy dates,
# Danish decimal-comma numbers, currency conversion, and validation checks
# on the final weekly modelling table.
# =============================================================================

#' Read a raw semicolon-delimited platform export with every column forced to
#' character. This is deliberate: readr's automatic type guessing uses a
#' locale with grouping_mark = "," by default, which silently misparses
#' Danish decimal-comma numbers (e.g. "100257,62" becomes 10025762 -- the
#' comma is stripped as if it were a thousands separator, inflating the value
#' ~100x). Reading everything as character and parsing explicitly with
#' parse_danish_number()/parse_messy_dates() avoids that trap entirely.
read_raw_csv <- function(path) {
  readr::read_delim(path, delim = ";", show_col_types = FALSE,
                     col_types = readr::cols(.default = readr::col_character()),
                     locale = readr::locale(encoding = "UTF-8"))
}

#' Parse a vector of dates that may be in several different formats
#' (mixing within the same column across rows, as real messy exports do).
parse_messy_dates <- function(x) {
  fmts <- c("%Y-%m-%d", "%d-%m-%Y", "%d/%m/%Y", "%d.%m.%Y", "%m/%d/%Y")
  out <- as.Date(rep(NA, length(x)))
  remaining <- is.na(out)
  for (f in fmts) {
    if (!any(remaining)) break
    parsed <- as.Date(x[remaining], format = f)
    # guard against %m/%d/%Y silently parsing d/m/Y wrongly when day <= 12:
    # only accept if round-trip formatting matches the original string
    valid <- !is.na(parsed) & (format(parsed, f) == x[remaining])
    out[remaining][valid] <- parsed[valid]
    remaining <- is.na(out)
  }
  out
}

#' Parse a numeric vector that may use Danish decimal commas
#' ("1.234,56" or "1234,56") or standard decimal points ("1234.56").
parse_danish_number <- function(x) {
  x <- as.character(x)
  has_comma <- grepl(",", x, fixed = TRUE)
  x[has_comma] <- gsub("\\.", "", x[has_comma])   # strip thousands separators
  x[has_comma] <- gsub(",", ".", x[has_comma], fixed = TRUE)
  suppressWarnings(as.numeric(x))
}

#' Convert a value in mixed currencies to DKK using the fixed central rate.
convert_to_dkk <- function(value, currency, eur_dkk_rate = 7.46038) {
  dplyr::if_else(currency == "EUR", value * eur_dkk_rate, value)
}

#' Aggregate a daily tibble with a `date` column to ISO weeks (Mon-start),
#' summing the given value columns.
aggregate_to_iso_week <- function(df, date_col, value_cols) {
  df |>
    dplyr::mutate(
      iso_year = lubridate::isoyear(.data[[date_col]]),
      iso_week = lubridate::isoweek(.data[[date_col]]),
      week_start = lubridate::floor_date(.data[[date_col]], unit = "week", week_start = 1)
    ) |>
    dplyr::group_by(iso_year, iso_week, week_start) |>
    dplyr::summarise(dplyr::across(dplyr::all_of(value_cols), ~ sum(.x, na.rm = TRUE)), .groups = "drop") |>
    dplyr::arrange(week_start)
}

#' Validation checks on the final weekly modelling table. Stops with a clear
#' message on failure; returns TRUE invisibly on success.
validate_weekly_table <- function(df, expected_weeks) {
  errors <- character(0)

  all_weeks <- seq(min(df$week_start), max(df$week_start), by = "week")
  missing_weeks <- setdiff(as.character(all_weeks), as.character(df$week_start))
  if (length(missing_weeks) > 0) {
    errors <- c(errors, sprintf("Missing %d week(s): %s", length(missing_weeks),
                                 paste(head(missing_weeks, 5), collapse = ", ")))
  }

  if (nrow(df) != expected_weeks) {
    errors <- c(errors, sprintf("Expected %d weeks, got %d", expected_weeks, nrow(df)))
  }

  spend_cols <- grep("^spend_", names(df), value = TRUE)
  for (col in spend_cols) {
    if (any(df[[col]] < 0, na.rm = TRUE)) {
      errors <- c(errors, sprintf("Negative spend in column '%s'", col))
    }
  }

  if (any(is.na(df$revenue_dkk))) {
    errors <- c(errors, "NA values in revenue_dkk")
  }
  if (any(df$revenue_dkk <= 0, na.rm = TRUE)) {
    errors <- c(errors, "Non-positive revenue_dkk")
  }

  dup_weeks <- df$week_start[duplicated(df$week_start)]
  if (length(dup_weeks) > 0) {
    errors <- c(errors, sprintf("Duplicate week_start values: %s", paste(unique(dup_weeks), collapse = ", ")))
  }

  if (length(errors) > 0) {
    stop("Weekly table validation FAILED:\n  - ", paste(errors, collapse = "\n  - "), call. = FALSE)
  }
  invisible(TRUE)
}

#' Match campaign names to a channel/tactic/funnel-stage using the taxonomy
#' mapping table (glob-style patterns, e.g. "*Brand*"), first match wins in
#' row order -- so more specific patterns must be listed first for a given
#' platform (see config/taxonomy_map.csv).
#'
#' @param campaign_names Character vector of raw campaign/line-item names.
#' @param platform Single string identifying the raw_platform to filter to.
#' @param taxonomy Taxonomy mapping tibble (raw_platform, raw_campaign_pattern, channel, tactic, funnel_stage).
#' @return tibble with one row per input name: channel, tactic, funnel_stage (NA if unmatched).
match_taxonomy <- function(campaign_names, platform, taxonomy) {
  rules <- dplyr::filter(taxonomy, raw_platform == platform)
  out <- tibble::tibble(channel = NA_character_, tactic = NA_character_, funnel_stage = NA_character_)
  out <- out[rep(1, length(campaign_names)), ]
  unmatched <- rep(TRUE, length(campaign_names))
  for (i in seq_len(nrow(rules))) {
    if (!any(unmatched)) break
    pattern <- utils::glob2rx(rules$raw_campaign_pattern[i])
    hit <- unmatched & grepl(pattern, campaign_names, ignore.case = TRUE)
    out$channel[hit] <- rules$channel[i]
    out$tactic[hit] <- rules$tactic[i]
    out$funnel_stage[hit] <- rules$funnel_stage[i]
    unmatched[hit] <- FALSE
  }
  out
}

#' Reconcile aggregated weekly spend totals against the raw daily/weekly
#' source totals (in DKK, after currency conversion) within a tolerance.
reconcile_totals <- function(weekly_total, raw_total, tolerance = 0.01, label = "") {
  rel_diff <- abs(weekly_total - raw_total) / max(raw_total, 1)
  if (rel_diff > tolerance) {
    stop(sprintf("Reconciliation FAILED for %s: weekly total %.0f vs raw total %.0f (%.2f%% diff)",
                 label, weekly_total, raw_total, rel_diff * 100), call. = FALSE)
  }
  invisible(TRUE)
}
