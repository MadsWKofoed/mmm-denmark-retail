# =============================================================================
# 05b_recovery_study.R
#
# THE ONLY script (besides 00b/00c which build it) allowed to read
# data/processed/_truth/. Compares the ridge (04a) and Bayesian (04b) MMM
# estimates -- ROAS, decay, saturation -- against the known ground truth,
# and reports HONESTLY where and why each model fails. No result here was
# used to tune scripts 01-04; this is a pure post-hoc check.
#
# Inputs:  results/models/04a_ridge_model.rds, results/models/04b_bayesian_model.rds,
#          results/tables/04a_channel_roas.csv, results/tables/04b_channel_roas_posterior.csv,
#          data/processed/_truth/ground_truth_config_snapshot.rds
# Outputs: results/tables/05b_*.csv, results/figures/05b_*.png
# =============================================================================

library(tidyverse)
library(here)

source(here("R", "plotting.R"))

log_msg <- function(...) cat(sprintf("[%s] ", format(Sys.time(), "%H:%M:%S")), sprintf(...), "\n")

dir.create(here("results", "tables"), recursive = TRUE, showWarnings = FALSE)
dir.create(here("results", "figures"), recursive = TRUE, showWarnings = FALSE)

truth_cfg <- readRDS(here("data", "processed", "_truth", "ground_truth_config_snapshot.rds"))
ridge_model <- readRDS(here("results", "models", "04a_ridge_model.rds"))
bayes_model <- readRDS(here("results", "models", "04b_bayesian_model.rds"))

ridge_roas <- read_csv(here("results", "tables", "04a_channel_roas.csv"), show_col_types = FALSE)
bayes_roas <- read_csv(here("results", "tables", "04b_channel_roas_posterior.csv"), show_col_types = FALSE)

channels <- ridge_model$channels

# -----------------------------------------------------------------------------
# True ROAS, decay, saturation from the ground truth config snapshot
# -----------------------------------------------------------------------------
truth_table <- map_dfr(channels, function(ch) {
  cc <- truth_cfg$media_channels[[ch]]
  tibble(
    channel = ch, true_roas = cc$target_short_run_roas,
    true_decay = cc$adstock_decay, true_shape = cc$hill_shape,
    true_ec_dkk = cc$hill_ec,
    known_endogenous = !is.null(cc$endogenous_driver) || !is.null(cc$platform_reported_roas_inflation),
    collinear_with = ifelse(is.null(cc$correlated_with), NA_character_, paste(cc$correlated_with, collapse = ","))
  )
})

# -----------------------------------------------------------------------------
# ROAS recovery: true vs ridge vs Bayesian
# -----------------------------------------------------------------------------
recovery <- truth_table |>
  left_join(ridge_roas |> select(channel, ridge_roas = roas), by = "channel") |>
  left_join(bayes_roas |> select(channel, bayes_roas = roas_mean, bayes_roas_lower = roas_lower, bayes_roas_upper = roas_upper), by = "channel") |>
  mutate(
    ridge_abs_error = abs(ridge_roas - true_roas),
    bayes_abs_error = abs(bayes_roas - true_roas),
    bayes_true_covered_90pct_ci = true_roas >= bayes_roas_lower & true_roas <= bayes_roas_upper,
    bayes_improves_on_ridge = bayes_abs_error < ridge_abs_error
  ) |>
  arrange(desc(ridge_abs_error))

write_csv(recovery, here("results", "tables", "05b_roas_recovery.csv"))
log_msg("ROAS recovery vs ground truth:")
print(recovery |> select(channel, true_roas, ridge_roas, bayes_roas, known_endogenous, bayes_true_covered_90pct_ci))

log_msg(
  "Bayesian model's 90%% credible interval contains the true ROAS for %d of %d channels.",
  sum(recovery$bayes_true_covered_90pct_ci), nrow(recovery)
)
log_msg(
  "Bayesian estimate closer to truth than ridge point estimate for %d of %d channels.",
  sum(recovery$bayes_improves_on_ridge), nrow(recovery)
)

