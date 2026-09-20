# =============================================================================
# 05_validation.R
#
# Out-of-time validation on the final 26-week holdout (never touched by any
# tuning in 04a/04b), plus rolling-origin CV summaries and residual
# diagnostics, comparing: seasonal naive, no-media model, naive OLS, ridge
# MMM, Bayesian MMM. MAPE, RMSE, R^2, bias vs actuals.
#
# scripts/05b_recovery_study.R (SEPARATE script) is the only place ground
# truth is used, to check estimated ROAS/decay/saturation against it.
#
# Inputs:  results/models/04a_ridge_model.rds, results/models/04b_bayesian_model.rds,
#          data/processed/weekly_modelling_table.rds
# Outputs: results/tables/05_*.csv, results/figures/05_*.png
# =============================================================================

library(tidyverse)
library(here)
library(yaml)
library(glmnet)
library(brms)

source(here("R", "transformations.R"))
source(here("R", "model_design.R"))
source(here("R", "plotting.R"))

log_msg <- function(...) cat(sprintf("[%s] ", format(Sys.time(), "%H:%M:%S")), sprintf(...), "\n")

mcfg <- read_yaml(here("config", "model_config.yml"))
dir.create(here("results", "tables"), recursive = TRUE, showWarnings = FALSE)
dir.create(here("results", "figures"), recursive = TRUE, showWarnings = FALSE)

wt <- readRDS(here("data", "processed", "weekly_modelling_table.rds")) |> add_time_features()
ridge_model <- readRDS(here("results", "models", "04a_ridge_model.rds"))
bayes_model <- readRDS(here("results", "models", "04b_bayesian_model.rds"))

holdout_n <- ridge_model$holdout_n
n_total <- nrow(wt)
train_idx <- seq_len(n_total - holdout_n)
test_idx <- seq(n_total - holdout_n + 1, n_total)
wt_train <- wt[train_idx, ]
wt_test <- wt[test_idx, ]
channels <- ridge_model$channels
final_params <- ridge_model$params

log_msg(
  "Out-of-time holdout: %d weeks, %s to %s (untouched by all tuning above)",
  holdout_n, min(wt_test$week_start), max(wt_test$week_start)
)

# Build media matrix on the FULL series then split, so adstock carryover
# correctly propagates from the training period into the holdout.
media_split <- build_media_matrix_full_then_split(wt, channels, final_params, train_idx, test_idx)

accuracy_metrics <- function(actual, predicted, model_name) {
  resid <- actual - predicted
  tibble(
    model = model_name,
    rmse = sqrt(mean(resid^2)),
    mape_pct = mean(abs(resid / actual)) * 100,
    r2 = 1 - sum(resid^2) / sum((actual - mean(actual))^2),
    bias_pct = mean(resid / actual) * 100 # positive = under-forecast on average
  )
}

# -----------------------------------------------------------------------------
# Baselines evaluated on the SAME holdout (refit-free: seasonal naive just
# looks back 52 weeks; no-media/naive OLS refit on training only, matching
# scripts/03_baselines.R's spec, then predict on holdout)
# -----------------------------------------------------------------------------
log_msg("Evaluating baselines on the holdout...")

seasonal_naive_pred <- wt$revenue_dkk[test_idx - 52]
m_seasonal_naive <- accuracy_metrics(wt_test$revenue_dkk, seasonal_naive_pred, "Seasonal naive")

controls_formula_rhs <- paste(
  "t + fourier_sin1 + fourier_cos1 + fourier_sin2 + fourier_cos2 +",
  "promo_depth_pct + temperature_c + precipitation_mm + consumer_confidence + cpi_index + n_stores +",
  "is_easter_week + is_ascension_week + is_whitmonday_week + is_great_prayer_week + is_christmas_week"
)
no_media_fit <- lm(as.formula(paste("revenue_dkk ~", controls_formula_rhs)), data = wt_train)
m_no_media <- accuracy_metrics(wt_test$revenue_dkk, predict(no_media_fit, newdata = wt_test), "No-media model")

spend_cols <- paste0("spend_", channels)
ols_fit <- lm(as.formula(paste("revenue_dkk ~", paste(spend_cols, collapse = " + "), "+", controls_formula_rhs)), data = wt_train)
m_ols <- accuracy_metrics(wt_test$revenue_dkk, predict(ols_fit, newdata = wt_test), "Naive OLS on raw spend")

# -----------------------------------------------------------------------------
# Ridge/elastic-net MMM (04a)
# -----------------------------------------------------------------------------
log_msg("Evaluating ridge MMM on the holdout...")
control_mat_test <- as.matrix(wt_test[, mmm_control_cols()])
X_test <- cbind(media_split$test, control_mat_test)
ridge_pred <- as.numeric(predict(ridge_model$fit, newx = X_test))
m_ridge <- accuracy_metrics(wt_test$revenue_dkk, ridge_pred, "Ridge/elastic-net MMM")

# -----------------------------------------------------------------------------
# Bayesian MMM (04b)
# -----------------------------------------------------------------------------
log_msg("Evaluating Bayesian MMM on the holdout...")
newdata_test <- as_tibble(media_split$test) |>
  bind_cols(as_tibble(control_mat_test)) |>
  mutate(t = wt_test$t, y_scaled = wt_test$revenue_dkk / bayes_model$mean_revenue)
