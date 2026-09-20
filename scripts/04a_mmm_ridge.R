# =============================================================================
# 04a_mmm_ridge.R
#
# Core MMM, part (i): adstock + Hill saturation per channel, with transform
# hyperparameters (decay, ec, shape) chosen by rolling-origin time-series CV
# via a parallel random search (fixed seed) -- NEVER using ground truth.
# Final model is a non-negative-media-coefficient elastic net (glmnet).
#
# The last N weeks (config$holdout$final_holdout_weeks) are held out
# completely untouched by this script -- they are reserved for
# scripts/05_validation.R's out-of-time evaluation.
#
# Inputs:  data/processed/weekly_modelling_table.rds, config/model_config.yml
# Outputs: results/models/04a_ridge_model.rds, results/tables/04a_*.csv,
#          results/figures/04a_*.png
# =============================================================================

library(tidyverse)
library(here)
library(yaml)
library(glmnet)
library(furrr)

source(here("R", "transformations.R"))
source(here("R", "model_design.R"))
source(here("R", "models_transform_search.R"))
source(here("R", "plotting.R"))

log_msg <- function(...) cat(sprintf("[%s] ", format(Sys.time(), "%H:%M:%S")), sprintf(...), "\n")

quick <- Sys.getenv("MMM_QUICK", "0") == "1"
mcfg <- read_yaml(here("config", "model_config.yml"))
cv_cfg <- if (quick) mcfg$cv$quick else mcfg$cv$full
n_draws <- if (quick) mcfg$transform_search$quick$n_draws else mcfg$transform_search$full$n_draws
channels <- mcfg$media_channels

dir.create(here("results", "models"), recursive = TRUE, showWarnings = FALSE)
dir.create(here("results", "tables"), recursive = TRUE, showWarnings = FALSE)
dir.create(here("results", "figures"), recursive = TRUE, showWarnings = FALSE)

set.seed(mcfg$seed)
plan(multisession, workers = max(1, parallel::detectCores() - 1))

wt <- readRDS(here("data", "processed", "weekly_modelling_table.rds")) |> add_time_features()

holdout_n <- mcfg$holdout$final_holdout_weeks
n_total <- nrow(wt)
wt_train <- wt[seq_len(n_total - holdout_n), ]
wt_holdout <- wt[seq(n_total - holdout_n + 1, n_total), ]
log_msg("Training weeks: %d, final untouched holdout weeks: %d (%s to %s)",
    nrow(wt_train), nrow(wt_holdout), min(wt_holdout$week_start), max(wt_holdout$week_start))

# -----------------------------------------------------------------------------
# Random search over adstock/saturation transforms, scored by rolling-origin
# CV RMSE within the training period only.
# -----------------------------------------------------------------------------
log_msg("Running random search: %d draws over %d-dim transform space (rolling-origin CV, %s window/%s step/%s horizon weeks)...",
    n_draws, length(channels) * 3, cv_cfg$initial_window_weeks, cv_cfg$step_weeks, cv_cfg$horizon_weeks)

t0 <- Sys.time()
search_result <- random_search_transforms(
  wt_train, channels, cv_cfg, mcfg$transform_search, n_draws,
  alpha = mcfg$glmnet$alpha, n_lambda = mcfg$glmnet$n_lambda, base_seed = mcfg$seed
)
log_msg("Search done in %.1fs, %d CV folds per draw.", as.numeric(Sys.time() - t0, units = "secs"), search_result$n_folds)

best <- search_result$summary |> slice(1)
best_draw <- search_result$draws[[which(search_result$summary$draw_seed[1] == vapply(search_result$draws, `[[`, numeric(1), "seed"))]]$draw
log_msg("Best draw: seed=%d, CV RMSE=%.0f DKK (vs worst draw in search: %.0f DKK)",
    best$draw_seed, best$cv_rmse, max(search_result$summary$cv_rmse, na.rm = TRUE))

search_summary_out <- search_result$summary
write_csv(search_summary_out, here("results", "tables", "04a_transform_search_results.csv"))

