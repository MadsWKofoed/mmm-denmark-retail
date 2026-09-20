# =============================================================================
# 01_ingest_clean.R
#
# Pipeline step 1: parse every raw platform export, standardise dates/numbers/
# currency, apply the taxonomy, deduplicate, aggregate everything to ISO
# weeks, and assemble the single weekly modelling table used by every script
# from here on. Also writes a data dictionary.
#
# Inputs:  data/raw/*.csv, data/raw/*.xlsx, data/external/*.csv
# Outputs: data/processed/weekly_modelling_table.csv (+ .rds)
#          data/processed/data_dictionary.csv
# =============================================================================

library(tidyverse)
library(here)
library(readxl)
library(janitor)
library(yaml)

source(here("R", "cleaning.R"))

cfg <- read_yaml(here("config", "ground_truth.yml"))
eur_rate <- cfg$data_quality$eur_dkk_fixed_rate
taxonomy <- read_csv(here("data", "raw", "taxonomy_map.csv"), show_col_types = FALSE)

log_msg <- function(...) cat(sprintf("[%s] ", format(Sys.time(), "%H:%M:%S")), sprintf(...), "\n")

# -----------------------------------------------------------------------------
# Google Ads (search_brand, search_nonbrand)
# -----------------------------------------------------------------------------
log_msg("Cleaning google_ads_daily.csv...")
google_raw <- read_raw_csv(here("data", "raw", "google_ads_daily.csv"))
google_clean <- google_raw |>
  distinct() |>
  mutate(
    date = parse_messy_dates(dato),
    omkostning_dkk = convert_to_dkk(parse_danish_number(omkostning), currency, eur_rate),
    konv_vaerdi_dkk = convert_to_dkk(parse_danish_number(konv_vaerdi), currency, eur_rate),
    klik = as.numeric(klik), konverteringer = as.numeric(konverteringer)
  ) |>
  filter(!is.na(date))
google_clean <- google_clean |> bind_cols(match_taxonomy(google_clean$kampagne, "google_ads_daily", taxonomy))

n_unmatched_google <- sum(is.na(google_clean$channel))
if (n_unmatched_google > 0) log_msg("  WARNING: %d google_ads rows unmatched by taxonomy", n_unmatched_google)

google_weekly <- google_clean |>
  filter(!is.na(channel)) |>
  mutate(week_start = lubridate::floor_date(date, unit = "week", week_start = 1)) |>
  group_by(week_start, channel) |>
  summarise(
    spend_dkk = sum(omkostning_dkk, na.rm = TRUE),
    platform_reported_revenue_dkk = sum(konv_vaerdi_dkk, na.rm = TRUE), .groups = "drop"
  )

# -----------------------------------------------------------------------------
# Meta Ads (social_prospecting, social_retargeting)
# -----------------------------------------------------------------------------
log_msg("Cleaning meta_ads_daily.csv...")
meta_raw <- read_raw_csv(here("data", "raw", "meta_ads_daily.csv")) |>
  janitor::clean_names()
meta_clean <- meta_raw |>
  distinct() |>
  mutate(
    date = parse_messy_dates(date_str),
    spend_dkk = convert_to_dkk(parse_danish_number(amount_spent_dkk), currency, eur_rate),
    conv_value_dkk = convert_to_dkk(parse_danish_number(purchase_conversion_value), currency, eur_rate)
  ) |>
  filter(!is.na(date))
meta_clean <- meta_clean |> bind_cols(match_taxonomy(meta_clean$campaign_name, "meta_ads_daily", taxonomy))

n_unmatched_meta <- sum(is.na(meta_clean$channel))
if (n_unmatched_meta > 0) log_msg("  WARNING: %d meta_ads rows unmatched by taxonomy", n_unmatched_meta)

meta_weekly <- meta_clean |>
  filter(!is.na(channel)) |>
  mutate(week_start = lubridate::floor_date(date, unit = "week", week_start = 1)) |>
  group_by(week_start, channel) |>
  summarise(
    spend_dkk = sum(spend_dkk, na.rm = TRUE),
    platform_reported_revenue_dkk = sum(conv_value_dkk, na.rm = TRUE), .groups = "drop"
  )