bayes_pred_draws <- posterior_predict(bayes_model$fit, newdata = newdata_test, allow_new_levels = TRUE)
bayes_pred_scaled <- colMeans(bayes_pred_draws)
bayes_pred <- bayes_pred_scaled * bayes_model$mean_revenue
bayes_pred_lower <- apply(bayes_pred_draws, 2, quantile, 0.05) * bayes_model$mean_revenue
bayes_pred_upper <- apply(bayes_pred_draws, 2, quantile, 0.95) * bayes_model$mean_revenue
m_bayes <- accuracy_metrics(wt_test$revenue_dkk, bayes_pred, "Bayesian MMM")

coverage_90 <- mean(wt_test$revenue_dkk >= bayes_pred_lower & wt_test$revenue_dkk <= bayes_pred_upper)
log_msg("Bayesian MMM 90%% predictive interval coverage on holdout: %.1f%% (target ~90%%)", coverage_90 * 100)

# -----------------------------------------------------------------------------
# Comparison table
# -----------------------------------------------------------------------------
comparison <- bind_rows(m_seasonal_naive, m_no_media, m_ols, m_ridge, m_bayes) |> arrange(mape_pct)
write_csv(comparison, here("results", "tables", "05_holdout_comparison.csv"))
log_msg("Out-of-time holdout comparison (%d weeks, untouched by tuning):", holdout_n)
print(comparison)

# -----------------------------------------------------------------------------
# Rolling-origin CV summary on the training period, at the FINAL chosen
# transform (for the ridge model) -- reports the CV distribution, not just
# the single random-search winner's score.
# -----------------------------------------------------------------------------
log_msg("Rolling-origin CV summary (ridge MMM, final chosen transform)...")
source(here("R", "models_transform_search.R"))
cv_cfg <- mcfg$cv$full
folds <- rolling_origin_folds(nrow(wt_train), cv_cfg$initial_window_weeks, cv_cfg$step_weeks, cv_cfg$horizon_weeks)
cv_fold_metrics <- map_dfr(seq_along(folds), function(i) {
  fold <- folds[[i]]
  d_tr <- build_design(wt_train[fold$train, ], channels, final_params)
  d_te <- build_design(wt_train[fold$test, ], channels, final_params)
  lower <- c(rep(0, length(channels)), rep(-Inf, length(mmm_control_cols())))
  fit <- glmnet(d_tr$X, d_tr$y, alpha = mcfg$glmnet$alpha, lower.limits = lower, standardize = TRUE)
  cvf <- cv.glmnet(d_tr$X, d_tr$y, alpha = mcfg$glmnet$alpha, lower.limits = lower, nfolds = 5, standardize = TRUE)
  pred <- as.numeric(predict(fit, newx = d_te$X, s = cvf$lambda.1se))
  m <- accuracy_metrics(d_te$y, pred, sprintf("fold_%d", i))
  m$fold <- i
  m
})
write_csv(cv_fold_metrics, here("results", "tables", "05_rolling_cv_metrics.csv"))
log_msg(
  "Rolling-origin CV (ridge MMM): mean MAPE=%.1f%%, mean RMSE=%.0f, mean R2=%.3f across %d folds",
  mean(cv_fold_metrics$mape_pct), mean(cv_fold_metrics$rmse), mean(cv_fold_metrics$r2), nrow(cv_fold_metrics)
)

# -----------------------------------------------------------------------------
# Residual diagnostics on holdout (ridge + Bayesian)
# -----------------------------------------------------------------------------
resid_df <- tibble(
  week_start = wt_test$week_start,
  actual = wt_test$revenue_dkk,
  ridge_pred = ridge_pred, ridge_resid = wt_test$revenue_dkk - ridge_pred,
  bayes_pred = bayes_pred, bayes_pred_lower = bayes_pred_lower, bayes_pred_upper = bayes_pred_upper,
  bayes_resid = wt_test$revenue_dkk - bayes_pred
)
write_csv(resid_df, here("results", "tables", "05_holdout_predictions.csv"))

png(here("results", "figures", "05_holdout_residual_acf.png"), width = 900, height = 500, res = 120)
par(mfrow = c(1, 2))
acf(resid_df$ridge_resid, main = "Ridge MMM holdout residual ACF")
acf(resid_df$bayes_resid, main = "Bayesian MMM holdout residual ACF")
dev.off()

p_holdout <- resid_df |>
  select(week_start, actual, ridge_pred, bayes_pred, bayes_pred_lower, bayes_pred_upper) |>
  ggplot(aes(week_start)) +
  geom_ribbon(aes(ymin = bayes_pred_lower, ymax = bayes_pred_upper), fill = mmm_pal("primary"), alpha = 0.15) +
  geom_line(aes(y = actual, color = "Actual"), linewidth = 0.9) +
  geom_line(aes(y = ridge_pred, color = "Ridge MMM"), linewidth = 0.7, linetype = "dashed") +
  geom_line(aes(y = bayes_pred, color = "Bayesian MMM"), linewidth = 0.7) +
  scale_color_manual(values = c(Actual = mmm_pal("ink_primary"), `Ridge MMM` = mmm_pal("warning"), `Bayesian MMM` = mmm_pal("primary")), name = NULL) +
  scale_y_continuous(labels = scales::label_number(scale = 1e-6, suffix = "M")) +
  labs(
    title = "Out-of-time holdout: actual vs. predicted revenue", subtitle = "Shaded band = Bayesian MMM 90% predictive interval",
    x = NULL, y = "Revenue (DKK)"
  ) +
  mmm_theme()
ggsave(here("results", "figures", "05_holdout_actual_vs_predicted.png"), p_holdout, width = 10, height = 5, dpi = 130)

log_msg("Done. Wrote tables/figures with prefix 05_")
