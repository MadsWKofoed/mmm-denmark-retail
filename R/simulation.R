# =============================================================================
# R/simulation.R
#
# Core data-generating process for the fictional client "Havehjornet". Builds
# the TRUE weekly revenue and media series from config/ground_truth.yml plus
# real external data (weather, consumer confidence, CPI). This is the answer
# key: scripts/05b_recovery_study.R is the only modelling script allowed to
# read it. Everything else works only from the messy raw exports built on top
# of this in R/raw_exports.R.
# =============================================================================

#' Build the weekly calendar skeleton (ISO weeks) for the simulation period.
build_weekly_calendar <- function(cfg) {
  starts <- seq(as.Date(cfg$period$start_date), as.Date(cfg$period$end_date), by = "week")
  tibble::tibble(
    week_start = starts,
    iso_year = lubridate::isoyear(starts),
    iso_week = lubridate::isoweek(starts),
    week_index = seq_along(starts),
    month = lubridate::month(starts),
    year = lubridate::year(starts)
  )
}

#' Attach real external weekly drivers (weather, confidence, CPI) to the
#' calendar, joining monthly StatBank series onto weeks by year-month.
attach_external_drivers <- function(calendar, weather_weekly, consumer_confidence, cpi_monthly) {
  weather_weekly <- weather_weekly |> dplyr::select(iso_year, iso_week, temperature_c, precipitation_mm)
  calendar |>
    dplyr::left_join(weather_weekly, by = c("iso_year", "iso_week")) |>
    dplyr::mutate(year_month = sprintf("%dM%02d", year, month)) |>
    dplyr::left_join(consumer_confidence, by = "year_month") |>
    dplyr::left_join(cpi_monthly, by = "year_month") |>
    tidyr::fill(temperature_c, precipitation_mm, consumer_confidence, cpi_index, .direction = "downup")
}