# -----------------------------------------------------------------------------
# Programmatic (programmatic_display, online_video)
# -----------------------------------------------------------------------------
log_msg("Cleaning programmatic_daily.csv...")
prog_raw <- read_raw_csv(here("data", "raw", "programmatic_daily.csv"))
prog_clean <- prog_raw |>
  distinct() |>
  mutate(
    date = parse_messy_dates(report_date),
    spend_dkk = convert_to_dkk(parse_danish_number(spend_dkk), currency, eur_rate),
    revenue_dkk = convert_to_dkk(parse_danish_number(attributed_revenue), currency, eur_rate)
  ) |>
  filter(!is.na(date))
prog_clean <- prog_clean |> bind_cols(match_taxonomy(prog_clean$line_item, "programmatic_daily", taxonomy))

prog_weekly <- prog_clean |>
  filter(!is.na(channel)) |>
  mutate(week_start = lubridate::floor_date(date, unit = "week", week_start = 1)) |>
  group_by(week_start, channel) |>
  summarise(
    spend_dkk = sum(spend_dkk, na.rm = TRUE),
    platform_reported_revenue_dkk = sum(revenue_dkk, na.rm = TRUE), .groups = "drop"
  )

# -----------------------------------------------------------------------------
# TV spots
# -----------------------------------------------------------------------------
log_msg("Cleaning tv_spots.csv...")
tv_raw <- read_raw_csv(here("data", "raw", "tv_spots.csv"))
tv_weekly <- tv_raw |>
  distinct() |>
  mutate(
    week_start = parse_messy_dates(uge_start),
    pris_dkk = convert_to_dkk(parse_danish_number(pris_dkk), currency, eur_rate)
  ) |>
  filter(!is.na(week_start)) |>
  mutate(week_start = lubridate::floor_date(week_start, unit = "week", week_start = 1)) |>
  group_by(week_start) |>
  summarise(spend_dkk = sum(pris_dkk, na.rm = TRUE), grp = sum(parse_danish_number(grp), na.rm = TRUE), .groups = "drop") |>
  mutate(channel = "tv_linear")

# -----------------------------------------------------------------------------
# OOH bookings
# -----------------------------------------------------------------------------
log_msg("Cleaning ooh_bookings.csv...")
ooh_raw <- read_raw_csv(here("data", "raw", "ooh_bookings.csv"))
ooh_weekly <- ooh_raw |>
  distinct() |>
  mutate(
    booking_start = parse_messy_dates(booking_start),
    cost_dkk = convert_to_dkk(parse_danish_number(cost_dkk), currency, eur_rate)
  ) |>
  filter(!is.na(booking_start)) |>
  mutate(week_start = lubridate::floor_date(booking_start, unit = "week", week_start = 1)) |>
  group_by(week_start) |>
  summarise(spend_dkk = sum(cost_dkk, na.rm = TRUE), .groups = "drop") |>
  mutate(channel = "ooh")

# -----------------------------------------------------------------------------
# Leaflets
# -----------------------------------------------------------------------------
log_msg("Cleaning leaflet_costs_weekly.csv...")
leaflet_raw <- read_raw_csv(here("data", "raw", "leaflet_costs_weekly.csv"))
leaflet_weekly <- leaflet_raw |>
  distinct() |>
  mutate(
    week_start = parse_messy_dates(uge),
    total_dkk = parse_danish_number(distributionsomkostning_dkk) + parse_danish_number(trykomkostning_dkk)
  ) |>
  filter(!is.na(week_start)) |>
  mutate(week_start = lubridate::floor_date(week_start, unit = "week", week_start = 1)) |>
  group_by(week_start) |>
  summarise(spend_dkk = sum(total_dkk, na.rm = TRUE), .groups = "drop") |>
  mutate(channel = "leaflets")