# -----------------------------------------------------------------------------
# Resolve the winning draw's params using the FULL training set, then fit
# the final elastic net with proper CV-selected lambda (5-fold CV, allowed
# to be random-fold rather than rolling-origin here since lambda selection
# within a fixed, already-chosen transform is a much smaller decision).
# -----------------------------------------------------------------------------
final_params <- resolve_draw(best_draw, wt_train, channels)
params_table <- map_dfr(channels, function(ch) {
  tibble(channel = ch, decay = final_params[[ch]]$decay, ec = final_params[[ch]]$ec, shape = final_params[[ch]]$shape)
})
write_csv(params_table, here("results", "tables", "04a_best_transform_params.csv"))
log_msg("Chosen transform parameters:")
print(params_table)

d_train <- build_design(wt_train, channels, final_params)
lower <- c(rep(0, length(channels)), rep(-Inf, length(mmm_control_cols())))

log_msg("Fitting final elastic net (alpha=%.2f) with CV-selected lambda...", mcfg$glmnet$alpha)
set.seed(mcfg$seed)
cvfit <- cv.glmnet(d_train$X, d_train$y, alpha = mcfg$glmnet$alpha, lower.limits = lower,
                    nfolds = mcfg$glmnet$final_cv_folds, standardize = TRUE)
final_fit <- glmnet(d_train$X, d_train$y, alpha = mcfg$glmnet$alpha, lower.limits = lower,
                     lambda = cvfit$lambda.1se, standardize = TRUE)

pred_train <- as.numeric(predict(final_fit, newx = d_train$X))
train_r2 <- 1 - sum((d_train$y - pred_train)^2) / sum((d_train$y - mean(d_train$y))^2)
train_rmse <- sqrt(mean((d_train$y - pred_train)^2))
log_msg("Final model (training fit): R^2=%.3f, RMSE=%.0f DKK", train_r2, train_rmse)

# -----------------------------------------------------------------------------
# Media coefficients, contributions, and implied ROAS on the training period
# -----------------------------------------------------------------------------
coefs <- as.matrix(coef(final_fit))
media_coefs <- tibble(channel = channels, coefficient = coefs[channels, 1])

media_mat_train <- build_media_matrix(wt_train, channels, final_params)
contributions <- sweep(media_mat_train, 2, media_coefs$coefficient, `*`)
colnames(contributions) <- channels

roas_table <- map_dfr(channels, function(ch) {
  spend <- sum(wt_train[[paste0("spend_", ch)]])
  contrib <- sum(contributions[, ch])
  tibble(channel = ch, total_spend_dkk = spend, total_contribution_dkk = contrib,
         roas = contrib / spend, coefficient = media_coefs$coefficient[media_coefs$channel == ch])
}) |> arrange(desc(roas))
write_csv(roas_table, here("results", "tables", "04a_channel_roas.csv"))
log_msg("Ridge/elastic-net MMM: estimated ROAS by channel (training period):")
print(roas_table |> select(channel, total_spend_dkk, roas))

n_zeroed <- sum(media_coefs$coefficient == 0)
log_msg("%d of %d channels shrunk to exactly zero by the elastic net penalty.", n_zeroed, length(channels))

total_contrib <- rowSums(contributions)
baseline_contrib <- pred_train - total_contrib
decomposition <- tibble(
  week_start = wt_train$week_start,
  actual_revenue = d_train$y,
  predicted_revenue = pred_train,
  baseline_contrib = baseline_contrib,
  media_contrib = total_contrib
) |> bind_cols(as_tibble(contributions) |> rename_with(~ paste0("contrib_", .x)))
write_csv(decomposition, here("results", "tables", "04a_decomposition.csv"))

media_share <- mean(total_contrib / d_train$y)
log_msg("Media share of predicted revenue (training period): %.1f%%", media_share * 100)
if (media_share > 0.40) {
  log_msg("NOTE: this is a known limitation of the regularised model, not a bug -- see docs/methodology.md.")
  log_msg("  With media and seasonal controls this collinear, CV-optimal regularisation (chosen purely for")
  log_msg("  predictive fit) does not pin down a unique causal media/baseline split: several very different")
  log_msg("  attributions fit the data almost equally well. This is exactly why scripts/04b (Bayesian, with")
  log_msg("  informative priors) and scripts/07 (geo experiment calibration) exist -- predictive accuracy")
  log_msg("  alone is not sufficient for a trustworthy budget-allocation decision.")
}