#' Simulate the non-media, non-external drivers: trend, seasonality index,
#' price index, promo depth, competitor pressure, distribution/store effect.
simulate_non_media_drivers <- function(calendar, cfg, holidays) {
  set.seed(cfg$seed)
  n <- nrow(calendar)
  nm <- cfg$non_media_drivers
  rv <- cfg$revenue

  # Fourier seasonality
  t <- calendar$week_index
  period <- 52.18
  fourier <- matrix(0, n, rv$seasonality$fourier_terms * 2)
  for (k in seq_len(rv$seasonality$fourier_terms)) {
    fourier[, 2 * k - 1] <- sin(2 * pi * k * t / period)
    fourier[, 2 * k] <- cos(2 * pi * k * t / period)
  }
  fourier_coefs <- rv$seasonality$fourier_amplitude * rnorm(ncol(fourier), 0, 1) / seq_len(ncol(fourier))
  fourier_index <- as.numeric(fourier %*% fourier_coefs)

  garden_peak <- as.integer(calendar$month %in% rv$seasonality$garden_peak_months)
  black_friday <- as.integer(calendar$month == 11 & calendar$iso_week %in% c(47, 48))
  christmas <- as.integer(calendar$iso_week %in% c(50, 51))
  january_trough <- as.integer(calendar$month == 1 & calendar$iso_week <= 3)

  seasonal_multiplier <- exp(fourier_index) *
    (1 + (rv$seasonality$garden_peak_multiplier - 1) * garden_peak) *
    (1 + (rv$seasonality$black_friday_week_multiplier - 1) * black_friday) *
    (1 + (rv$seasonality$christmas_weeks_multiplier - 1) * christmas) *
    (1 - (1 - rv$seasonality$january_trough_multiplier) * january_trough)

  # Holiday bumps: map named holidays to weeks that contain them
  holiday_week_mult <- rep(1, n)
  hol_map <- list(
    easter = "Paaskedag", ascension_day = "Kristi Himmelfartsdag",
    whit_monday = "2. Pinsedag", great_prayer_day = "Store Bededag",
    christmas_eve_week = "Juleaftensdag"
  )
  for (nm_key in names(hol_map)) {
    hdates <- holidays$date[holidays$holiday_name == hol_map[[nm_key]]]
    if (length(hdates) == 0) next
    hyears <- lubridate::isoyear(hdates); hweeks <- lubridate::isoweek(hdates)
    idx <- which(calendar$iso_year %in% hyears & calendar$iso_week %in% hweeks &
                   paste(calendar$iso_year, calendar$iso_week) %in% paste(hyears, hweeks))
    holiday_week_mult[idx] <- holiday_week_mult[idx] * rv$holiday_effects[[nm_key]]
  }

  # Trend
  years_elapsed <- t / 52.18
  trend_index <- (1 + rv$trend_annual_growth)^years_elapsed

  # Price index (mean-reverting AR1 around 100, slow drift)
  price_index <- 100 + as.numeric(arima.sim(list(ar = 0.9), n = n, sd = nm$price_index$sd * 0.35))

  # Promotions: 0-1 depth, higher during Black Friday / Christmas / garden peak starts, plus random promos
  promo_base <- 0.15 + 0.5 * black_friday + 0.35 * christmas + 0.15 * as.integer(calendar$month == 4)
  promo_depth_index <- pmin(1, pmax(0, promo_base + rnorm(n, 0, 0.08)))

  # Competitor pressure (AR1, mean 100)
  competitor_pressure_index <- 100 + as.numeric(arima.sim(list(ar = 0.85), n = n, sd = nm$competitor_pressure_index$sd * 0.4))

  # Distribution / new-store effect: ramps in from start_date over ramp_weeks
  dist_start_idx <- which(calendar$week_start == as.Date(rv$distribution_effect$start_date))[1]
  distribution_ramp <- numeric(n)
  if (!is.na(dist_start_idx)) {
    ramp_len <- rv$distribution_effect$ramp_weeks
    for (i in seq_len(n)) {
      if (i >= dist_start_idx) {
        weeks_since <- i - dist_start_idx + 1
        distribution_ramp[i] <- rv$distribution_effect$revenue_uplift_at_full_ramp * pmin(1, weeks_since / ramp_len)
      }
    }
  }

  tibble::tibble(
    week_start = calendar$week_start,
    seasonal_multiplier = seasonal_multiplier,
    holiday_multiplier = holiday_week_mult,
    trend_index = trend_index,
    price_index = price_index,
    promo_depth_index = promo_depth_index,
    competitor_pressure_index = competitor_pressure_index,
    distribution_uplift = distribution_ramp,
    garden_peak = garden_peak
  )
}

