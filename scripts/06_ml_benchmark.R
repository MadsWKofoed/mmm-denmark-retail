# =============================================================================
# 06_ml_benchmark.R
#
# ML benchmark (xgboost, ranger) on the same rolling-origin CV design as the
# MMM, to compare predictive accuracy -- and then explain why predictive
# accuracy alone is not enough for ROI/budget decisions: neither model
# enforces non-negative media effects, monotonic response, or produces a
# usable per-channel contribution decomposition without extra (fragile)
# machinery like SHAP, and neither can simulate "what if we changed next
# month's spend" the way the MMM's structural transforms can.
#
# Inputs:  data/processed/weekly_modelling_table.rds, results/models/04a_ridge_model.rds
# Outputs: results/tables/06_*.csv, results/figures/06_*.png
# =============================================================================

library(tidyverse)
library(here)
library(yaml)
library(xgboost)
library(ranger)

source(here("R", "transformations.R"))
source(here("R", "model_design.R"))
source(here("R", "models_transform_search.R"))
source(here("R", "plotting.R"))

log_msg <- function(...) cat(sprintf("[%s] ", format(Sys.time(), "%H:%M:%S")), sprintf(...), "\n")

mcfg <- read_yaml(here("config", "model_config.yml"))
dir.create(here("results", "tables"), recursive = TRUE, showWarnings = FALSE)
dir.create(here("results", "figures"), recursive = TRUE, showWarnings = FALSE)

wt <- readRDS(here("data", "processed", "weekly_modelling_table.rds")) |> add_time_features()
ridge_model <- readRDS(here("results", "models", "04a_ridge_model.rds"))
channels <- ridge_model$channels
holdout_n <- ridge_model$holdout_n
n_total <- nrow(wt)
train_idx <- seq_len(n_total - holdout_n)
test_idx <- seq(n_total - holdout_n + 1, n_total)
wt_train <- wt[train_idx, ]
wt_test <- wt[test_idx, ]

# ML models get RAW spend (not adstocked/saturated) plus the same controls --
# the whole point is these are flexible non-parametric models that could, in
# principle, learn nonlinear/lagged relationships on their own. In practice,
# with ~180 weekly rows, they mostly can't (see results below).
feature_cols <- c(paste0("spend_", channels), mmm_control_cols())
X_train <- as.matrix(wt_train[, feature_cols])
X_test <- as.matrix(wt_test[, feature_cols])
y_train <- wt_train$revenue_dkk
y_test <- wt_test$revenue_dkk

accuracy_metrics <- function(actual, predicted, model_name) {
  resid <- actual - predicted
  tibble(
    model = model_name, rmse = sqrt(mean(resid^2)), mape_pct = mean(abs(resid / actual)) * 100,
    r2 = 1 - sum(resid^2) / sum((actual - mean(actual))^2), bias_pct = mean(resid / actual) * 100
  )
}

# -----------------------------------------------------------------------------
# Rolling-origin CV for both ML models (same fold design as the MMM)
# -----------------------------------------------------------------------------
cv_cfg <- mcfg$cv$full
folds <- rolling_origin_folds(nrow(wt_train), cv_cfg$initial_window_weeks, cv_cfg$step_weeks, cv_cfg$horizon_weeks)
log_msg("Running rolling-origin CV for xgboost and ranger (%d folds)...", length(folds))

cv_results <- map_dfr(seq_along(folds), function(i) {
  fold <- folds[[i]]
  Xtr <- X_train[fold$train, ]
  ytr <- y_train[fold$train]
  Xte <- X_train[fold$test, ]
  yte <- y_train[fold$test]

  xgb_fit <- xgboost(
    data = Xtr, label = ytr, nrounds = 150, max_depth = 3, eta = 0.05,
    subsample = 0.8, colsample_bytree = 0.8, objective = "reg:squarederror", verbose = 0
  )
  xgb_pred <- predict(xgb_fit, Xte)

  rf_fit <- ranger(y ~ ., data = data.frame(y = ytr, Xtr), num.trees = 500, mtry = floor(ncol(Xtr) / 3), seed = mcfg$seed)
  rf_pred <- predict(rf_fit, data.frame(Xte))$predictions

  bind_rows(
    accuracy_metrics(yte, xgb_pred, "xgboost") |> mutate(fold = i),
    accuracy_metrics(yte, rf_pred, "ranger (random forest)") |> mutate(fold = i)
  )
})
write_csv(cv_results, here("results", "tables", "06_ml_rolling_cv_metrics.csv"))