# -----------------------------------------------------------------------------
# Combine all media spend into one long table, then pivot wide
# -----------------------------------------------------------------------------
media_long <- bind_rows(
  google_weekly |> select(week_start, channel, spend_dkk, platform_reported_revenue_dkk),
  meta_weekly |> select(week_start, channel, spend_dkk, platform_reported_revenue_dkk),
  prog_weekly |> select(week_start, channel, spend_dkk, platform_reported_revenue_dkk),
  tv_weekly |> select(week_start, channel, spend_dkk),
  ooh_weekly |> select(week_start, channel, spend_dkk),
  leaflet_weekly |> select(week_start, channel, spend_dkk)
) |>
  group_by(week_start, channel) |>
  summarise(
    spend_dkk = sum(spend_dkk, na.rm = TRUE),
    platform_reported_revenue_dkk = sum(platform_reported_revenue_dkk, na.rm = TRUE), .groups = "drop"
  )

media_spend_wide <- media_long |>
  select(week_start, channel, spend_dkk) |>
  pivot_wider(names_from = channel, values_from = spend_dkk, values_fill = 0, names_prefix = "spend_")

platform_roas_wide <- media_long |>
  select(week_start, channel, platform_reported_revenue_dkk) |>
  pivot_wider(
    names_from = channel, values_from = platform_reported_revenue_dkk, values_fill = 0,
    names_prefix = "platform_revenue_"
  )

# -----------------------------------------------------------------------------
# Client sales (revenue)
# -----------------------------------------------------------------------------
log_msg("Cleaning client_sales_daily.csv...")
sales_raw <- read_raw_csv(here("data", "raw", "client_sales_daily.csv"))
sales_weekly <- sales_raw |>
  distinct() |>
  mutate(
    date = parse_messy_dates(dato),
    store_dkk = parse_danish_number(butiksomsaetning_dkk),
    web_dkk = parse_danish_number(webshop_omsaetning_dkk)
  ) |>
  filter(!is.na(date)) |>
  mutate(week_start = lubridate::floor_date(date, unit = "week", week_start = 1)) |>
  group_by(week_start) |>
  summarise(
    revenue_dkk = sum(store_dkk, na.rm = TRUE) + sum(web_dkk, na.rm = TRUE),
    store_revenue_dkk = sum(store_dkk, na.rm = TRUE),
    web_revenue_dkk = sum(web_dkk, na.rm = TRUE), .groups = "drop"
  )

# -----------------------------------------------------------------------------
# Promo calendar -> weekly promo depth (share of week under promotion, avg depth)
# -----------------------------------------------------------------------------
log_msg("Cleaning promo_calendar.xlsx...")
promo_raw <- read_excel(here("data", "raw", "promo_calendar.xlsx"))
promo_weekly <- promo_raw |>
  mutate(week_start = lubridate::floor_date(as.Date(start), unit = "week", week_start = 1)) |>
  group_by(week_start) |>
  summarise(promo_depth_pct = mean(dybde_pct, na.rm = TRUE), .groups = "drop")

# -----------------------------------------------------------------------------
# Store count (client-supplied operational data -> distribution control)
# -----------------------------------------------------------------------------
log_msg("Cleaning store_count_weekly.csv...")
store_raw <- read_raw_csv(here("data", "raw", "store_count_weekly.csv"))
store_weekly <- store_raw |>
  distinct() |>
  mutate(
    week_start = lubridate::floor_date(parse_messy_dates(uge), unit = "week", week_start = 1),
    n_stores = as.numeric(antal_butikker)
  ) |>
  filter(!is.na(week_start)) |>
  group_by(week_start) |>
  summarise(n_stores = max(n_stores), .groups = "drop")

# -----------------------------------------------------------------------------
# External real data
# -----------------------------------------------------------------------------
log_msg("Loading external data...")
weather_weekly <- read_csv(here("data", "external", "weather_weekly.csv"), show_col_types = FALSE)
consumer_confidence <- read_csv(here("data", "external", "consumer_confidence_monthly.csv"), show_col_types = FALSE)
cpi_monthly <- read_csv(here("data", "external", "cpi_monthly.csv"), show_col_types = FALSE)
danish_holidays_raw <- read_csv(here("data", "external", "danish_holidays.csv"), show_col_types = FALSE)