#' Simulate one media channel's TRUE weekly spend, following the flighting
#' pattern described in the config. Some channels are endogenous (spend
#' follows demand / another channel), which is deliberately hard for models
#' to untangle.
simulate_channel_spend <- function(channel_name, ch_cfg, calendar, drivers, search_brand_demand = NULL) {
  n <- nrow(calendar)
  mean_spend <- ch_cfg$mean_weekly_spend_dkk
  t <- calendar$week_index

  base <- switch(ch_cfg$flighting,
    "bursts" = ,
    "bursts_with_tv" = {
      # 5-6 flights/year, ~5 weeks each, roughly aligned to seasonal peaks
      burst_centers <- c(6, 16, 22, 35, 44, 49)
      burst_centers <- rep(burst_centers, length.out = ceiling(max(t) / 52.18) * length(burst_centers)) +
        rep(seq(0, by = 52, length.out = ceiling(max(t) / 52.18)), each = 6)
      intensity <- rowSums(sapply(burst_centers, function(c) dnorm(t, mean = c, sd = 2.2)))
      intensity <- intensity / max(intensity)
      mean_spend * (0.15 + 2.6 * intensity)
    },
    "supports_tv" = {
      burst_centers <- c(7, 17, 23, 36, 45, 50)
      burst_centers <- rep(burst_centers, length.out = ceiling(max(t) / 52.18) * length(burst_centers)) +
        rep(seq(0, by = 52, length.out = ceiling(max(t) / 52.18)), each = 6)
      intensity <- rowSums(sapply(burst_centers, function(c) dnorm(t, mean = c, sd = 3)))
      intensity <- intensity / max(intensity)
      mean_spend * (0.35 + 1.8 * intensity)
    },
    "always_on_with_bursts" = {
      burst_centers <- c(10, 20, 33, 46)
      burst_centers <- rep(burst_centers, length.out = ceiling(max(t) / 52.18) * length(burst_centers)) +
        rep(seq(0, by = 52, length.out = ceiling(max(t) / 52.18)), each = 4)
      intensity <- rowSums(sapply(burst_centers, function(c) dnorm(t, mean = c, sd = 2.5)))
      intensity <- intensity / max(intensity)
      mean_spend * (0.6 + 1.1 * intensity)
    },
    "always_on" = rep(mean_spend, n),
    "weekly_with_seasonal_peaks" = mean_spend * (0.7 + 0.6 * drivers$garden_peak + 0.5 * (calendar$iso_week %in% c(47, 48, 50, 51))),
    "follows_seasonal_demand" = mean_spend * (0.6 + 0.8 * drivers$garden_peak + 0.6 * (calendar$iso_week %in% c(47, 48, 50, 51))) * drivers$seasonal_multiplier / mean(drivers$seasonal_multiplier),
    "follows_traffic" = mean_spend * rep(1, n),  # filled in later using site-traffic proxy
    "follows_brand_demand" = mean_spend * rep(1, n),  # filled in later using lagged TV
    rep(mean_spend, n)
  )

  noise <- exp(rnorm(n, 0, 0.12))
  spend <- pmax(0, base * noise)
  spend
}

