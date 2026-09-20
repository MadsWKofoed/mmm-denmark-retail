test_that("parse_danish_number handles comma decimals and thousands separators", {
  expect_equal(parse_danish_number("1234,56"), 1234.56)
  expect_equal(parse_danish_number("1.234,56"), 1234.56)
  expect_equal(parse_danish_number("1234.56"), 1234.56)
  expect_equal(parse_danish_number("0"), 0)
})

test_that("parse_messy_dates parses several common formats to the same date", {
  target <- as.Date("2023-05-14")
  expect_equal(parse_messy_dates("2023-05-14"), target)
  expect_equal(parse_messy_dates("14-05-2023"), target)
  expect_equal(parse_messy_dates("14/05/2023"), target)
  expect_equal(parse_messy_dates("14.05.2023"), target)
})

test_that("convert_to_dkk only converts EUR rows", {
  vals <- c(100, 100)
  cur <- c("DKK", "EUR")
  out <- convert_to_dkk(vals, cur, eur_dkk_rate = 7.46038)
  expect_equal(out[1], 100)
  expect_equal(out[2], 746.038)
})

test_that("match_taxonomy resolves overlapping substrings via row order (NonBrand before Brand)", {
  taxonomy <- tibble::tibble(
    raw_platform = c("google_ads_daily", "google_ads_daily"),
    raw_campaign_pattern = c("*NonBrand*", "*Brand*"),
    channel = c("search_nonbrand", "search_brand"),
    tactic = c("paid_search", "paid_search"),
    funnel_stage = c("mid_funnel", "lower_funnel")
  )
  out <- match_taxonomy(c("HH_Search_NonBrand_202401", "HH_Search_Brand_202401"), "google_ads_daily", taxonomy)
  expect_equal(out$channel, c("search_nonbrand", "search_brand"))
})

test_that("validate_weekly_table catches missing weeks", {
  df <- tibble::tibble(
    week_start = as.Date(c("2022-01-03", "2022-01-17")),  # missing 2022-01-10
    revenue_dkk = c(1000, 1000),
    spend_tv = c(10, 10)
  )
  expect_error(validate_weekly_table(df, expected_weeks = 2), "Missing")
})

test_that("validate_weekly_table catches negative spend", {
  df <- tibble::tibble(
    week_start = as.Date(c("2022-01-03", "2022-01-10")),
    revenue_dkk = c(1000, 1000),
    spend_tv = c(10, -5)
  )
  expect_error(validate_weekly_table(df, expected_weeks = 2), "Negative spend")
})

test_that("validate_weekly_table passes on a clean table", {
  df <- tibble::tibble(
    week_start = as.Date(c("2022-01-03", "2022-01-10")),
    revenue_dkk = c(1000, 1200),
    spend_tv = c(10, 20)
  )
  expect_true(validate_weekly_table(df, expected_weeks = 2))
})

test_that("reconcile_totals errors when weekly and raw totals diverge", {
  expect_error(reconcile_totals(1000, 500, label = "test"), "Reconciliation FAILED")
  expect_true(reconcile_totals(1000, 1005, tolerance = 0.01, label = "test"))
})
