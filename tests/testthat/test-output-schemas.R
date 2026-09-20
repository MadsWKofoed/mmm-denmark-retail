# These tests check the SHAPE of pipeline outputs when they exist, so the
# suite still passes on a clean checkout before `make all` has been run
# (they skip rather than fail when a given output hasn't been produced yet).

expect_has_columns <- function(df, cols) {
  missing <- setdiff(cols, names(df))
  expect_true(length(missing) == 0, info = paste("Missing columns:", paste(missing, collapse = ", ")))
}

test_that("weekly modelling table has the expected schema", {
  path <- here::here("data", "processed", "weekly_modelling_table.rds")
  skip_if_not(file.exists(path), "weekly_modelling_table.rds not built yet")
  wt <- readRDS(path)
  expect_has_columns(wt, c("week_start", "iso_year", "iso_week", "revenue_dkk",
                            "promo_depth_pct", "temperature_c", "precipitation_mm",
                            "consumer_confidence", "cpi_index", "n_stores"))
  expect_true(all(!is.na(wt$revenue_dkk)))
  expect_true(all(wt$revenue_dkk > 0))
  expect_equal(anyDuplicated(wt$week_start), 0)
  expect_true(is.numeric(wt$revenue_dkk))
})

test_that("ridge MMM model object has the expected structure", {
  path <- here::here("results", "models", "04a_ridge_model.rds")
  skip_if_not(file.exists(path), "04a_ridge_model.rds not built yet")
  m <- readRDS(path)
  expect_true(all(c("fit", "params", "channels", "control_cols", "train_r2", "holdout_n") %in% names(m)))
  expect_length(m$params, length(m$channels))
  expect_true(m$train_r2 > 0 && m$train_r2 <= 1)
})

test_that("channel ROAS tables have one row per channel and no negative spend", {
  path <- here::here("results", "tables", "04a_channel_roas.csv")
  skip_if_not(file.exists(path), "04a_channel_roas.csv not built yet")
  roas <- readr::read_csv(path, show_col_types = FALSE)
  expect_has_columns(roas, c("channel", "total_spend_dkk", "total_contribution_dkk", "roas"))
  expect_equal(nrow(roas), 9)
  expect_true(all(roas$total_spend_dkk >= 0))
  expect_equal(anyDuplicated(roas$channel), 0)
})

test_that("Bayesian posterior ROAS table has credible intervals that bracket the mean", {
  path <- here::here("results", "tables", "04b_channel_roas_posterior.csv")
  skip_if_not(file.exists(path), "04b_channel_roas_posterior.csv not built yet")
  roas <- readr::read_csv(path, show_col_types = FALSE)
  expect_has_columns(roas, c("channel", "roas_mean", "roas_lower", "roas_upper"))
  expect_true(all(roas$roas_lower <= roas$roas_mean))
  expect_true(all(roas$roas_mean <= roas$roas_upper))
})

test_that("budget allocation table sums to the current total and stays non-negative", {
  path <- here::here("results", "tables", "08_budget_allocation.csv")
  skip_if_not(file.exists(path), "08_budget_allocation.csv not built yet")
  alloc <- readr::read_csv(path, show_col_types = FALSE)
  expect_has_columns(alloc, c("channel", "current_spend_dkk", "optimal_spend_dkk", "change_pct"))
  expect_equal(sum(alloc$optimal_spend_dkk), sum(alloc$current_spend_dkk), tolerance = 1)
  expect_true(all(alloc$optimal_spend_dkk >= 0))
})

test_that("data dictionary documents every column of the weekly modelling table", {
  dict_path <- here::here("data", "processed", "data_dictionary.csv")
  wt_path <- here::here("data", "processed", "weekly_modelling_table.rds")
  skip_if_not(file.exists(dict_path) && file.exists(wt_path), "outputs not built yet")
  dict <- readr::read_csv(dict_path, show_col_types = FALSE)
  wt <- readRDS(wt_path)
  expect_equal(sort(dict$column), sort(names(wt)))
})
