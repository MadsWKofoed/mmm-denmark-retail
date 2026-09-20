# =============================================================================
# 08_decision_tools.R
#
# Decision tools built on the (geo-experiment-calibrated where available)
# Bayesian MMM: a budget allocator (nloptr SLSQP, uncertainty-aware via
# posterior draws), a campaign simulator, and non-media scenario simulations.
# Reads saved model objects only -- no refitting here (the Shiny app reads
# this script's outputs the same way).
#
# Inputs:  results/models/04a_ridge_model.rds, results/models/04b_bayesian_model.rds
#          (07_bayesian_calibrated.rds used for social_prospecting if present)
# Outputs: results/tables/08_*.csv, results/figures/08_*.png
# =============================================================================

library(tidyverse)
library(here)
library(yaml)
library(brms)
library(nloptr)

source(here("R", "transformations.R"))
source(here("R", "model_design.R"))
source(here("R", "optimisation.R"))
source(here("R", "plotting.R"))

log_msg <- function(...) cat(sprintf("[%s] ", format(Sys.time(), "%H:%M:%S")), sprintf(...), "\n")

mcfg <- read_yaml(here("config", "model_config.yml"))
dir.create(here("results", "tables"), recursive = TRUE, showWarnings = FALSE)
dir.create(here("results", "figures"), recursive = TRUE, showWarnings = FALSE)

ridge_model <- readRDS(here("results", "models", "04a_ridge_model.rds"))
bayes_model <- readRDS(here("results", "models", "04b_bayesian_model.rds"))
channels <- ridge_model$channels
params <- ridge_model$params
mean_revenue <- bayes_model$mean_revenue

wt <- readRDS(here("data", "processed", "weekly_modelling_table.rds")) |> add_time_features()
current_spend <- setNames(sapply(channels, function(ch) mean(tail(wt[[paste0("spend_", ch)]], 26))), channels)
log_msg("Current spend baseline (mean of last 26 weeks): total %.0f DKK/week", sum(current_spend))

# -----------------------------------------------------------------------------
# Posterior draws for each channel's nlpar coefficient (use the geo-
# experiment-calibrated fit for social_prospecting if it exists, since it's
# a strictly better estimate; the base 04b fit for everything else)
# -----------------------------------------------------------------------------
draws_base <- as_draws_matrix(bayes_model$fit)
beta_draws_mat <- sapply(seq_along(channels), function(i) as.numeric(draws_base[, sprintf("b_eff%d_Intercept", i)]))
colnames(beta_draws_mat) <- channels

calibrated_path <- here("results", "models", "07_bayesian_calibrated.rds")
if (file.exists(calibrated_path)) {
  log_msg("Using geo-experiment-calibrated posterior for social_prospecting.")
  calibrated <- readRDS(calibrated_path)
  draws_cal <- as_draws_matrix(calibrated$fit)
  prospecting_idx <- which(channels == "social_prospecting")
  cal_draws <- as.numeric(draws_cal[, sprintf("b_eff%d_Intercept", prospecting_idx)])
  # Resample to match beta_draws_mat's row count so matrix ops stay simple.
  beta_draws_mat[, "social_prospecting"] <- sample(cal_draws, nrow(beta_draws_mat), replace = TRUE)
}

# -----------------------------------------------------------------------------
# Budget allocator
# -----------------------------------------------------------------------------
ocfg <- mcfg$optimiser
log_msg(
  "Optimising budget allocation (+/-%.0f%% bounds, %.0f%% contractual minimum)...",
  ocfg$bound_pct * 100, ocfg$contractual_minimum_pct * 100
)

opt_result <- optimise_budget(current_spend,
  total_budget = sum(current_spend), params = params,
  beta_draws_mat = beta_draws_mat, mean_revenue = mean_revenue,
  bound_pct = ocfg$bound_pct, contractual_minimum_pct = ocfg$contractual_minimum_pct
)
log_msg("Optimiser converged: %s (%s)", opt_result$converged, opt_result$message)

