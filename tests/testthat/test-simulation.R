cfg_test <- yaml::read_yaml(here::here("config", "ground_truth.yml"))

# Small, fast synthetic external data for simulator tests (avoids network calls)
make_fake_external <- function(cfg) {
  weeks <- seq(as.Date(cfg$period$start_date), as.Date(cfg$period$end_date), by = "week")
  iso_year <- lubridate::isoyear(weeks)
  iso_week <- lubridate::isoweek(weeks)
  weather <- tibble::tibble(
    iso_year = iso_year, iso_week = iso_week,
    temperature_c = 10 + 5 * sin(seq_along(weeks)), precipitation_mm = 20
  )
  months <- unique(sprintf("%dM%02d", lubridate::year(weeks), lubridate::month(weeks)))
  confidence <- tibble::tibble(year_month = months, consumer_confidence = 0)
  cpi <- tibble::tibble(year_month = months, cpi_index = 100)
  list(weather = weather, confidence = confidence, cpi = cpi)
}

test_that("simulate_ground_truth is reproducible given the same seed", {
  ext <- make_fake_external(cfg_test)
  out1 <- simulate_ground_truth(cfg_test, ext$weather, ext$confidence, ext$cpi)
  out2 <- simulate_ground_truth(cfg_test, ext$weather, ext$confidence, ext$cpi)
  expect_equal(out1$weekly_truth$revenue_dkk, out2$weekly_truth$revenue_dkk)
  expect_equal(out1$media_spend$tv_linear, out2$media_spend$tv_linear)
})

test_that("simulate_ground_truth produces the configured number of weeks", {
  ext <- make_fake_external(cfg_test)
  out <- simulate_ground_truth(cfg_test, ext$weather, ext$confidence, ext$cpi)
  expect_equal(nrow(out$weekly_truth), cfg_test$period$n_weeks)
  expect_equal(nrow(out$media_spend), cfg_test$period$n_weeks)
})

test_that("simulate_ground_truth produces non-negative revenue and spend", {
  ext <- make_fake_external(cfg_test)
  out <- simulate_ground_truth(cfg_test, ext$weather, ext$confidence, ext$cpi)
  expect_true(all(out$weekly_truth$revenue_dkk >= 0))
  media_cols <- setdiff(names(out$media_spend), "week_start")
  for (col in media_cols) expect_true(all(out$media_spend[[col]] >= 0))
})

test_that("simulate_ground_truth media channels are all present with the configured names", {
  ext <- make_fake_external(cfg_test)
  out <- simulate_ground_truth(cfg_test, ext$weather, ext$confidence, ext$cpi)
  expect_setequal(setdiff(names(out$media_spend), "week_start"), names(cfg_test$media_channels))
})

test_that("media contributes a plausible share of revenue (config target: 15-30%)", {
  ext <- make_fake_external(cfg_test)
  out <- simulate_ground_truth(cfg_test, ext$weather, ext$confidence, ext$cpi)
  media_share <- mean(out$weekly_truth$total_media_contrib_dkk / out$weekly_truth$revenue_dkk)
  expect_gt(media_share, 0.10)
  expect_lt(media_share, 0.35)
})
