# =============================================================================
# 10_build_excel_workbook.R
#
# Builds the client-facing Excel workbook: contributions, ROAS (platform-
# reported, ridge, Bayesian, geo-calibrated), response curves, and
# scenarios. Every number is read from results/ -- nothing hand-typed.
#
# Inputs:  results/tables/*.csv
# Outputs: results/havehjornet_mmm_results.xlsx
# =============================================================================

library(tidyverse)
library(here)
library(openxlsx)

log_msg <- function(...) cat(sprintf("[%s] ", format(Sys.time(), "%H:%M:%S")), sprintf(...), "\n")

read_or_empty <- function(path, ...) {
  if (file.exists(path)) read_csv(path, show_col_types = FALSE, ...) else tibble()
}

t <- here("results", "tables")

roas_summary <- read_or_empty(file.path(t, "04a_channel_roas.csv")) |>
  select(channel, ridge_roas = roas, ridge_spend = total_spend_dkk, ridge_contribution = total_contribution_dkk)

bayes_summary <- read_or_empty(file.path(t, "04b_channel_roas_posterior.csv")) |>
  select(channel,
    bayes_roas_mean = roas_mean, bayes_roas_lower = roas_lower, bayes_roas_upper = roas_upper,
    bayes_contribution_mean = contribution_mean
  )

platform_summary <- read_or_empty(file.path(t, "02_platform_reported_roas.csv")) |>
  select(channel, platform_reported_roas)

calibration <- read_or_empty(file.path(t, "07_calibration_comparison.csv"))

roas_sheet <- roas_summary |>
  full_join(bayes_summary, by = "channel") |>
  full_join(platform_summary, by = "channel") |>
  arrange(desc(bayes_roas_mean))

decomposition_sheet <- read_or_empty(file.path(t, "04a_decomposition.csv"))
response_curves_sheet <- read_or_empty(file.path(t, "04a_response_curves.csv"))
recovery_sheet <- read_or_empty(file.path(t, "05b_roas_recovery.csv"))
scenarios_sheet <- read_or_empty(file.path(t, "08_scenarios.csv"))
allocation_sheet <- read_or_empty(file.path(t, "08_budget_allocation.csv"))
holdout_sheet <- read_or_empty(file.path(t, "05_holdout_comparison.csv"))
geo_experiment_sheet <- read_or_empty(file.path(t, "07_did_summary.csv"))

wb <- createWorkbook()
header_style <- createStyle(textDecoration = "bold", fgFill = "#2a78d6", fontColour = "white")

add_sheet <- function(wb, name, df) {
  addWorksheet(wb, name)
  writeData(wb, name, df, headerStyle = header_style)
  setColWidths(wb, name, cols = seq_len(max(1, ncol(df))), widths = "auto")
  freezePane(wb, name, firstRow = TRUE)
}

add_sheet(wb, "ROAS summary", roas_sheet)
add_sheet(wb, "Decomposition (weekly)", decomposition_sheet)
add_sheet(wb, "Response curves", response_curves_sheet)
add_sheet(wb, "Recovery vs truth", recovery_sheet)
add_sheet(wb, "Budget allocation", allocation_sheet)
add_sheet(wb, "Scenarios", scenarios_sheet)
add_sheet(wb, "Holdout accuracy", holdout_sheet)
add_sheet(wb, "Geo experiment", geo_experiment_sheet)
if (nrow(calibration) > 0) add_sheet(wb, "Geo calibration", calibration)

dir.create(here("results"), showWarnings = FALSE)
saveWorkbook(wb, here("results", "havehjornet_mmm_results.xlsx"), overwrite = TRUE)
log_msg("Done. Wrote results/havehjornet_mmm_results.xlsx (%d sheets)", length(wb$sheet_names))
