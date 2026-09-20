# =============================================================================
# 04b_mmm_bayesian.R
#
# Core MMM, part (ii): Bayesian model (brms + cmdstanr backend), reusing the
# adstock/Hill transforms chosen by 04a's rolling-origin CV search (see
# R/models_bayesian.R for why). Weakly informative half-normal priors on
# media effects, normal priors on controls, AR(1) errors, posterior
# predictive checks, and posterior ROAS/contribution with 90% credible
# intervals.
#
# Falls back to rstan if cmdstanr/CmdStan is unavailable (per the brief).
#
# Inputs:  results/models/04a_ridge_model.rds, data/processed/weekly_modelling_table.rds
# Outputs: results/models/04b_bayesian_model.rds, results/tables/04b_*.csv,
#          results/figures/04b_*.png
# =============================================================================

library(tidyverse)
library(here)
library(yaml)
library(brms)

source(here("R", "transformations.R"))
source(here("R", "model_design.R"))
source(here("R", "models_bayesian.R"))
source(here("R", "plotting.R"))

log <- function(...) cat(sprintf("[%s] ", format(Sys.time(), "%H:%M:%S")), sprintf(...), "\n")

quick <- Sys.getenv("MMM_QUICK", "0") == "1"
mcfg <- read_yaml(here("config", "model_config.yml"))
bcfg <- mcfg$bayesian
mcmc_cfg <- if (quick) bcfg$quick else bcfg$full
channels <- mcfg$media_channels

dir.create(here("results", "models"), recursive = TRUE, showWarnings = FALSE)
dir.create(here("results", "tables"), recursive = TRUE, showWarnings = FALSE)
dir.create(here("results", "figures"), recursive = TRUE, showWarnings = FALSE)

# Pick a Stan backend: cmdstanr if CmdStan is actually installed, else rstan.
backend <- "rstan"
if (requireNamespace("cmdstanr", quietly = TRUE)) {
  cmdstan_ok <- tryCatch({ cmdstanr::cmdstan_path(); TRUE }, error = function(e) FALSE)
  if (cmdstan_ok) backend <- "cmdstanr"
}
log("Using Stan backend: %s", backend)

wt <- readRDS(here("data", "processed", "weekly_modelling_table.rds")) |> add_time_features()
ridge_model <- readRDS(here("results", "models", "04a_ridge_model.rds"))
final_params <- ridge_model$params
holdout_n <- ridge_model$holdout_n
n_total <- nrow(wt)
wt_train <- wt[seq_len(n_total - holdout_n), ]
log("Reusing 04a's chosen media transforms (decay/ec/shape) for the Bayesian model.")

media_mat <- build_media_matrix(wt_train, channels, final_params)
control_mat <- as.matrix(wt_train[, mmm_control_cols()])

mean_revenue <- mean(wt_train$revenue_dkk)
model_df <- as_tibble(media_mat) |>
  bind_cols(as_tibble(control_mat)) |>
  mutate(y_scaled = wt_train$revenue_dkk / mean_revenue, t = wt_train$t)

fp <- build_bayes_formula_priors(channels, mmm_control_cols(), bcfg)

log("Fitting brms model: %d chains, %d warmup, %d sampling iterations (media_effect_prior_sd=%.2f)...",
    mcmc_cfg$chains, mcmc_cfg$iter_warmup, mcmc_cfg$iter_sampling, bcfg$media_effect_prior_sd)
t0 <- Sys.time()
fit <- brm(
  formula = fp$formula, data = model_df, prior = fp$prior, family = gaussian(),
  chains = mcmc_cfg$chains, warmup = mcmc_cfg$iter_warmup, iter = mcmc_cfg$iter_warmup + mcmc_cfg$iter_sampling,
  # cores = 1 (sequential chains) deliberately -- spawning multiple parallel
  # cmdstanr worker processes crashes silently in this machine's sandboxed
  # shell environment (confirmed: identical model succeeds with cores=1,
  # dies with no error message at cores=4). Sequential chains are slower
  # but reliable; if running outside this sandbox, cores = mcmc_cfg$chains
  # is safe and faster.
  backend = backend, seed = mcfg$seed, cores = 1,
  control = list(adapt_delta = bcfg$adapt_delta, max_treedepth = bcfg$max_treedepth),
  refresh = 200  # periodic progress output -- silent long-running jobs (refresh=0) appear to get killed in this sandbox
)
log("MCMC done in %.1f minutes.", as.numeric(Sys.time() - t0, units = "mins"))