# -----------------------------------------------------------------------------
# Decay/shape recovery (ridge model's chosen transform only -- the Bayesian
# model reused these same transforms, so there is nothing separate to check
# there; this itself is a limitation worth stating plainly)
# -----------------------------------------------------------------------------
decay_recovery <- truth_table |>
  left_join(map_dfr(channels, function(ch) {
    tibble(
      channel = ch, estimated_decay = ridge_model$params[[ch]]$decay,
      estimated_shape = ridge_model$params[[ch]]$shape,
      estimated_ec_dkk = ridge_model$params[[ch]]$ec
    )
  }), by = "channel") |>
  mutate(decay_error = estimated_decay - true_decay, shape_error = estimated_shape - true_shape)
write_csv(decay_recovery, here("results", "tables", "05b_transform_recovery.csv"))
log_msg("Adstock decay / Hill shape recovery (chosen by rolling-origin CV, never touching ground truth):")
print(decay_recovery |> select(channel, true_decay, estimated_decay, true_shape, estimated_shape))

# -----------------------------------------------------------------------------
# Honest failure analysis: connect errors to the KNOWN confounders
# -----------------------------------------------------------------------------
failure_notes <- recovery |>
  mutate(likely_reason = case_when(
    channel %in% c("tv_linear", "ooh") ~ "TV/OOH collinearity (r=0.89 in spend, both flighted together) -- credit is hard to split between them even though both have genuinely positive effects.",
    channel == "search_brand" ~ "Endogeneity: spend follows brand demand that TV itself creates, with a 1-week lag -- classic reverse-causality trap. Needs an experiment or instrument to fix, not just better regularisation.",
    channel == "social_retargeting" ~ "Endogeneity: spend follows a site-traffic proxy correlated with revenue's own seasonal level. This is the channel scripts/07's geo experiment is specifically designed to calibrate.",
    channel == "search_nonbrand" ~ "Spend follows seasonal category demand, correlated with revenue's own seasonality -- partially separable via controls, but not fully.",
    channel == "leaflets" ~ "Large, genuinely important true driver with naturally seasonal execution -- high correlation with revenue here is mostly real signal, not confounding.",
    TRUE ~ "Reasonably well-identified: flighting pattern is close to independent of revenue's own seasonal shape."
  ))
write_csv(
  failure_notes |> select(channel, ridge_abs_error, bayes_abs_error, known_endogenous, likely_reason),
  here("results", "tables", "05b_failure_analysis.csv")
)

# -----------------------------------------------------------------------------
# Figure: true vs estimated ROAS, ridge and Bayesian
# -----------------------------------------------------------------------------
plot_df <- recovery |>
  select(channel, true_roas, ridge_roas, bayes_roas, bayes_roas_lower, bayes_roas_upper) |>
  pivot_longer(c(ridge_roas, bayes_roas), names_to = "model", values_to = "estimated_roas") |>
  mutate(model = recode(model, ridge_roas = "Ridge/elastic-net", bayes_roas = "Bayesian"))

p_recovery <- ggplot(plot_df, aes(true_roas, estimated_roas, color = model)) +
  geom_abline(slope = 1, intercept = 0, linetype = "dashed", color = mmm_pal("ink_secondary")) +
  geom_point(size = 3, alpha = 0.85) +
  ggrepel::geom_text_repel(aes(label = channel), size = 2.8, show.legend = FALSE, max.overlaps = 20) +
  scale_color_manual(values = c(`Ridge/elastic-net` = mmm_pal("warning"), Bayesian = mmm_pal("primary")), name = NULL) +
  labs(
    title = "ROAS recovery: estimated vs. true", subtitle = "Dashed line = perfect recovery. Points near the line are well-identified; points far above it are over-attributed.",
    x = "True ROAS (ground truth)", y = "Estimated ROAS"
  ) +
  mmm_theme()
ggsave(here("results", "figures", "05b_roas_recovery.png"), p_recovery, width = 9, height = 6.5, dpi = 130)

log_msg("Done. Wrote tables/figures with prefix 05b_. This is the honest scorecard for the whole MMM in this project.")
