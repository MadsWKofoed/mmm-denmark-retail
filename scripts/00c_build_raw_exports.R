# =============================================================================
# 00c_build_raw_exports.R
#
# Turns the TRUE weekly media spend + revenue (data/processed/_truth/) into
# messy, realistic RAW platform exports under data/raw/. This is the ONLY
# place downstream scripts are allowed to read data from (besides
# data/external/). See R/raw_exports.R for the mess-injection helpers.
# =============================================================================

library(tidyverse)
library(here)
library(yaml)
library(writexl)

source(here("R", "transformations.R"))
source(here("R", "raw_exports.R"))

cfg <- read_yaml(here("config", "ground_truth.yml"))
dq <- cfg$data_quality
set.seed(cfg$seed + 100)

truth_wt <- readRDS(here("data", "processed", "_truth", "weekly_truth.rds"))
ms <- readRDS(here("data", "processed", "_truth", "media_spend_truth.rds"))

dir.create(here("data", "raw"), recursive = TRUE, showWarnings = FALSE)

platform_roas <- function(channel) {
  ch_cfg <- cfg$media_channels[[channel]]
  infl <- ch_cfg$platform_reported_roas_inflation
  if (is.null(infl)) ch_cfg$target_short_run_roas * runif(1, 0.95, 1.1) else ch_cfg$target_short_run_roas * infl
}

# -----------------------------------------------------------------------------
# 1. google_ads_daily.csv  (search_brand, search_nonbrand)
# -----------------------------------------------------------------------------
build_google_ads <- function() {
  chans <- c(search_brand = "Brand", search_nonbrand = "NonBrand")
  out <- map_dfr(names(chans), function(ch) {
    daily_spend <- weekly_to_daily(ms$week_start, ms[[ch]], noise_sd = 0.10)
    roas <- platform_roas(ch)
    tibble(
      date = daily_spend$date,
      campaign = messy_campaign_name(ifelse(ch == "search_brand", "Search", "Search"),
                                      chans[ch], daily_spend$date, n = nrow(daily_spend)),
      cost = daily_spend$value,
      klik = round(daily_spend$value / runif(nrow(daily_spend), 4, 9)),
      visninger = round(daily_spend$value / runif(nrow(daily_spend), 0.15, 0.4)),
      konverteringer = pmax(0, round(daily_spend$value * roas / runif(nrow(daily_spend), 550, 750))),
      conv_value = daily_spend$value * roas * exp(rnorm(nrow(daily_spend), 0, 0.15))
    )
  })
  out$date_str <- messy_dates(out$date)
  out <- out |> select(-date)
  out <- maybe_eur(out, c("cost", "conv_value"), dq, share_eur = 0.1)
  out <- inject_row_gremlins(out, dq)
  out <- out |> rename(dato = date_str, kampagne = campaign, omkostning = cost, konv_vaerdi = conv_value)
  write_danish_csv(out, here("data", "raw", "google_ads_daily.csv"),
                    comma_cols = c("omkostning", "konv_vaerdi"))
}

# -----------------------------------------------------------------------------
# 2. meta_ads_daily.csv  (social_prospecting, social_retargeting)
# -----------------------------------------------------------------------------
build_meta_ads <- function() {
  chans <- c(social_prospecting = "Prospecting", social_retargeting = "Retargeting")
  out <- map_dfr(names(chans), function(ch) {
    daily_spend <- weekly_to_daily(ms$week_start, ms[[ch]], noise_sd = 0.12)
    roas <- platform_roas(ch)
    tibble(
      Date = daily_spend$date,
      `Campaign name` = messy_campaign_name("Social", chans[ch], daily_spend$date, n = nrow(daily_spend)),
      `Amount spent (DKK)` = daily_spend$value,
      Impressions = round(daily_spend$value / runif(nrow(daily_spend), 0.05, 0.2)),
      `Link clicks` = round(daily_spend$value / runif(nrow(daily_spend), 3, 8)),
      Purchases = pmax(0, round(daily_spend$value * roas / runif(nrow(daily_spend), 500, 700))),
      `Purchase conversion value` = daily_spend$value * roas * exp(rnorm(nrow(daily_spend), 0, 0.18))
    )
  })
  out$date_str <- messy_dates(out$Date)
  out <- out |> select(-Date)
  out <- maybe_eur(out, c("Amount spent (DKK)", "Purchase conversion value"), dq, share_eur = 0.2)
  out <- inject_row_gremlins(out, dq)
  write_danish_csv(out, here("data", "raw", "meta_ads_daily.csv"),
                    comma_cols = c("Amount spent (DKK)", "Purchase conversion value"))
}

