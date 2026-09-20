# =============================================================================
# 00a_fetch_external_data.R
#
# Fetches REAL public external data and caches it in data/external/, with the
# fetch date recorded. This is the only "real" data in the project -- see
# README for what is real vs simulated.
#
#   1. Weather: Open-Meteo historical archive API, Copenhagen + Aarhus daily
#      mean temperature and precipitation, aggregated to weekly.
#   2. Consumer confidence: Statistics Denmark StatBank, table FORV1
#      (Forbrugertillidsindikatoren / Consumer confidence indicator), monthly.
#   3. CPI: Statistics Denmark StatBank, table PRIS01 (Consumer price index).
#      NOTE: the brief suggested PRIS111, but that table was verified via the
#      StatBank API (tableinfo endpoint) to be inactive/discontinued
#      (replaced by PRIS01 in Feb 2020, same underlying series structure with
#      an updated commodity classification). PRIS01 is used instead.
#   4. Danish public holidays: computed locally (R/danish_calendar.R), not an
#      API, but included here for a single "build the calendar" step.
#
# Each fetch is retried up to 2 times; if it still fails, a documented
# simulated fallback is used instead (and clearly flagged in the metadata
# file and README) so the rest of the pipeline never breaks on network
# issues.
# =============================================================================

library(tidyverse)
library(here)
library(jsonlite)
library(httr2)

source(here("R", "danish_calendar.R"))

dir.create(here("data", "external"), recursive = TRUE, showWarnings = FALSE)

cfg <- yaml::read_yaml(here("config", "ground_truth.yml"))
start_date <- as.Date(cfg$period$start_date)
end_date <- as.Date(cfg$period$end_date)
fetch_date <- Sys.Date()

log_msg <- function(...) cat(sprintf("[%s] ", format(Sys.time(), "%H:%M:%S")), sprintf(...), "\n")

with_retries <- function(fn, tries = 2, label = "request") {
  last_err <- NULL
  for (i in seq_len(tries)) {
    result <- tryCatch(list(ok = TRUE, value = fn()), error = function(e) {
      last_err <<- conditionMessage(e)
      list(ok = FALSE, value = NULL)
    })
    if (result$ok) {
      return(result$value)
    }
    log_msg("  attempt %d/%d for %s failed: %s", i, tries, label, last_err)
  }
  log_msg("  %s: all %d attempts failed, falling back to simulated data.", label, tries)
  NULL
}

# -----------------------------------------------------------------------------
# 1. Weather (Open-Meteo)
# -----------------------------------------------------------------------------
fetch_weather_city <- function(lat, lon, city) {
  req <- request("https://archive-api.open-meteo.com/v1/archive") |>
    req_url_query(
      latitude = lat, longitude = lon,
      start_date = as.character(start_date), end_date = as.character(end_date),
      daily = "temperature_2m_mean,precipitation_sum",
      timezone = "Europe/Copenhagen"
    ) |>
    req_timeout(30)
  resp <- req_perform(req)
  body <- resp_body_json(resp)
  tibble(
    date = as.Date(unlist(body$daily$time)),
    temperature_c = as.numeric(unlist(body$daily$temperature_2m_mean)),
    precipitation_mm = as.numeric(unlist(body$daily$precipitation_sum)),
    city = city
  )
}

log_msg("Fetching weather: Copenhagen + Aarhus (Open-Meteo archive API)...")
weather_cph <- with_retries(function() fetch_weather_city(55.6761, 12.5683, "Copenhagen"), label = "weather Copenhagen")
weather_aar <- with_retries(function() fetch_weather_city(56.1629, 10.2039, "Aarhus"), label = "weather Aarhus")

weather_is_real <- !is.null(weather_cph) && !is.null(weather_aar)

if (weather_is_real) {
  weather_daily <- bind_rows(weather_cph, weather_aar)
} else {
  log_msg("Using SIMULATED weather fallback.")
  set.seed(cfg$seed)
  all_days <- seq(start_date, end_date, by = "day")
  doy <- as.numeric(format(all_days, "%j"))
  seasonal_temp <- 8.5 + 8 * sin(2 * pi * (doy - 100) / 365)
  weather_daily <- bind_rows(
    tibble(
      date = all_days, temperature_c = seasonal_temp + rnorm(length(all_days), 0, 3),
      precipitation_mm = pmax(0, rgamma(length(all_days), shape = 0.9, scale = 2.2)), city = "Copenhagen"
    ),
    tibble(
      date = all_days, temperature_c = seasonal_temp - 0.4 + rnorm(length(all_days), 0, 3),
      precipitation_mm = pmax(0, rgamma(length(all_days), shape = 0.9, scale = 2.4)), city = "Aarhus"
    )
  )
}

