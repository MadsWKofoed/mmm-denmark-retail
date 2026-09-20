# =============================================================================
# 00b_simulate_ground_truth.R
#
# Builds the TRUE (hidden) weekly revenue + media series using
# config/ground_truth.yml and the real external data fetched in 00a. Saves
# results to data/processed/_truth/ -- this folder is only ever read by
# scripts/05b_recovery_study.R. Every other script must pretend it does not
# exist.
# =============================================================================

library(tidyverse)
library(here)
library(yaml)

source(here("R", "transformations.R"))
source(here("R", "danish_calendar.R"))
source(here("R", "simulation.R"))

cfg <- read_yaml(here("config", "ground_truth.yml"))

weather_weekly <- read_csv(here("data", "external", "weather_weekly.csv"), show_col_types = FALSE)
consumer_confidence <- read_csv(here("data", "external", "consumer_confidence_monthly.csv"), show_col_types = FALSE)
cpi_monthly <- read_csv(here("data", "external", "cpi_monthly.csv"), show_col_types = FALSE)

set.seed(cfg$seed)
truth <- simulate_ground_truth(cfg, weather_weekly, consumer_confidence, cpi_monthly)

dir.create(here("data", "processed", "_truth"), recursive = TRUE, showWarnings = FALSE)
saveRDS(truth$weekly_truth, here("data", "processed", "_truth", "weekly_truth.rds"))
saveRDS(truth$media_spend, here("data", "processed", "_truth", "media_spend_truth.rds"))
saveRDS(truth$holidays, here("data", "processed", "_truth", "holidays.rds"))
saveRDS(cfg, here("data", "processed", "_truth", "ground_truth_config_snapshot.rds"))

# --- sanity checks / summary, printed for a human to eyeball ---
wt <- truth$weekly_truth
cat("n weeks:", nrow(wt), "\n")
cat("revenue range:", round(min(wt$revenue_dkk)), "-", round(max(wt$revenue_dkk)), "\n")
cat("mean weekly revenue:", round(mean(wt$revenue_dkk)), "\n")
cat("mean weekly baseline:", round(mean(wt$baseline_dkk)), "\n")
cat("media share of revenue:", round(mean(wt$total_media_contrib_dkk / wt$revenue_dkk) * 100, 1), "%\n")
cat("any negative revenue:", any(wt$revenue_dkk < 0), "\n")
cat("any NA in weekly_truth:", any(is.na(wt)), "\n")

ms <- truth$media_spend
cat("\nmedia spend summary (weekly mean DKK):\n")
print(ms |> select(-week_start) |> summarise(across(everything(), mean)) |> pivot_longer(everything()) |>
  arrange(desc(value)))

cat("\nimplied short-run ROAS by channel (true contribution / true spend):\n")
channel_names <- names(cfg$media_channels)
roas_check <- map_dfr(channel_names, function(ch) {
  tibble(
    channel = ch,
    true_spend = sum(ms[[ch]]),
    true_contrib = sum(wt[[paste0("true_contrib_", ch)]]),
    implied_roas = true_contrib / true_spend
  )
})
print(roas_check)

cat("\nTotal true media spend:", round(sum(select(ms, -week_start))), "DKK\n")
cat("Total revenue:", round(sum(wt$revenue_dkk)), "DKK\n")

ggsave(
  here("results", "figures", "_truth_check_revenue.png"),
  ggplot(wt, aes(week_start, revenue_dkk)) +
    geom_line() +
    labs(title = "TRUE simulated weekly revenue (sanity check)", x = NULL, y = "Revenue (DKK)") +
    theme_minimal(),
  width = 10, height = 4, dpi = 120
)

cat("\nDone. Wrote data/processed/_truth/*.rds and results/figures/_truth_check_revenue.png\n")