# -----------------------------------------------------------------------------
# 3. programmatic_daily.csv  (programmatic_display, online_video)
# -----------------------------------------------------------------------------
build_programmatic <- function() {
  chans <- c(programmatic_display = "Display", online_video = "Video")
  out <- map_dfr(names(chans), function(ch) {
    daily_spend <- weekly_to_daily(ms$week_start, ms[[ch]], noise_sd = 0.14)
    roas <- platform_roas(ch)
    tibble(
      report_date = daily_spend$date,
      line_item = messy_campaign_name("Prog", chans[ch], daily_spend$date, n = nrow(daily_spend)),
      spend_dkk = daily_spend$value,
      impressions = round(daily_spend$value / runif(nrow(daily_spend), 0.03, 0.09)),
      clicks = round(daily_spend$value / runif(nrow(daily_spend), 8, 20)),
      viewable_rate = round(runif(nrow(daily_spend), 0.55, 0.9), 3),
      attributed_revenue = daily_spend$value * roas * exp(rnorm(nrow(daily_spend), 0, 0.2))
    )
  })
  out$report_date <- messy_dates(out$report_date)
  out <- maybe_eur(out, c("spend_dkk", "attributed_revenue"), dq, share_eur = 0.15)
  out <- inject_row_gremlins(out, dq)
  write_danish_csv(out, here("data", "raw", "programmatic_daily.csv"),
                    comma_cols = c("spend_dkk", "attributed_revenue"))
}

# -----------------------------------------------------------------------------
# 4. tv_spots.csv  (tv_linear) -- spot-level-ish, aggregated to a few
#    "spot batches" per week with GRPs and cost
# -----------------------------------------------------------------------------
build_tv_spots <- function() {
  cpp_dkk <- 4200  # cost per GRP point, roughly
  out <- pmap_dfr(list(ms$week_start, ms$tv_linear), function(ws, spend) {
    if (spend < 1000) return(NULL)
    n_batches <- sample(2:5, 1)
    batch_spend <- spend * (function(w) w / sum(w))(runif(n_batches, 0.5, 1.5))
    tibble(
      uge_start = ws,
      station = sample(c("DR1", "TV2", "TV3", "Kanal5", "DK4"), n_batches, replace = TRUE),
      spot_type = sample(c("30 sek", "20 sek", "15 sek"), n_batches, replace = TRUE),
      grp = round(batch_spend / cpp_dkk * exp(rnorm(n_batches, 0, 0.08)), 1),
      pris_dkk = batch_spend
    )
  })
  out$uge_start <- messy_dates(out$uge_start)
  out <- maybe_eur(out, "pris_dkk", dq, share_eur = 0.05)
  out <- inject_row_gremlins(out, dq)
  write_danish_csv(out, here("data", "raw", "tv_spots.csv"), comma_cols = c("grp", "pris_dkk"))
}

# -----------------------------------------------------------------------------
# 5. ooh_bookings.csv  (ooh) -- booking-level
# -----------------------------------------------------------------------------
build_ooh <- function() {
  out <- pmap_dfr(list(ms$week_start, ms$ooh), function(ws, spend) {
    if (spend < 500) return(NULL)
    n_bookings <- sample(1:3, 1)
    booking_spend <- spend * (function(w) w / sum(w))(runif(n_bookings, 0.5, 1.5))
    tibble(
      booking_start = ws,
      booking_end = ws + 6,
      format = sample(c("Billboard", "Bus shelter", "Citylight", "Storformat"), n_bookings, replace = TRUE),
      by = sample(c("Koebenhavn", "Aarhus", "Odense", "Aalborg", "Landsdaekkende"), n_bookings, replace = TRUE),
      cost_dkk = booking_spend
    )
  })
  out$booking_start <- messy_dates(out$booking_start)
  out$booking_end <- messy_dates(out$booking_end)
  out <- maybe_eur(out, "cost_dkk", dq, share_eur = 0.1)
  out <- inject_row_gremlins(out, dq)
  write_danish_csv(out, here("data", "raw", "ooh_bookings.csv"), comma_cols = "cost_dkk")
}