# -----------------------------------------------------------------------------
# Convergence diagnostics
# -----------------------------------------------------------------------------
summ <- summary(fit)
rhat_max <- max(summ$fixed$Rhat, na.rm = TRUE)
ess_min <- min(summ$fixed$Bulk_ESS, na.rm = TRUE)
log("Convergence: max Rhat=%.3f (want <1.01), min bulk ESS=%.0f (want >400)", rhat_max, ess_min)
if (rhat_max > 1.05) log("WARNING: some parameters have not converged well (Rhat > 1.05).")

divergences <- sum(brms::nuts_params(fit, pars = "divergent__")$Value)
log("Divergent transitions: %d", divergences)

write_csv(as_tibble(summ$fixed, rownames = "parameter"), here("results", "tables", "04b_mcmc_summary.csv"))

# -----------------------------------------------------------------------------
# Posterior predictive checks
# -----------------------------------------------------------------------------
log("Posterior predictive checks...")
pp_plot <- pp_check(fit, ndraws = 100) +
  labs(title = "Posterior predictive check: y_scaled (revenue / mean training revenue)") +
  mmm_theme()
ggsave(here("results", "figures", "04b_posterior_predictive_check.png"), pp_plot, width = 8, height = 5, dpi = 130)

pred_scaled <- posterior_predict(fit)
pred_mean_dkk <- colMeans(pred_scaled) * mean_revenue
bayes_r2_val <- bayes_R2(fit)
log("Bayesian R^2: mean=%.3f, 90%% CI [%.3f, %.3f]", bayes_r2_val[1, "Estimate"], bayes_r2_val[1, "Q2.5"], bayes_r2_val[1, "Q97.5"])

# -----------------------------------------------------------------------------
# Posterior ROAS and contribution by channel, 90% credible intervals
# -----------------------------------------------------------------------------
log("Computing posterior channel summaries (90%% credible intervals)...")
spend_totals <- setNames(as.list(colSums(wt_train[, paste0("spend_", channels)])), channels)
channel_summary <- posterior_channel_summary(fit, media_mat, spend_totals, mean_revenue, prob = 0.90) |>
  arrange(desc(roas_mean))
write_csv(channel_summary, here("results", "tables", "04b_channel_roas_posterior.csv"))
log("Posterior ROAS by channel (90%% CI):")
print(channel_summary |> select(channel, roas_mean, roas_lower, roas_upper))

media_share_draws <- {
  draws <- as_draws_matrix(fit)
  contrib_per_draw <- sapply(seq_along(channels), function(i) sum(media_mat[, channels[i]]) * as.numeric(draws[, sprintf("b_eff%d_Intercept", i)]))
  total_contrib_draws <- rowSums(contrib_per_draw) * mean_revenue
  total_contrib_draws / sum(wt_train$revenue_dkk)
}
log("Bayesian model media share of revenue: mean=%.1f%%, 90%% CI [%.1f%%, %.1f%%] (vs 04a's point estimate 63.5%%, true 16.6%%)",
    mean(media_share_draws) * 100, quantile(media_share_draws, 0.05) * 100, quantile(media_share_draws, 0.95) * 100)

p_roas_bayes <- ggplot(channel_summary, aes(reorder(channel, roas_mean), roas_mean)) +
  geom_col(fill = mmm_pal("primary")) +
  geom_errorbar(aes(ymin = roas_lower, ymax = roas_upper), width = 0.25, color = mmm_pal("ink_secondary")) +
  geom_hline(yintercept = 1, linetype = "dashed", color = mmm_pal("ink_secondary")) +
  coord_flip() +
  labs(title = "Bayesian MMM: posterior ROAS by channel", subtitle = "90% credible intervals; dashed line = breakeven",
       x = NULL, y = "Posterior ROAS") +
  mmm_theme()
ggsave(here("results", "figures", "04b_roas_posterior.png"), p_roas_bayes, width = 8, height = 5, dpi = 130)

# -----------------------------------------------------------------------------
# Save model
# -----------------------------------------------------------------------------
saveRDS(list(
  fit = fit, params = final_params, channels = channels, control_cols = mmm_control_cols(),
  mean_revenue = mean_revenue, holdout_n = holdout_n, backend = backend,
  rhat_max = rhat_max, divergences = divergences, channel_summary = channel_summary
), here("results", "models", "04b_bayesian_model.rds"))

log("Done. Wrote model to results/models/04b_bayesian_model.rds, tables/figures with prefix 04b_")