#' Simulate the full TRUE weekly dataset (revenue + all media channels).
#' Returns a list with $weekly (tibble) and $media_spend (tibble, wide).
simulate_ground_truth <- function(cfg, weather_weekly, consumer_confidence, cpi_monthly) {
  source_here <- function(f) source(f, local = TRUE)
  calendar <- build_weekly_calendar(cfg)
  holidays <- danish_holidays(unique(calendar$year))
  calendar_ext <- attach_external_drivers(calendar, weather_weekly, consumer_confidence, cpi_monthly)
  drivers <- simulate_non_media_drivers(calendar_ext, cfg, holidays)

  set.seed(cfg$seed + 10)
  n <- nrow(calendar)

  # First pass: simulate independent / seasonal channels
  channel_names <- names(cfg$media_channels)
  spend <- list()
  for (ch in channel_names) {
    spend[[ch]] <- simulate_channel_spend(ch, cfg$media_channels[[ch]], calendar_ext, drivers)
  }

  # TV drives brand-search demand with a lag (endogeneity)
  tv_adstock <- adstock_geometric(spend[["tv_linear"]], 0.5)
  brand_demand_signal <- dplyr::lag(tv_adstock, cfg$media_channels$search_brand$endogenous_lag_weeks, default = mean(tv_adstock))
  brand_demand_signal <- brand_demand_signal / mean(brand_demand_signal)
  spend[["search_brand"]] <- pmax(0, cfg$media_channels$search_brand$mean_weekly_spend_dkk *
                                     (0.35 + 0.9 * brand_demand_signal) * exp(rnorm(n, 0, 0.10)))

  # Retargeting spend follows a site-traffic proxy (driven by overall demand level)
  demand_proxy <- drivers$seasonal_multiplier * drivers$trend_index
  demand_proxy <- demand_proxy / mean(demand_proxy)
  spend[["social_retargeting"]] <- pmax(0, cfg$media_channels$social_retargeting$mean_weekly_spend_dkk *
                                           (0.5 + 0.7 * demand_proxy) * exp(rnorm(n, 0, 0.10)))

  media_spend <- tibble::as_tibble(spend)
  media_spend$week_start <- calendar$week_start

  # --- TRUE media contribution to revenue ---
  media_contrib <- matrix(0, n, length(channel_names), dimnames = list(NULL, channel_names))
  for (ch in channel_names) {
    ch_cfg <- cfg$media_channels[[ch]]
    sat <- transform_media(spend[[ch]], ch_cfg$adstock_decay, ch_cfg$hill_ec, ch_cfg$hill_shape)
    # Scale beta so that average short-run ROAS matches target_short_run_roas
    avg_sat <- mean(sat)
    avg_spend <- mean(spend[[ch]])
    beta <- ch_cfg$target_short_run_roas * avg_spend / max(avg_sat, 1e-6)
    media_contrib[, ch] <- beta * sat
  }

  # --- Non-media contribution (log-additive on standardised drivers) ---
  # Guard against zero-variance inputs (scale() divides by sd and returns NaN
  # when sd = 0, e.g. a constant driver in a short test fixture).
  z <- function(x) {
    s <- stats::sd(x, na.rm = TRUE)
    if (is.na(s) || s == 0) return(rep(0, length(x)))
    as.numeric(scale(x))
  }
  nm <- cfg$non_media_drivers
  driver_log_effect <-
    nm$price_index$true_beta * z(drivers$price_index) / 100 +
    nm$promo_depth_index$true_beta * drivers$promo_depth_index +
    nm$competitor_pressure_index$true_beta * z(drivers$competitor_pressure_index) / 100 +
    nm$consumer_confidence$true_beta * z(calendar_ext$consumer_confidence) / 10 +
    nm$cpi$true_beta * z(calendar_ext$cpi_index) / 10 +
    nm$temperature_c$true_beta * z(calendar_ext$temperature_c) / 10 *
      (1 + (nm$temperature_c$interact_multiplier - 1) * drivers$garden_peak) +
    nm$precipitation_mm$true_beta * z(calendar_ext$precipitation_mm) / 10

  baseline <- cfg$revenue$baseline_weekly_dkk * drivers$trend_index *
    drivers$seasonal_multiplier * drivers$holiday_multiplier *
    (1 + drivers$distribution_uplift) * exp(driver_log_effect)

  # AR(1) heteroskedastic noise
  rho <- cfg$revenue$noise$ar1_rho
  base_sd <- cfg$revenue$noise$base_sd_dkk
  het_scale <- cfg$revenue$noise$heteroskedastic_scale_with_level
  eps <- numeric(n)
  sd_t <- base_sd * (1 + het_scale * (drivers$seasonal_multiplier - 1) / max(drivers$seasonal_multiplier - 1))
  sd_t[is.na(sd_t)] <- base_sd
  eps[1] <- rnorm(1, 0, sd_t[1])
  for (i in 2:n) eps[i] <- rho * eps[i - 1] + rnorm(1, 0, sd_t[i])

  total_media_contrib <- rowSums(media_contrib)
  revenue_true <- baseline + total_media_contrib + eps

  weekly_truth <- tibble::tibble(
    week_start = calendar$week_start,
    iso_year = calendar$iso_year,
    iso_week = calendar$iso_week,
    revenue_dkk = pmax(0, revenue_true),
    baseline_dkk = baseline,
    total_media_contrib_dkk = total_media_contrib,
    noise_dkk = eps,
    temperature_c = calendar_ext$temperature_c,
    precipitation_mm = calendar_ext$precipitation_mm,
    consumer_confidence = calendar_ext$consumer_confidence,
    cpi_index = calendar_ext$cpi_index
  ) |>
    dplyr::bind_cols(drivers |> dplyr::select(-week_start)) |>
    dplyr::bind_cols(tibble::as_tibble(media_contrib) |> dplyr::rename_with(~ paste0("true_contrib_", .x)))

  list(weekly_truth = weekly_truth, media_spend = media_spend, calendar = calendar_ext, holidays = holidays)
}