comparison <- compare_allocations(opt_result$optimal_spend, current_spend, params, beta_draws_mat, mean_revenue)
log_msg(
  "Optimal vs. current mix: expected uplift %.0f DKK/week [%.0f, %.0f], P(beats current)=%.1f%%",
  comparison$expected_uplift_dkk, comparison$uplift_lower, comparison$uplift_upper, comparison$prob_beats_baseline * 100
)

# Channels with known endogeneity bias (05b_recovery_study.R) that calibration
# (07) has NOT corrected -- their posterior ROAS is still inflated, so an
# optimiser fed those numbers uncritically will recommend MORE spend on
# exactly the channels least trustworthy. Flagged rather than silently acted on.
low_confidence_channels <- c("search_brand", "social_retargeting")

allocation_table <- tibble(
  channel = channels, current_spend_dkk = current_spend, optimal_spend_dkk = opt_result$optimal_spend
) |>
  mutate(
    change_pct = (optimal_spend_dkk - current_spend_dkk) / current_spend_dkk * 100,
    low_confidence_estimate = channel %in% low_confidence_channels
  )
write_csv(allocation_table, here("results", "tables", "08_budget_allocation.csv"))
log_msg("Recommended reallocation:")
print(allocation_table)
if (any(allocation_table$low_confidence_estimate & allocation_table$change_pct > 0)) {
  log_msg(
    "CAVEAT: the optimiser recommends MORE spend on %s -- these channels' posterior ROAS remains",
    paste(allocation_table$channel[allocation_table$low_confidence_estimate & allocation_table$change_pct > 0], collapse = " and ")
  )
  log_msg("  inflated by known endogeneity (see 05b_recovery_study.R), uncorrected by the geo experiment (which only")
  log_msg("  tested social_prospecting). A real recommendation should heavily discount or exclude these channels")
  log_msg("  pending further identification work, not act on this allocation for them at face value.")
}

write_csv(
  tibble(
    expected_uplift_dkk = comparison$expected_uplift_dkk, uplift_lower_90 = comparison$uplift_lower,
    uplift_upper_90 = comparison$uplift_upper, prob_beats_current_mix = comparison$prob_beats_baseline,
    current_weekly_budget_dkk = sum(current_spend)
  ),
  here("results", "tables", "08_optimiser_summary.csv")
)

p_alloc <- allocation_table |>
  select(channel, current_spend_dkk, optimal_spend_dkk) |>
  pivot_longer(-channel, names_to = "type", values_to = "spend") |>
  mutate(type = recode(type, current_spend_dkk = "Current", optimal_spend_dkk = "Recommended"))
p_alloc_plot <- ggplot(p_alloc, aes(reorder(channel, spend), spend, fill = type)) +
  geom_col(position = "dodge") +
  coord_flip() +
  scale_fill_manual(values = c(Current = mmm_pal("ink_muted"), Recommended = mmm_pal("primary")), name = NULL) +
  scale_y_continuous(labels = scales::label_number(scale = 1e-3, suffix = "K")) +
  labs(
    title = "Budget allocator: current vs. recommended weekly spend",
    subtitle = sprintf(
      "Expected uplift: %+.0f DKK/week (90%% CI [%.0f, %.0f]), P(beats current mix) = %.0f%%",
      comparison$expected_uplift_dkk, comparison$uplift_lower, comparison$uplift_upper, comparison$prob_beats_baseline * 100
    ),
    x = NULL, y = "Weekly spend (DKK)"
  ) +
  mmm_theme()
ggsave(here("results", "figures", "08_budget_allocation.png"), p_alloc_plot, width = 9, height = 5.5, dpi = 130)