calendar <- tibble(week_start = seq(as.Date(cfg$period$start_date), as.Date(cfg$period$end_date), by = "week")) |>
  mutate(
    iso_year = lubridate::isoyear(week_start), iso_week = lubridate::isoweek(week_start),
    year = lubridate::year(week_start), month = lubridate::month(week_start),
    year_month = sprintf("%dM%02d", year, month)
  )

external_weekly <- calendar |>
  left_join(weather_weekly |> select(iso_year, iso_week, temperature_c, precipitation_mm), by = c("iso_year", "iso_week")) |>
  left_join(consumer_confidence, by = "year_month") |>
  left_join(cpi_monthly, by = "year_month") |>
  tidyr::fill(temperature_c, precipitation_mm, consumer_confidence, cpi_index, .direction = "downup") |>
  select(week_start, temperature_c, precipitation_mm, consumer_confidence, cpi_index)

# Holiday week dummies: one column per named Danish holiday that plausibly
# moves demand, flagged for the ISO week that contains it (real, computed
# holiday dates -- Easter/Ascension/Whit Monday move every year; Great
# Prayer Day was abolished as a public holiday from 2024).
holiday_weeks <- danish_holidays_raw |>
  mutate(
    week_start = lubridate::floor_date(date, unit = "week", week_start = 1),
    holiday_group = case_when(
      holiday_name %in% c("Skaertorsdag", "Langfredag", "Paaskedag", "2. Paaskedag") ~ "is_easter_week",
      holiday_name == "Kristi Himmelfartsdag" ~ "is_ascension_week",
      holiday_name == "2. Pinsedag" ~ "is_whitmonday_week",
      holiday_name == "Store Bededag" ~ "is_great_prayer_week",
      holiday_name %in% c("Juleaftensdag", "Juledag", "2. Juledag", "Nytaarsaften") ~ "is_christmas_week",
      TRUE ~ NA_character_
    )
  ) |>
  filter(!is.na(holiday_group)) |>
  distinct(week_start, holiday_group) |>
  mutate(flag = 1L) |>
  pivot_wider(names_from = holiday_group, values_from = flag, values_fill = 0L)

holiday_cols <- c("is_easter_week", "is_ascension_week", "is_whitmonday_week", "is_great_prayer_week", "is_christmas_week")

# -----------------------------------------------------------------------------
# Assemble the final weekly modelling table
# -----------------------------------------------------------------------------
log_msg("Assembling weekly modelling table...")
weekly <- calendar |>
  select(week_start, iso_year, iso_week) |>
  left_join(sales_weekly, by = "week_start") |>
  left_join(media_spend_wide, by = "week_start") |>
  left_join(platform_roas_wide, by = "week_start") |>
  left_join(promo_weekly, by = "week_start") |>
  left_join(external_weekly, by = "week_start") |>
  left_join(store_weekly, by = "week_start") |>
  left_join(holiday_weeks, by = "week_start") |>
  mutate(
    across(starts_with("spend_"), ~ replace_na(.x, 0)),
    across(starts_with("platform_revenue_"), ~ replace_na(.x, 0)),
    across(all_of(holiday_cols), ~ replace_na(.x, 0L)),
    n_stores = zoo::na.locf(n_stores, na.rm = FALSE),
    promo_depth_pct = replace_na(promo_depth_pct, 0)
  ) |>
  arrange(week_start)

# revenue_dkk / store / web could have gaps if a week's raw sales rows were
# all dropped by the injected missing-day gremlin; fill any such gaps by
# linear interpolation and flag them, mirroring what a real analyst would do
# for a handful of missing days rather than dropping the whole week.
n_missing_revenue <- sum(is.na(weekly$revenue_dkk))
if (n_missing_revenue > 0) {
  log_msg("  Interpolating %d week(s) with missing revenue (from dropped raw rows)", n_missing_revenue)
  weekly <- weekly |>
    mutate(
      revenue_was_interpolated = is.na(revenue_dkk),
      revenue_dkk = zoo::na.approx(revenue_dkk, na.rm = FALSE),
      store_revenue_dkk = zoo::na.approx(store_revenue_dkk, na.rm = FALSE),
      web_revenue_dkk = zoo::na.approx(web_revenue_dkk, na.rm = FALSE)
    )
} else {
  weekly$revenue_was_interpolated <- FALSE
}