cv_summary <- cv_results |>
  group_by(model) |>
  summarise(mean_mape = mean(mape_pct), mean_rmse = mean(rmse), mean_r2 = mean(r2), .groups = "drop")
log_msg("Rolling-origin CV summary (ML models, training period):")
print(cv_summary)

# -----------------------------------------------------------------------------
# Final fit on full training data, evaluate on the untouched holdout
# -----------------------------------------------------------------------------
log_msg("Fitting final xgboost and ranger on full training data...")
xgb_final <- xgboost(
  data = X_train, label = y_train, nrounds = 150, max_depth = 3, eta = 0.05,
  subsample = 0.8, colsample_bytree = 0.8, objective = "reg:squarederror", verbose = 0
)
xgb_pred_test <- predict(xgb_final, X_test)

rf_final <- ranger(y ~ .,
  data = data.frame(y = y_train, X_train), num.trees = 500,
  mtry = floor(ncol(X_train) / 3), importance = "impurity", seed = mcfg$seed
)
rf_pred_test <- predict(rf_final, data.frame(X_test))$predictions

holdout_comparison_ml <- bind_rows(
  accuracy_metrics(y_test, xgb_pred_test, "xgboost"),
  accuracy_metrics(y_test, rf_pred_test, "ranger (random forest)")
)

# Bring in the MMM's holdout numbers (already computed in 05) for one
# combined comparison table, if available.
mmm_holdout_path <- here("results", "tables", "05_holdout_comparison.csv")
if (file.exists(mmm_holdout_path)) {
  full_comparison <- bind_rows(read_csv(mmm_holdout_path, show_col_types = FALSE), holdout_comparison_ml) |> arrange(mape_pct)
} else {
  full_comparison <- holdout_comparison_ml
}
write_csv(full_comparison, here("results", "tables", "06_holdout_comparison_with_ml.csv"))
log_msg("Holdout comparison including ML models:")
print(full_comparison)

# -----------------------------------------------------------------------------
# Feature importance (xgboost gain, ranger impurity) -- and why this is NOT
# the same thing as an ROAS/contribution decomposition
# -----------------------------------------------------------------------------
xgb_importance <- xgb.importance(model = xgb_final) |>
  as_tibble() |>
  transmute(feature = Feature, xgb_gain = Gain)
rf_importance <- tibble(feature = names(rf_final$variable.importance), rf_importance = rf_final$variable.importance)
importance_table <- full_join(xgb_importance, rf_importance, by = "feature") |>
  filter(feature %in% paste0("spend_", channels)) |>
  mutate(channel = str_remove(feature, "spend_")) |>
  arrange(desc(xgb_gain))
write_csv(importance_table, here("results", "tables", "06_ml_feature_importance.csv"))
log_msg("Media spend feature importance (xgboost gain, ranger impurity) -- NOTE these are NOT ROAS or DKK contributions:")
print(importance_table |> select(channel, xgb_gain, rf_importance))

p_importance <- importance_table |>
  select(channel, xgb_gain) |>
  ggplot(aes(reorder(channel, xgb_gain), xgb_gain)) +
  geom_col(fill = mmm_pal("primary")) +
  coord_flip() +
  labs(
    title = "xgboost feature importance (gain) for media spend variables",
    subtitle = "This ranks predictive usefulness, NOT incremental revenue or ROAS -- see script header",
    x = NULL, y = "Gain"
  ) +
  mmm_theme()
ggsave(here("results", "figures", "06_ml_feature_importance.png"), p_importance, width = 8, height = 5, dpi = 130)

# -----------------------------------------------------------------------------
# The honest write-up point, computed directly: even if the ML models win on
# holdout accuracy, they give no usable answer to "if I move 100K DKK from
# channel A to channel B, what happens to revenue" without heavy additional
# machinery (partial dependence / SHAP, with no guarantee of monotonicity or
# plausible response shape) -- the MMM's transforms answer this by
# construction (scripts/08_decision_tools.R relies on exactly this).
# -----------------------------------------------------------------------------
log_msg("Done. Wrote tables/figures with prefix 06_.")
log_msg("Key point for the write-up: predictive accuracy (MAPE/RMSE) is not the same as a usable")
log_msg("budget-allocation answer -- xgboost/ranger have no structural media-response curve to")
log_msg("simulate spend changes with, unlike the MMM's adstock+Hill transforms.")
