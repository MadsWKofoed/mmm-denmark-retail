# =============================================================================
# 07_geo_experiment.R
#
# Simulated geo experiment: social_prospecting switched off in a randomly
# chosen half of Denmark's 98 municipalities for 6 weeks. Analysed with
# difference-in-differences (fixest, two-way fixed effects), an event-study
# plot, a parallel-trends check, randomisation-inference p-value, a
# cluster-bootstrap CI, and a power/minimum-detectable-effect calculation.
# The resulting lift estimate is then used to build an informative prior for
# social_prospecting and the Bayesian MMM (04b) is refit to check whether
# recovery of the true ROAS improves.
#
# The panel's outcome data is legitimately built from ground truth (see
# R/geo_experiment.R docstring for why); the DiD estimation itself never
# looks at ground truth -- it only sees the simulated panel, exactly as a
# real analyst would only see the experiment's outcome data.
#
# Inputs:  data/processed/_truth/weekly_truth.rds, config/ground_truth.yml (panel construction only)
# Outputs: results/tables/07_*.csv, results/figures/07_*.png,
#          results/models/07_bayesian_calibrated.rds
# =============================================================================

library(tidyverse)
library(here)
library(yaml)
library(fixest)
library(brms)

source(here("R", "geo_experiment.R"))
source(here("R", "transformations.R"))
source(here("R", "model_design.R"))
source(here("R", "models_bayesian.R"))
source(here("R", "plotting.R"))

log_msg <- function(...) cat(sprintf("[%s] ", format(Sys.time(), "%H:%M:%S")), sprintf(...), "\n")

mcfg <- read_yaml(here("config", "model_config.yml"))
dir.create(here("results", "tables"), recursive = TRUE, showWarnings = FALSE)
dir.create(here("results", "figures"), recursive = TRUE, showWarnings = FALSE)
dir.create(here("results", "models"), recursive = TRUE, showWarnings = FALSE)

wt_truth <- readRDS(here("data", "processed", "_truth", "weekly_truth.rds"))

# -----------------------------------------------------------------------------
# Build the experiment panel: 12 pre-weeks + 6 treatment weeks, ~week 150
# (well inside the series, away from the very start/end)
# -----------------------------------------------------------------------------
muni_df <- danish_municipalities(seed = mcfg$seed) |> assign_treatment(seed = mcfg$seed + 1)
log_msg(
  "98 municipalities, %d assigned to treatment (prospecting off), %d control. Treated pop share: %.1f%%",
  sum(muni_df$treated), sum(!muni_df$treated), sum(muni_df$pop_share[muni_df$treated]) * 100
)

panel <- simulate_geo_panel(wt_truth, muni_df,
  pre_weeks = 12, post_weeks = 6,
  window_end_week_index = 150, seed = mcfg$seed + 2
)
write_csv(panel |> select(-population), here("results", "tables", "07_geo_panel.csv"))
log_msg("Panel built: %d municipality-weeks (%d munis x %d weeks)", nrow(panel), n_distinct(panel$municipality), n_distinct(panel$week_index))

# -----------------------------------------------------------------------------
# DiD: two-way fixed effects
# -----------------------------------------------------------------------------
log_msg("Fitting two-way fixed-effects DiD...")
panel <- panel |> mutate(treated_post = treated & is_post)
did_fit <- feols(revenue_pc ~ treated_post | municipality + week_index, data = panel, cluster = ~municipality)
did_summary <- summary(did_fit)
did_coef <- coef(did_fit)["treated_postTRUE"]
did_se <- se(did_fit)["treated_postTRUE"]
log_msg("DiD estimate: %.2f DKK per-capita per week (SE %.2f, clustered by municipality)", did_coef, did_se)

total_pop <- sum(muni_df$population)
national_weekly_lift_dkk <- did_coef * total_pop
national_weekly_lift_se_dkk <- did_se * total_pop
log_msg(
  "Implied national weekly lift from switching prospecting OFF: %.0f DKK (SE %.0f) -- so switching it",
  national_weekly_lift_dkk, national_weekly_lift_se_dkk
)
log_msg("  ON is estimated to ADD about %.0f DKK/week nationally while active.", -national_weekly_lift_dkk)

# -----------------------------------------------------------------------------
# Event study: leads and lags around the treatment window
# -----------------------------------------------------------------------------
log_msg("Fitting event-study specification...")
event_fit <- feols(revenue_pc ~ i(week_rel, treated, ref = -1) | municipality + week_index,
  data = panel, cluster = ~municipality
)
event_coefs <- broom::tidy(event_fit, conf.int = TRUE) |>
  mutate(week_rel = as.integer(str_extract(term, "-?\\d+"))) |>
  filter(!is.na(week_rel))
