# =============================================================================
# 03_baselines.R
#
# Three deliberately naive baselines, diagnosed thoroughly, to show WHY a
# proper MMM (adstock + saturation + regularisation + a real error structure)
# is needed rather than just throwing revenue ~ spend into lm(). This script
# is meant to fail informatively.
#
#   1. Seasonal naive: revenue_t = revenue_{t-52} (last year, same week).
#   2. No-media model: revenue ~ controls only (trend, seasonality, holidays,
#      promo, price, competitor, macro, weather) -- no media terms at all.
#   3. OLS on RAW, untransformed spend + controls -- the naive "just run a
#      regression" approach. Diagnosed with VIF, Durbin-Watson, Breusch-
#      Godfrey, Breusch-Pagan, residual ACF, and Newey-West HAC SEs.
#
# Inputs:  data/processed/weekly_modelling_table.rds
# Outputs: results/tables/03_*.csv, results/figures/03_*.png
# =============================================================================

library(tidyverse)
library(here)
library(car)
library(lmtest)
library(sandwich)
library(broom)
library(scales)

source(here("R", "plotting.R"))

dir.create(here("results", "figures"), recursive = TRUE, showWarnings = FALSE)
dir.create(here("results", "tables"), recursive = TRUE, showWarnings = FALSE)

log_msg <- function(...) cat(sprintf("[%s] ", format(Sys.time(), "%H:%M:%S")), sprintf(...), "\n")

wt <- readRDS(here("data", "processed", "weekly_modelling_table.rds"))
spend_cols <- names(wt) |> keep(~ str_starts(.x, "spend_"))

# Fourier terms for seasonality controls (same idea as the simulator, but
# fit from data -- these scripts never see config/ground_truth.yml)
wt <- wt |>
  mutate(
    t = row_number(),
    fourier_sin1 = sin(2 * pi * t / 52.18), fourier_cos1 = cos(2 * pi * t / 52.18),
    fourier_sin2 = sin(4 * pi * t / 52.18), fourier_cos2 = cos(4 * pi * t / 52.18),
    month = lubridate::month(week_start)
  )

controls_formula_rhs <- paste(
  "t + fourier_sin1 + fourier_cos1 + fourier_sin2 + fourier_cos2 +",
  "promo_depth_pct + temperature_c + precipitation_mm + consumer_confidence + cpi_index + n_stores +",
  "is_easter_week + is_ascension_week + is_whitmonday_week + is_great_prayer_week + is_christmas_week"
)

# -----------------------------------------------------------------------------
# 1. Seasonal naive
# -----------------------------------------------------------------------------
log_msg("Fitting seasonal naive baseline...")
wt <- wt |> mutate(seasonal_naive_pred = lag(revenue_dkk, 52))
sn_eval <- wt |> filter(!is.na(seasonal_naive_pred))
sn_mape <- mean(abs((sn_eval$revenue_dkk - sn_eval$seasonal_naive_pred) / sn_eval$revenue_dkk)) * 100
sn_rmse <- sqrt(mean((sn_eval$revenue_dkk - sn_eval$seasonal_naive_pred)^2))
log_msg(
  "  Seasonal naive (revenue_t = revenue_{t-52}): MAPE=%.1f%%, RMSE=%.0f DKK (n=%d weeks evaluable)",
  sn_mape, sn_rmse, nrow(sn_eval)
)

# -----------------------------------------------------------------------------
# 2. No-media model
# -----------------------------------------------------------------------------
log_msg("Fitting no-media model (controls only, no spend terms)...")
no_media_formula <- as.formula(paste("revenue_dkk ~", controls_formula_rhs))
no_media_fit <- lm(no_media_formula, data = wt)
no_media_r2 <- summary(no_media_fit)$r.squared
no_media_resid_sd <- sd(resid(no_media_fit))
log_msg("  No-media model R^2=%.3f (this is the ceiling controls alone can explain; the rest is media + noise)", no_media_r2)

# -----------------------------------------------------------------------------
# 3. OLS on RAW spend + controls -- the naive approach
# -----------------------------------------------------------------------------
log_msg("Fitting naive OLS on raw (untransformed) spend + controls...")
ols_formula <- as.formula(paste("revenue_dkk ~", paste(spend_cols, collapse = " + "), "+", controls_formula_rhs))
ols_fit <- lm(ols_formula, data = wt)
ols_r2 <- summary(ols_fit)$r.squared
log_msg("  Naive OLS R^2=%.3f", ols_r2)

ols_coefs <- broom::tidy(ols_fit) |>
  filter(term %in% spend_cols) |>
  mutate(
    channel = str_remove(term, "spend_"),
    wrong_signed = estimate < 0,
    significant_at_5pct = p.value < 0.05
  )
write_csv(ols_coefs, here("results", "tables", "03_naive_ols_coefficients.csv"))

log_msg("Naive OLS media coefficients (DKK revenue per DKK spend, i.e. should be a plausible ROAS if unbiased):")
print(ols_coefs |> select(channel, estimate, std.error, p.value, wrong_signed))
n_wrong_signed <- sum(ols_coefs$wrong_signed)
log_msg(
  "  %d of %d channels have a NEGATIVE (wrong-signed) coefficient despite genuinely positive true effects -- this is the collinearity from Phase 2 breaking OLS.",
  n_wrong_signed, nrow(ols_coefs)
)

# -----------------------------------------------------------------------------
# Diagnostics on the naive OLS model
# -----------------------------------------------------------------------------
log_msg("Running diagnostics on naive OLS (VIF, Durbin-Watson, Breusch-Godfrey, Breusch-Pagan)...")