# -----------------------------------------------------------------------------
# Response curves (saturation curves) per channel, at the fitted transform
# -----------------------------------------------------------------------------
log_msg("Building response curves...")
response_curves <- map_dfr(channels, function(ch) {
  p <- final_params[[ch]]
  max_spend <- max(wt_train[[paste0("spend_", ch)]]) * 2.5
  spend_grid <- seq(0, max_spend, length.out = 100)
  sat <- hill_saturation(spend_grid, ec = p$ec, shape = p$shape)  # response to a single-week spend level (no adstock, illustrative)
  coef_val <- media_coefs$coefficient[media_coefs$channel == ch]
  tibble(channel = ch, spend_dkk = spend_grid, predicted_contribution_dkk = sat * coef_val)
})
write_csv(response_curves, here("results", "tables", "04a_response_curves.csv"))

p_response <- ggplot(response_curves, aes(spend_dkk, predicted_contribution_dkk)) +
  geom_line(color = mmm_pal("primary"), linewidth = 0.8) +
  facet_wrap(~channel, scales = "free", ncol = 3) +
  scale_x_continuous(labels = scales::label_number(scale = 1e-3, suffix = "K")) +
  scale_y_continuous(labels = scales::label_number(scale = 1e-3, suffix = "K")) +
  labs(title = "Estimated response curves (diminishing returns)", subtitle = "Single-week spend -> contribution, at the fitted saturation curve",
       x = "Weekly spend (DKK)", y = "Contribution (DKK)") +
  mmm_theme()
ggsave(here("results", "figures", "04a_response_curves.png"), p_response, width = 11, height = 8, dpi = 130)

p_roas <- ggplot(roas_table, aes(reorder(channel, roas), roas)) +
  geom_col(fill = mmm_pal("primary")) +
  geom_hline(yintercept = 1, linetype = "dashed", color = mmm_pal("ink_secondary")) +
  coord_flip() +
  labs(title = "Ridge/elastic-net MMM: estimated ROAS by channel", subtitle = "Training period; dashed line = breakeven (ROAS = 1)",
       x = NULL, y = "Estimated ROAS") +
  mmm_theme()
ggsave(here("results", "figures", "04a_roas_by_channel.png"), p_roas, width = 8, height = 5, dpi = 130)

p_decomp <- decomposition |>
  select(week_start, baseline_contrib, media_contrib) |>
  pivot_longer(-week_start, names_to = "component", values_to = "value") |>
  mutate(component = recode(component, baseline_contrib = "Baseline (trend/season/controls)", media_contrib = "Media"))
p_decomp_plot <- ggplot(p_decomp, aes(week_start, value, fill = component)) +
  geom_area() +
  scale_fill_manual(values = c("Baseline (trend/season/controls)" = mmm_pal("ink_muted"), "Media" = mmm_pal("primary")), name = NULL) +
  scale_y_continuous(labels = scales::label_number(scale = 1e-6, suffix = "M")) +
  labs(title = "Revenue decomposition: baseline vs. media", x = NULL, y = "Revenue (DKK)") +
  mmm_theme()
ggsave(here("results", "figures", "04a_decomposition.png"), p_decomp_plot, width = 10, height = 5, dpi = 130)

# -----------------------------------------------------------------------------
# Save model objects for downstream scripts (validation, optimiser, app)
# -----------------------------------------------------------------------------
saveRDS(list(
  fit = final_fit, cvfit = cvfit, params = final_params, channels = channels,
  control_cols = mmm_control_cols(), train_r2 = train_r2, train_rmse = train_rmse,
  holdout_n = holdout_n, media_coefs = media_coefs
), here("results", "models", "04a_ridge_model.rds"))

log_msg("Done. Wrote model to results/models/04a_ridge_model.rds, tables/figures with prefix 04a_")