write_csv(event_coefs, here("results", "tables", "07_event_study.csv"))

p_event <- ggplot(event_coefs, aes(week_rel, estimate)) +
  geom_hline(yintercept = 0, color = mmm_pal("ink_secondary"), linewidth = 0.4) +
  geom_vline(xintercept = -0.5, linetype = "dashed", color = mmm_pal("ink_secondary")) +
  geom_pointrange(aes(ymin = conf.low, ymax = conf.high), color = mmm_pal("primary")) +
  labs(
    title = "Event study: treated vs. control per-capita revenue, relative to week -1",
    subtitle = "Dashed line = start of the 6-week test window. Flat pre-period = parallel trends holds.",
    x = "Weeks relative to test start", y = "Estimate (DKK per capita)"
  ) +
  mmm_theme()
ggsave(here("results", "figures", "07_event_study.png"), p_event, width = 9, height = 5.5, dpi = 130)

# -----------------------------------------------------------------------------
# Parallel-trends check: joint test that pre-period leads are zero
# -----------------------------------------------------------------------------
pre_terms <- event_coefs$term[event_coefs$week_rel < -1]
if (length(pre_terms) > 0) {
  pt_test <- wald(event_fit, keep = pre_terms)
  log_msg(
    "Parallel-trends check (joint Wald test, pre-period leads = 0): p=%.3f (%s)",
    pt_test$p, ifelse(pt_test$p > 0.05, "PASS -- no evidence against parallel trends", "FAIL -- pre-trends detected, interpret DiD with caution")
  )
  write_csv(tibble(stat = pt_test$stat, p = pt_test$p), here("results", "tables", "07_parallel_trends_test.csv"))
}

# -----------------------------------------------------------------------------
# Randomisation inference: permute treatment assignment (same group sizes),
# recompute DiD under each permutation, compare against actual estimate.
# -----------------------------------------------------------------------------
log_msg("Running randomisation inference (500 permutations)...")
set.seed(mcfg$seed + 3)
n_perm <- 500
muni_ids <- unique(panel$municipality)
n_treat <- sum(muni_df$treated)

perm_estimates <- map_dbl(seq_len(n_perm), function(i) {
  perm_treated <- sample(muni_ids, n_treat)
  perm_panel <- panel |> mutate(treated_perm = municipality %in% perm_treated, treated_post_perm = treated_perm & is_post)
  fit <- tryCatch(
    feols(revenue_pc ~ treated_post_perm | municipality + week_index, data = perm_panel, notes = FALSE),
    error = function(e) NULL
  )
  if (is.null(fit) || !("treated_post_permTRUE" %in% names(coef(fit)))) {
    return(NA_real_)
  }
  coef(fit)["treated_post_permTRUE"]
})
perm_estimates <- perm_estimates[!is.na(perm_estimates)]
ri_p_value <- mean(abs(perm_estimates) >= abs(did_coef))
log_msg("Randomisation-inference p-value: %.3f (%d valid permutations)", ri_p_value, length(perm_estimates))

p_ri <- ggplot(tibble(estimate = perm_estimates), aes(estimate)) +
  geom_histogram(bins = 40, fill = mmm_pal("ink_muted"), alpha = 0.7) +
  geom_vline(xintercept = did_coef, color = mmm_pal("negative"), linewidth = 1) +
  labs(
    title = "Randomisation inference: null distribution of the DiD estimate",
    subtitle = sprintf("Red line = actual estimate (%.2f). p = %.3f", did_coef, ri_p_value),
    x = "DiD estimate under random treatment reassignment (DKK per capita)", y = "Count"
  ) +
  mmm_theme()
ggsave(here("results", "figures", "07_randomization_inference.png"), p_ri, width = 8, height = 5, dpi = 130)

# -----------------------------------------------------------------------------
# Cluster bootstrap CI (resample municipalities with replacement)
# -----------------------------------------------------------------------------
log_msg("Running cluster bootstrap (500 resamples)...")
set.seed(mcfg$seed + 4)
n_boot <- 500
boot_estimates <- map_dbl(seq_len(n_boot), function(i) {
  boot_munis <- sample(muni_ids, length(muni_ids), replace = TRUE)
  boot_panel <- map_dfr(seq_along(boot_munis), function(j) {
    panel |>
      filter(municipality == boot_munis[j]) |>
      mutate(municipality = paste0(municipality, "_", j))
  })
  fit <- tryCatch(feols(revenue_pc ~ treated_post | municipality + week_index, data = boot_panel, notes = FALSE),
    error = function(e) NULL
  )
  if (is.null(fit) || !("treated_postTRUE" %in% names(coef(fit)))) {
    return(NA_real_)
  }
  coef(fit)["treated_postTRUE"]
})
boot_estimates <- boot_estimates[!is.na(boot_estimates)]
boot_ci <- quantile(boot_estimates, c(0.05, 0.95))
log_msg("Bootstrap 90%% CI for DiD estimate: [%.2f, %.2f] DKK per capita", boot_ci[1], boot_ci[2])