# -----------------------------------------------------------------------------
# 6. leaflet_costs_weekly.csv  (leaflets / tilbudsavis)
# -----------------------------------------------------------------------------
build_leaflets <- function() {
  out <- tibble(
    uge = ms$week_start,
    oplag = round(ms$leaflets / runif(nrow(ms), 0.35, 0.55)),  # print run size proxy
    distributionsomkostning_dkk = ms$leaflets * runif(nrow(ms), 0.75, 0.9),
    trykomkostning_dkk = ms$leaflets * runif(nrow(ms), 0.1, 0.25)
  )
  out$uge <- messy_dates(out$uge)
  out <- inject_row_gremlins(out, dq)
  write_danish_csv(out, here("data", "raw", "leaflet_costs_weekly.csv"),
                    comma_cols = c("distributionsomkostning_dkk", "trykomkostning_dkk"))
}

# -----------------------------------------------------------------------------
# 7. client_sales_daily.csv  (store + web revenue)
# -----------------------------------------------------------------------------
build_client_sales <- function() {
  weekday_weights <- c(mon = 0.11, tue = 0.12, wed = 0.13, thu = 0.14, fri = 0.16, sat = 0.22, sun = 0.12)
  out <- pmap_dfr(list(truth_wt$week_start, truth_wt$revenue_dkk), function(ws, wv) {
    days <- ws + 0:6
    w <- as.numeric(weekday_weights) * exp(rnorm(7, 0, 0.05))
    w <- w / sum(w)
    daily_total <- wv * w
    web_share <- pmin(0.4, pmax(0.12, 0.22 + rnorm(7, 0, 0.03)))
    tibble(
      dato = days,
      butiksomsaetning_dkk = daily_total * (1 - web_share),
      webshop_omsaetning_dkk = daily_total * web_share
    )
  })
  out$dato <- messy_dates(out$dato)
  out <- inject_row_gremlins(out, dq)
  write_danish_csv(out, here("data", "raw", "client_sales_daily.csv"),
                    comma_cols = c("butiksomsaetning_dkk", "webshop_omsaetning_dkk"))
}

# -----------------------------------------------------------------------------
# 8. promo_calendar.xlsx
# -----------------------------------------------------------------------------
build_promo_calendar <- function() {
  promo <- truth_wt |>
    select(week_start, promo_depth_index) |>
    mutate(is_promo = promo_depth_index > quantile(promo_depth_index, 0.6)) |>
    filter(is_promo) |>
    mutate(
      kampagne_navn = paste0("Kampagne_", format(week_start, "%Y_uge%V")),
      start = week_start,
      slut = week_start + 6,
      dybde_pct = round(promo_depth_index * 100, 0)
    ) |>
    select(kampagne_navn, start, slut, dybde_pct)
  write_xlsx(promo, here("data", "raw", "promo_calendar.xlsx"))
}

log <- function(...) cat(sprintf("[%s] ", format(Sys.time(), "%H:%M:%S")), sprintf(...), "\n")

log("Building google_ads_daily.csv..."); build_google_ads()
log("Building meta_ads_daily.csv..."); build_meta_ads()
log("Building programmatic_daily.csv..."); build_programmatic()
log("Building tv_spots.csv..."); build_tv_spots()
log("Building ooh_bookings.csv..."); build_ooh()
log("Building leaflet_costs_weekly.csv..."); build_leaflets()
log("Building client_sales_daily.csv..."); build_client_sales()
log("Building promo_calendar.xlsx..."); build_promo_calendar()

file.copy(here("config", "taxonomy_map.csv"), here("data", "raw", "taxonomy_map.csv"), overwrite = TRUE)

log("Done. Raw exports written to data/raw/")
walk(list.files(here("data", "raw")), ~ log("  %s (%s KB)", .x,
     round(file.size(here("data", "raw", .x)) / 1024, 1)))