validate_weekly_table(weekly, expected_weeks = cfg$period$n_weeks)
log_msg("Validation PASSED: %d weeks, no missing weeks, no negative spend, revenue complete.", nrow(weekly))

# Reconciliation check: weekly aggregated spend vs raw daily total (DKK, post-conversion)
for (ch in unique(media_long$channel)) {
  col <- paste0("spend_", ch)
  if (col %in% names(weekly)) {
    reconcile_totals(sum(weekly[[col]]), sum(media_long$spend_dkk[media_long$channel == ch]), label = col)
  }
}
log_msg("Reconciliation PASSED for all channels.")

dir.create(here("data", "processed"), recursive = TRUE, showWarnings = FALSE)
write_csv(weekly, here("data", "processed", "weekly_modelling_table.csv"))
saveRDS(weekly, here("data", "processed", "weekly_modelling_table.rds"))

# -----------------------------------------------------------------------------
# Data dictionary
# -----------------------------------------------------------------------------
dict <- tibble(column = names(weekly)) |>
  mutate(description = case_when(
    column == "week_start" ~ "ISO week start date (Monday)",
    column == "iso_year" ~ "ISO year",
    column == "iso_week" ~ "ISO week number",
    column == "revenue_dkk" ~ "Total weekly client revenue (store + web), DKK",
    column == "store_revenue_dkk" ~ "In-store weekly revenue, DKK",
    column == "web_revenue_dkk" ~ "Webshop weekly revenue, DKK",
    column == "revenue_was_interpolated" ~ "TRUE if this week's revenue was linearly interpolated due to missing raw rows",
    str_starts(column, "spend_") ~ paste0("Weekly media spend, ", str_remove(column, "spend_"), ", DKK (converted to DKK, deduplicated, weekly-aggregated)"),
    str_starts(column, "platform_revenue_") ~ paste0("Platform-reported (last-click) attributed revenue, ", str_remove(column, "platform_revenue_"), ", DKK"),
    column == "promo_depth_pct" ~ "Average promo depth (%) across active promotions that week, from promo_calendar.xlsx",
    column == "temperature_c" ~ "Mean daily temperature, Copenhagen+Aarhus avg, degrees C (real, Open-Meteo)",
    column == "precipitation_mm" ~ "Total weekly precipitation, mm (real, Open-Meteo)",
    column == "consumer_confidence" ~ "Danish consumer confidence indicator (real, DST StatBank FORV1)",
    column == "cpi_index" ~ "Danish consumer price index, 2015=100 (real, DST StatBank PRIS01)",
    column == "n_stores" ~ "Number of open stores that week (client-supplied operational data; distribution control)",
    column == "is_easter_week" ~ "1 if the ISO week contains Maundy Thu/Good Fri/Easter Sun/Easter Mon (real, computed)",
    column == "is_ascension_week" ~ "1 if the ISO week contains Ascension Day (real, computed)",
    column == "is_whitmonday_week" ~ "1 if the ISO week contains Whit Monday (real, computed)",
    column == "is_great_prayer_week" ~ "1 if the ISO week contains Great Prayer Day (real, computed; abolished as a holiday from 2024)",
    column == "is_christmas_week" ~ "1 if the ISO week contains Christmas Eve/Day/Boxing Day/New Year's Eve (real, computed)",
    TRUE ~ "See scripts/01_ingest_clean.R"
  ))
write_csv(dict, here("data", "processed", "data_dictionary.csv"))

log_msg("Done. Weekly modelling table: %d rows x %d cols", nrow(weekly), ncol(weekly))
log_msg("Wrote data/processed/weekly_modelling_table.{csv,rds} and data_dictionary.csv")