# -----------------------------------------------------------------------------
# Power / minimum detectable effect
# -----------------------------------------------------------------------------
sd_perm <- sd(perm_estimates)
mde_90pct_power <- sd_perm * (qnorm(0.975) + qnorm(0.90)) # two-sided alpha=0.05, power=90%
achieved_power <- pnorm(abs(did_coef) / sd_perm - qnorm(0.975))
log_msg(
  "Design SD (from permutation null): %.2f. MDE at 90%% power: %.2f DKK/capita. Achieved power for the observed effect: %.1f%%",
  sd_perm, mde_90pct_power, achieved_power * 100
)

power_table <- tibble(
  did_estimate = did_coef, did_se_clustered = did_se, permutation_sd = sd_perm,
  mde_90pct_power_dkk_percapita = mde_90pct_power, achieved_power_pct = achieved_power * 100,
  randomization_inference_p = ri_p_value, bootstrap_ci_lower = boot_ci[1], bootstrap_ci_upper = boot_ci[2]
)
write_csv(power_table, here("results", "tables", "07_did_summary.csv"))

# -----------------------------------------------------------------------------
# Convert the lift to an experiment-implied ROAS for social_prospecting, to
# use as a calibration prior for the Bayesian model.
# -----------------------------------------------------------------------------
ridge_model <- readRDS(here("results", "models", "04a_ridge_model.rds"))
window_spend <- wt_truth$week_start # placeholder to align indices below
weeks_idx <- seq(150 - 12 + 1, 150 + 6)
post_weeks_idx <- weeks_idx[13:18] # the 6 post-period weeks

wt <- readRDS(here("data", "processed", "weekly_modelling_table.rds"))
avg_weekly_spend_prospecting <- mean(wt$spend_social_prospecting[post_weeks_idx])
experiment_implied_roas <- (-national_weekly_lift_dkk) / avg_weekly_spend_prospecting
experiment_roas_se <- national_weekly_lift_se_dkk / avg_weekly_spend_prospecting
log_msg("Experiment-implied ROAS for social_prospecting: %.2f (SE %.2f)", experiment_implied_roas, experiment_roas_se)
write_csv(
  tibble(channel = "social_prospecting", experiment_implied_roas, experiment_roas_se),
  here("results", "tables", "07_experiment_implied_roas.csv")
)

# -----------------------------------------------------------------------------
# Calibrate the Bayesian MMM: refit with an experiment-informed prior for
# social_prospecting specifically (replacing its generic shared prior),
# and check whether recovery of the TRUE ROAS improves.
# -----------------------------------------------------------------------------
log_msg("Refitting the Bayesian MMM with an experiment-calibrated prior for social_prospecting...")

bayes_model <- readRDS(here("results", "models", "04b_bayesian_model.rds"))
channels <- ridge_model$channels
final_params <- ridge_model$params
holdout_n <- ridge_model$holdout_n
wt <- wt |> add_time_features()
n_total <- nrow(wt)
wt_train <- wt[seq_len(n_total - holdout_n), ]

media_mat <- build_media_matrix(wt_train, channels, final_params)
control_mat <- as.matrix(wt_train[, mmm_control_cols()])
mean_revenue <- mean(wt_train$revenue_dkk)
model_df <- as_tibble(media_mat) |>
  bind_cols(as_tibble(control_mat)) |>
  mutate(y_scaled = wt_train$revenue_dkk / mean_revenue, t = wt_train$t)

# Convert the experiment's DKK-scale ROAS estimate into the nlpar's
# "share of average revenue at full saturation" scale (same transform 04a
# uses to go from a coefficient to a DKK contribution, inverted).
sat_sum <- sum(media_mat[, "social_prospecting"])
spend_total <- sum(wt_train$spend_social_prospecting)
beta_mean <- experiment_implied_roas * spend_total / (sat_sum * mean_revenue)
beta_sd <- experiment_roas_se * spend_total / (sat_sum * mean_revenue)
log_msg("Experiment-informed prior for social_prospecting nlpar: normal(%.3f, %.3f) [lb=0]", beta_mean, beta_sd)