# -----------------------------------------------------------------------------
# Campaign / weekly-plan simulator: given an arbitrary spend plan for the
# NEXT N weeks, predict revenue with uncertainty, continuing adstock
# carryover from the end of the observed series.
# -----------------------------------------------------------------------------
log_msg("Running the campaign simulator on an example 4-week plan (+20%% social_prospecting, flat elsewhere)...")
simulate_campaign <- function(spend_plan, channels, params, history_spend, beta_draws_mat, mean_revenue, control_baseline_scaled) {
  n_new <- nrow(spend_plan)
  contrib_by_draw <- sapply(channels, function(ch) {
    full_series <- c(history_spend[[ch]], spend_plan[[ch]])
    sat <- transform_media(full_series, params[[ch]]$decay, params[[ch]]$ec, params[[ch]]$shape)
    sat_new <- tail(sat, n_new)
    outer(sat_new, beta_draws_mat[, ch]) * mean_revenue # n_new x n_draws
  }, simplify = "array")
  media_total <- apply(contrib_by_draw, c(1, 2), sum) # n_new x n_draws
  total_pred <- media_total + control_baseline_scaled * mean_revenue
  tibble(
    week_ahead = seq_len(n_new),
    predicted_revenue_mean = rowMeans(total_pred),
    predicted_revenue_lower = apply(total_pred, 1, quantile, 0.05),
    predicted_revenue_upper = apply(total_pred, 1, quantile, 0.95)
  )
}

n_history <- 20 # weeks of real carryover history to seed adstock
history_spend <- as.list(tail(wt, n_history) |> select(all_of(paste0("spend_", channels))) |> rename_with(~ str_remove(., "spend_")))
avg_recent_baseline_scaled <- mean(tail(wt$revenue_dkk, 8)) / mean_revenue - mean(sapply(channels, function(ch) {
  mean(tail(transform_media(wt[[paste0("spend_", ch)]], params[[ch]]$decay, params[[ch]]$ec, params[[ch]]$shape), 8)) * mean(beta_draws_mat[, ch])
}))

example_plan <- as_tibble(setNames(lapply(channels, function(ch) rep(current_spend[[ch]] * ifelse(ch == "social_prospecting", 1.2, 1.0), 4)), channels))
campaign_result <- simulate_campaign(example_plan, channels, params, history_spend, beta_draws_mat, mean_revenue, avg_recent_baseline_scaled)
write_csv(campaign_result, here("results", "tables", "08_campaign_simulation_example.csv"))
log_msg("Example campaign simulation (4 weeks, +20%% social_prospecting):")
print(campaign_result)

# -----------------------------------------------------------------------------
# Non-media scenarios: consumer confidence -5pts, competitor promotion,
# warm vs. cold spring (temperature). Uses the "baseline" nlpar's posterior
# coefficients for the relevant controls.
# -----------------------------------------------------------------------------
log_msg("Running non-media driver scenarios...")
baseline_coef_names <- paste0("b_baseline_", mmm_control_cols())
baseline_draws <- sapply(mmm_control_cols(), function(cc) {
  nm <- paste0("b_baseline_", cc)
  if (nm %in% colnames(draws_base)) as.numeric(draws_base[, nm]) else rep(0, nrow(draws_base))
})
colnames(baseline_draws) <- mmm_control_cols()

scenario_effect <- function(control, delta) {
  # z-scored effect: revenue_scaled change = coefficient * delta (control
  # already enters the model in raw units, so this is coefficient * raw delta)
  (baseline_draws[, control] * delta) * mean_revenue
}

scenarios <- tibble(
  scenario = c("Consumer confidence -5pts", "Competitor promotion (+10 index pts pressure)", "Warm spring (+2C avg)", "Cold spring (-2C avg)"),
  weekly_revenue_impact_mean = c(
    mean(scenario_effect("consumer_confidence", -5)),
    mean(scenario_effect("cpi_index", 0)), # placeholder overwritten below (competitor proxy not in controls directly)
    mean(scenario_effect("temperature_c", 2)),
    mean(scenario_effect("temperature_c", -2))
  )
)
# competitor pressure isn't in mmm_control_cols() (it's in the simulator only,
# not fed to the model as a control -- an honest gap, noted in docs) so we
# drop that scenario row rather than report a meaningless number.
scenarios <- scenarios |> filter(scenario != "Competitor promotion (+10 index pts pressure)")
write_csv(scenarios, here("results", "tables", "08_scenarios.csv"))
log_msg("Non-media scenarios (mean weekly revenue impact):")
print(scenarios)

log_msg("Done. Wrote tables/figures with prefix 08_")
