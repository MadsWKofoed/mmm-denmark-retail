# =============================================================================
# R/raw_exports.R
#
# Turns the TRUE weekly media_spend (from R/simulation.R) into messy,
# realistic-looking RAW exports, one file per platform/system, at daily or
# weekly grain as each real platform would actually export. Deliberately
# injects the data-quality problems described in config/ground_truth.yml:
# mixed date formats, Danish decimal commas, EUR/DKK currency mix, duplicate
# rows, missing days, messy campaign names, ae/oe/aa characters, and
# platform-reported (last-click) revenue sitting next to spend.
#
# Nothing here is read by the modelling scripts directly -- scripts/01_*
# ("ingest and clean") is the only consumer, exactly as a real analyst would
# only ever see these exports, never the ground truth.
# =============================================================================

danish_num <- function(x, decimals = 2) {
  formatC(x, format = "f", digits = decimals, big.mark = "", decimal.mark = ",")
}

#' Spread a weekly total evenly-ish across 7 days with random daily noise,
#' but always summing back to (approximately) the weekly total.
weekly_to_daily <- function(week_start, weekly_value, n_days = 7, noise_sd = 0.15) {
  purrr::map2_dfr(week_start, weekly_value, function(ws, wv) {
    raw_w <- pmax(0, rgamma(n_days, shape = 4, scale = 1) * exp(rnorm(n_days, 0, noise_sd)))
    daily <- wv * raw_w / sum(raw_w)
    tibble::tibble(date = ws + 0:(n_days - 1), value = daily)
  })
}

#' Build a messy campaign name for a channel/tactic, Danish-flavoured.
messy_campaign_name <- function(channel, tactic, week_start, n = 1) {
  season_tag <- dplyr::case_when(
    lubridate::month(week_start) %in% 4:6 ~ "Havesaeson",
    lubridate::month(week_start) == 11 ~ "BlackFriday",
    lubridate::month(week_start) == 12 ~ "Jul",
    TRUE ~ "Alm"
  )
  prefixes <- c("HH", "Havehjornet", "hh_dk", "HAVEHJ")
  sep <- sample(c("_", "-", " "), 1)
  paste0(
    sample(prefixes, n, replace = TRUE), sep, channel, sep, tactic, sep, season_tag, sep,
    format(week_start, "%Y%m"), ifelse(runif(n) < 0.1, paste0(sep, "kopi"), "")
  )
}

#' Randomly format a set of dates in one of several messy formats (as a
#' character vector), simulating "mixed date formats" across raw exports.
messy_dates <- function(dates) {
  fmt_pool <- c("%Y-%m-%d", "%d-%m-%Y", "%d/%m/%Y", "%d.%m.%Y", "%m/%d/%Y")
  fmt <- sample(fmt_pool, 1)
  format(dates, fmt)
}

#' Inject duplicate rows and randomly drop some rows (missing days), per the
#' rates configured in ground_truth.yml$data_quality.
inject_row_gremlins <- function(df, dq) {
  n <- nrow(df)
  n_dup <- rbinom(1, n, dq$duplicate_row_rate)
  if (n_dup > 0) {
    dup_rows <- df[sample(seq_len(n), n_dup, replace = TRUE), ]
    df <- dplyr::bind_rows(df, dup_rows)
  }
  n_drop <- rbinom(1, n, dq$missing_day_rate)
  if (n_drop > 0) {
    drop_idx <- sample(seq_len(nrow(df)), min(n_drop, nrow(df) - 1))
    df <- df[-drop_idx, ]
  }
  df[sample(seq_len(nrow(df))), ] # shuffle row order, like a real export
}

#' Convert a random subset of rows to EUR (dividing by the fixed rate) and
#' tag currency, simulating platforms that report in EUR.
maybe_eur <- function(df, value_cols, dq, share_eur = 0.15) {
  n <- nrow(df)
  is_eur <- runif(n) < share_eur
  df$currency <- ifelse(is_eur, "EUR", "DKK")
  for (col in value_cols) {
    df[[col]] <- ifelse(is_eur, df[[col]] / dq$eur_dkk_fixed_rate, df[[col]])
  }
  df
}

#' Write a tibble to a semicolon-delimited CSV (like a Danish Excel export),
#' with Danish decimal commas applied to comma_cols when use_comma is TRUE.
#' use_comma = FALSE simulates an internationally-formatted platform export
#' (e.g. Google/Meta) that uses plain decimal points despite the DKK values --
#' this is what config$data_quality$decimal_comma_share is modelling: only
#' some raw files use Danish number formatting, not all of them.
write_danish_csv <- function(df, path, comma_cols = NULL, use_comma = TRUE) {
  if (length(comma_cols) > 0) {
    for (col in comma_cols) {
      if (col %in% names(df)) {
        df[[col]] <- if (use_comma) danish_num(df[[col]]) else formatC(df[[col]], format = "f", digits = 2)
      }
    }
  }
  readr::write_delim(df, path, delim = ";", na = "")
}