fp_calibrated <- build_bayes_formula_priors(channels, mmm_control_cols(), mcfg$bayesian,
  prior_overrides = list(social_prospecting = list(mean = beta_mean, sd = beta_sd))
)

mcmc_cfg <- mcfg$bayesian$full
fit_calibrated <- brm(
  formula = fp_calibrated$formula, data = model_df, prior = fp_calibrated$prior, family = gaussian(),
  chains = mcmc_cfg$chains, warmup = mcmc_cfg$iter_warmup, iter = mcmc_cfg$iter_warmup + mcmc_cfg$iter_sampling,
  backend = bayes_model$backend, seed = mcfg$seed, cores = 1,
  control = list(adapt_delta = mcfg$bayesian$adapt_delta, max_treedepth = mcfg$bayesian$max_treedepth),
  refresh = 0
)

spend_totals <- setNames(as.list(colSums(wt_train[, paste0("spend_", channels)])), channels)
calibrated_summary <- posterior_channel_summary(fit_calibrated, media_mat, spend_totals, mean_revenue, prob = 0.90)
write_csv(calibrated_summary, here("results", "tables", "07_channel_roas_calibrated.csv"))

# Compare social_prospecting's recovery before vs. after calibration
truth_cfg <- readRDS(here("data", "processed", "_truth", "ground_truth_config_snapshot.rds"))
true_roas_prospecting <- truth_cfg$media_channels$social_prospecting$target_short_run_roas
before <- bayes_model$channel_summary |> filter(channel == "social_prospecting")
after <- calibrated_summary |> filter(channel == "social_prospecting")
calibration_comparison <- tibble(
  channel = "social_prospecting", true_roas = true_roas_prospecting,
  roas_before_calibration = before$roas_mean, roas_before_lower = before$roas_lower, roas_before_upper = before$roas_upper,
  roas_after_calibration = after$roas_mean, roas_after_lower = after$roas_lower, roas_after_upper = after$roas_upper,
  error_before = abs(before$roas_mean - true_roas_prospecting), error_after = abs(after$roas_mean - true_roas_prospecting)
)
write_csv(calibration_comparison, here("results", "tables", "07_calibration_comparison.csv"))
log_msg(
  "social_prospecting ROAS recovery: true=%.2f, before calibration=%.2f [%.2f, %.2f], after=%.2f [%.2f, %.2f]",
  true_roas_prospecting, before$roas_mean, before$roas_lower, before$roas_upper,
  after$roas_mean, after$roas_lower, after$roas_upper
)
log_msg(
  "Calibration %s the estimate (error %.2f -> %.2f)",
  ifelse(calibration_comparison$error_after < calibration_comparison$error_before, "IMPROVED", "did NOT improve"),
  calibration_comparison$error_before, calibration_comparison$error_after
)

saveRDS(
  list(fit = fit_calibrated, channel_summary = calibrated_summary, prior_mean = beta_mean, prior_sd = beta_sd),
  here("results", "models", "07_bayesian_calibrated.rds")
)

p_calibration <- calibration_comparison |>
  select(
    true_roas, roas_before_calibration, roas_before_lower, roas_before_upper,
    roas_after_calibration, roas_after_lower, roas_after_upper
  ) |>
  pivot_longer(-true_roas, names_to = "key", values_to = "value") |>
  mutate(
    stage = ifelse(str_detect(key, "_before_"), "Before calibration", "After calibration"),
    stat = case_when(
      str_detect(key, "_lower$") ~ "lower",
      str_detect(key, "_upper$") ~ "upper",
      TRUE ~ "estimate"
    )
  ) |>
  select(-key) |>
  pivot_wider(names_from = stat, values_from = value)

p_calib_plot <- ggplot(p_calibration, aes(stage, estimate)) +
  geom_hline(aes(yintercept = true_roas), linetype = "dashed", color = mmm_pal("negative")) +
  geom_pointrange(aes(ymin = lower, ymax = upper), color = mmm_pal("primary"), size = 0.8) +
  labs(
    title = "social_prospecting: does the geo experiment improve ROAS recovery?",
    subtitle = sprintf("Dashed red line = true ROAS (%.2f)", true_roas_prospecting),
    x = NULL, y = "Estimated ROAS (90% credible interval)"
  ) +
  mmm_theme()
ggsave(here("results", "figures", "07_calibration_comparison.png"), p_calib_plot, width = 7, height = 5.5, dpi = 130)

log_msg("Done. Wrote experiment tables/figures with prefix 07_, calibrated model to results/models/07_bayesian_calibrated.rds")