weather_weekly <- weather_daily |>
  mutate(iso_year = lubridate::isoyear(date), iso_week = lubridate::isoweek(date)) |>
  group_by(iso_year, iso_week) |>
  summarise(
    temperature_c = mean(temperature_c, na.rm = TRUE),
    precipitation_mm = sum(precipitation_mm, na.rm = TRUE) / n_distinct(city),
    week_start = min(date[lubridate::wday(date, week_start = 1) == 1]),
    .groups = "drop"
  ) |>
  arrange(iso_year, iso_week)

write_csv(weather_weekly, here("data", "external", "weather_weekly.csv"))

# -----------------------------------------------------------------------------
# 2 & 3. Statistics Denmark StatBank: consumer confidence (FORV1), CPI (PRIS01)
# -----------------------------------------------------------------------------
month_seq <- function(from, to) {
  ym <- seq(as.Date(format(from, "%Y-%m-01")), as.Date(format(to, "%Y-%m-01")), by = "month")
  sprintf("%dM%02d", lubridate::year(ym), lubridate::month(ym))
}
months <- month_seq(start_date, end_date)

statbank_query <- function(table, variables) {
  req <- request("https://api.statbank.dk/v1/data") |>
    req_headers(`Content-Type` = "application/json") |>
    req_body_json(list(table = table, format = "CSV", variables = variables)) |>
    req_timeout(30)
  resp <- req_perform(req)
  raw_txt <- resp_body_string(resp, encoding = "UTF-8")
  raw_txt <- sub("^﻿", "", raw_txt) # strip BOM
  readr::read_delim(I(raw_txt), delim = ";", locale = readr::locale(decimal_mark = ","), show_col_types = FALSE)
}

log_msg("Fetching consumer confidence (StatBank FORV1)...")
confidence_raw <- with_retries(
  function() statbank_query("FORV1", list(list(code = "INDIKATOR", values = list("F1")), list(code = "Tid", values = as.list(months)))),
  label = "StatBank FORV1"
)
confidence_is_real <- !is.null(confidence_raw)

if (confidence_is_real) {
  consumer_confidence <- confidence_raw |>
    transmute(year_month = TID, consumer_confidence = INDHOLD)
} else {
  log_msg("Using SIMULATED consumer confidence fallback.")
  set.seed(cfg$seed + 1)
  consumer_confidence <- tibble(year_month = months, consumer_confidence = as.numeric(arima.sim(list(ar = 0.8), n = length(months))) * 5)
}
write_csv(consumer_confidence, here("data", "external", "consumer_confidence_monthly.csv"))

log_msg("Fetching CPI (StatBank PRIS01)...")
cpi_raw <- with_retries(
  function() statbank_query("PRIS01", list(list(code = "VAREGR", values = list("000000")), list(code = "ENHED", values = list("100")), list(code = "Tid", values = as.list(months)))),
  label = "StatBank PRIS01"
)
cpi_is_real <- !is.null(cpi_raw)

if (cpi_is_real) {
  cpi_monthly <- cpi_raw |> transmute(year_month = TID, cpi_index = INDHOLD)
} else {
  log_msg("Using SIMULATED CPI fallback.")
  set.seed(cfg$seed + 2)
  cpi_monthly <- tibble(year_month = months, cpi_index = 100 * cumprod(1 + rnorm(length(months), 0.003, 0.001)))
}
write_csv(cpi_monthly, here("data", "external", "cpi_monthly.csv"))

# -----------------------------------------------------------------------------
# 4. Danish public holidays (computed)
# -----------------------------------------------------------------------------
log_msg("Computing Danish public holidays %d-%d...", lubridate::year(start_date), lubridate::year(end_date))
holidays <- danish_holidays(lubridate::year(start_date):lubridate::year(end_date))
write_csv(holidays, here("data", "external", "danish_holidays.csv"))

# -----------------------------------------------------------------------------
# Metadata: what's real, what's fallback, when it was fetched
# -----------------------------------------------------------------------------
metadata <- list(
  fetch_date = as.character(fetch_date),
  sources = list(
    weather = list(
      source = "Open-Meteo archive API", is_real = weather_is_real,
      url = "https://archive-api.open-meteo.com/v1/archive"
    ),
    consumer_confidence = list(
      source = "Statistics Denmark StatBank, table FORV1", is_real = confidence_is_real,
      url = "https://api.statbank.dk/v1/data"
    ),
    cpi = list(
      source = "Statistics Denmark StatBank, table PRIS01 (PRIS111 verified discontinued/inactive; PRIS01 is its active successor)",
      is_real = cpi_is_real, url = "https://api.statbank.dk/v1/data"
    ),
    holidays = list(source = "Computed locally (Gregorian Easter algorithm + fixed DK holiday calendar)", is_real = TRUE)
  )
)
write_json(metadata, here("data", "external", "_fetch_metadata.json"), auto_unbox = TRUE, pretty = TRUE)

log_msg("Done. weather_is_real=%s confidence_is_real=%s cpi_is_real=%s", weather_is_real, confidence_is_real, cpi_is_real)
log_msg("Wrote: weather_weekly.csv, consumer_confidence_monthly.csv, cpi_monthly.csv, danish_holidays.csv, _fetch_metadata.json")