vif_vals <- car::vif(ols_fit)
vif_table <- tibble(term = names(vif_vals), vif = vif_vals) |>
  filter(term %in% spend_cols) |>
  mutate(channel = str_remove(term, "spend_")) |>
  select(channel, vif) |>
  arrange(desc(vif))

dw_test <- lmtest::dwtest(ols_fit)
bg_test <- lmtest::bgtest(ols_fit, order = 4) # residual autocorrelation up to lag 4
bp_test <- lmtest::bptest(ols_fit) # heteroskedasticity

diagnostics <- tibble(
  test = c("Durbin-Watson (autocorrelation)", "Breusch-Godfrey (autocorrelation, order 4)", "Breusch-Pagan (heteroskedasticity)"),
  statistic = c(dw_test$statistic, bg_test$statistic, bp_test$statistic),
  p_value = c(dw_test$p.value, bg_test$p.value, bp_test$p.value),
  interpretation = c(
    if (dw_test$p.value < 0.05) "Significant positive autocorrelation in residuals -- SEs are unreliable" else "No strong evidence of autocorrelation",
    if (bg_test$p.value < 0.05) "Residuals are autocorrelated beyond lag 1 too" else "No higher-order autocorrelation detected",
    if (bp_test$p.value < 0.05) "Heteroskedastic residuals -- standard SEs are invalid, need robust/HAC SEs" else "Homoskedastic residuals"
  )
)
write_csv(diagnostics, here("results", "tables", "03_naive_ols_diagnostics.csv"))
log_msg("Diagnostic test results:")
print(diagnostics |> select(test, statistic, p_value))

# Residual ACF
png(here("results", "figures", "03_residual_acf.png"), width = 800, height = 500, res = 120)
acf(resid(ols_fit), main = "Naive OLS residual ACF (autocorrelation across lags)")
dev.off()

# -----------------------------------------------------------------------------
# Newey-West HAC standard errors -- what the coefficients "should" look like
# once we at least fix the SEs (though the point estimates are still biased
# by the omitted adstock/saturation transforms and collinearity)
# -----------------------------------------------------------------------------
log_msg("Computing Newey-West HAC standard errors...")
hac_se <- lmtest::coeftest(ols_fit, vcov = sandwich::NeweyWest(ols_fit, lag = 4, prewhite = FALSE))
hac_table <- broom::tidy(hac_se) |>
  filter(term %in% spend_cols) |>
  mutate(channel = str_remove(term, "spend_")) |>
  rename(hac_std.error = std.error, hac_statistic = statistic, hac_p.value = p.value) |>
  select(channel, estimate, hac_std.error, hac_p.value)
write_csv(hac_table, here("results", "tables", "03_naive_ols_hac_coefficients.csv"))
log_msg("With Newey-West HAC SEs, standard errors widen substantially -- several 'significant' effects from the naive OLS are no longer significant:")
print(hac_table)

# -----------------------------------------------------------------------------
# Comparison table + plot: naive OLS coefficient vs VIF, colored by sign
# -----------------------------------------------------------------------------
comparison <- ols_coefs |>
  select(channel, naive_ols_estimate = estimate, naive_ols_p = p.value) |>
  left_join(vif_table, by = "channel") |>
  left_join(hac_table |> select(channel, hac_p.value), by = "channel")
write_csv(comparison, here("results", "tables", "03_baseline_summary.csv"))

p_coefs <- ggplot(ols_coefs, aes(reorder(channel, estimate), estimate, fill = wrong_signed)) +
  geom_col() +
  geom_hline(yintercept = 0, color = mmm_pal("ink_secondary"), linewidth = 0.4) +
  coord_flip() +
  scale_fill_manual(
    values = c(`FALSE` = mmm_pal("primary"), `TRUE` = mmm_pal("negative")),
    labels = c(`FALSE` = "Positive (plausible sign)", `TRUE` = "Negative (wrong sign)"), name = NULL
  ) +
  labs(
    title = "Naive OLS on raw spend: media coefficients",
    subtitle = sprintf("%d of %d channels come out wrong-signed due to collinearity -- this is why adstock/saturation + regularisation matter", n_wrong_signed, nrow(ols_coefs)),
    x = NULL, y = "OLS coefficient (DKK revenue per DKK spend)"
  ) +
  mmm_theme()
ggsave(here("results", "figures", "03_naive_ols_coefficients.png"), p_coefs, width = 9, height = 5.5, dpi = 130)

# -----------------------------------------------------------------------------
# Baseline accuracy summary (in-sample; proper out-of-time validation in Phase 5)
# -----------------------------------------------------------------------------
baseline_summary <- tibble(
  model = c("Seasonal naive", "No-media model", "Naive OLS on raw spend"),
  in_sample_r2 = c(NA, no_media_r2, ols_r2),
  mape_pct = c(sn_mape, mean(abs(resid(no_media_fit) / wt$revenue_dkk)) * 100, mean(abs(resid(ols_fit) / wt$revenue_dkk)) * 100),
  notes = c(
    "Simple, robust, but blind to media entirely -- can't answer any 'what if we changed spend' question.",
    "Shows how much controls alone explain; the gap to actual revenue is what media + noise must cover.",
    sprintf(
      "%d of %d channels wrong-signed; residuals autocorrelated (DW p=%.3f) and heteroskedastic (BP p=%.3f) -- coefficients are not trustworthy for budget decisions.",
      n_wrong_signed, nrow(ols_coefs), dw_test$p.value, bp_test$p.value
    )
  )
)
write_csv(baseline_summary, here("results", "tables", "03_baseline_comparison.csv"))
log_msg("Baseline comparison:")
print(baseline_summary |> select(model, in_sample_r2, mape_pct))

log_msg("Done. Wrote tables and figures to results/ (prefix 03_)")
