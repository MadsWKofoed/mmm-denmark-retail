# =============================================================================
# 02_eda.R
#
# Exploratory data analysis on the cleaned weekly modelling table: spend
# patterns and correlations (the collinearity traps baked into the sim --
# TV/OOH flighted together, video supporting TV), VIF, seasonal decomposition,
# stationarity tests, and platform-reported ROAS by channel (the number a
# client would show up with, to be compared against MMM-estimated
# incrementality later in 05b_recovery_study.R).
#
# Inputs:  data/processed/weekly_modelling_table.rds
# Outputs: results/figures/02_*.png, results/tables/02_*.csv
# =============================================================================

library(tidyverse)
library(here)
library(car)     # vif()
library(tseries) # adf.test
library(urca)    # ur.kpss
library(patchwork)
library(scales)

source(here("R", "plotting.R"))

dir.create(here("results", "figures"), recursive = TRUE, showWarnings = FALSE)
dir.create(here("results", "tables"), recursive = TRUE, showWarnings = FALSE)

log_msg <- function(...) cat(sprintf("[%s] ", format(Sys.time(), "%H:%M:%S")), sprintf(...), "\n")

wt <- readRDS(here("data", "processed", "weekly_modelling_table.rds"))
spend_cols <- names(wt) |> keep(~ str_starts(.x, "spend_"))
channel_names <- str_remove(spend_cols, "spend_")

# -----------------------------------------------------------------------------
# 1. Revenue over time
# -----------------------------------------------------------------------------
log_msg("Plotting revenue over time...")
p_revenue <- ggplot(wt, aes(week_start, revenue_dkk)) +
  geom_line(color = mmm_pal("primary")) +
  scale_y_continuous(labels = label_number(scale = 1e-6, suffix = "M")) +
  labs(title = "Weekly revenue", subtitle = "Havehjornet (simulated)", x = NULL, y = "Revenue (DKK)") +
  mmm_theme()
ggsave(here("results", "figures", "02_revenue_over_time.png"), p_revenue, width = 10, height = 4, dpi = 130)

# -----------------------------------------------------------------------------
# 2. Spend patterns by channel (stacked area + small multiples)
# -----------------------------------------------------------------------------
log_msg("Plotting spend patterns...")
spend_long <- wt |>
  select(week_start, all_of(spend_cols)) |>
  pivot_longer(-week_start, names_to = "channel", values_to = "spend_dkk") |>
  mutate(channel = str_remove(channel, "spend_"))

p_spend_small_multiples <- ggplot(spend_long, aes(week_start, spend_dkk)) +
  geom_area(fill = mmm_pal("primary"), alpha = 0.8) +
  facet_wrap(~channel, scales = "free_y", ncol = 3) +
  scale_y_continuous(labels = label_number(scale = 1e-3, suffix = "K")) +
  labs(title = "Weekly media spend by channel", x = NULL, y = "Spend (DKK)") +
  mmm_theme()
ggsave(here("results", "figures", "02_spend_by_channel.png"), p_spend_small_multiples, width = 11, height = 7, dpi = 130)

# -----------------------------------------------------------------------------
# 3. Correlation matrix of media spend (the TV/OOH/video collinearity trap)
# -----------------------------------------------------------------------------
log_msg("Computing spend correlation matrix...")
spend_matrix <- wt |> select(all_of(spend_cols)) |> rename_with(~ str_remove(.x, "spend_"))
cor_mat <- cor(spend_matrix)
write_csv(as_tibble(cor_mat, rownames = "channel"), here("results", "tables", "02_spend_correlation_matrix.csv"))

cor_long <- as_tibble(cor_mat, rownames = "channel_1") |>
  pivot_longer(-channel_1, names_to = "channel_2", values_to = "correlation")

p_cor <- ggplot(cor_long, aes(channel_1, channel_2, fill = correlation)) +
  geom_tile() +
  geom_text(aes(label = number(correlation, accuracy = 0.01), color = abs(correlation) > 0.6), size = 2.8, show.legend = FALSE) +
  scale_color_manual(values = c(`TRUE` = "white", `FALSE` = mmm_pal("ink_primary"))) +
  scale_fill_gradient2(low = mmm_pal("negative"), mid = "white", high = mmm_pal("primary"), midpoint = 0, limits = c(-1, 1)) +
  labs(title = "Media spend correlation matrix", subtitle = "TV/OOH flighted together and video supporting TV are the intended traps", x = NULL, y = NULL) +
  mmm_theme() +
  theme(axis.text.x = element_text(angle = 45, hjust = 1))
ggsave(here("results", "figures", "02_spend_correlation.png"), p_cor, width = 8, height = 7, dpi = 130)

log_msg("Top spend correlations (|r| > 0.3, excluding diagonal):")
top_cor <- cor_long |> filter(channel_1 < channel_2, abs(correlation) > 0.3) |> arrange(desc(abs(correlation)))
print(top_cor)

# -----------------------------------------------------------------------------
# 4. Variance Inflation Factors on raw (untransformed) spend
#    -- flags the exact multicollinearity that will make naive OLS unstable
# -----------------------------------------------------------------------------
log_msg("Computing VIF on raw spend (predicting revenue)...")
vif_formula <- as.formula(paste("revenue_dkk ~", paste(spend_cols, collapse = " + ")))
vif_model <- lm(vif_formula, data = wt)
vif_vals <- car::vif(vif_model)
vif_table <- tibble(channel = str_remove(names(vif_vals), "spend_"), vif = vif_vals) |> arrange(desc(vif))
write_csv(vif_table, here("results", "tables", "02_vif_raw_spend.csv"))
log_msg("VIF table (values > 5 indicate problematic collinearity):")
print(vif_table)

# -----------------------------------------------------------------------------
# 5. Seasonal decomposition of revenue
# -----------------------------------------------------------------------------
log_msg("Seasonal decomposition of revenue...")
rev_ts <- ts(wt$revenue_dkk, frequency = 52)
decomp <- stl(rev_ts, s.window = "periodic", robust = TRUE)
png(here("results", "figures", "02_seasonal_decomposition.png"), width = 1000, height = 800, res = 130)
plot(decomp, main = "Weekly revenue: STL decomposition")
dev.off()

# -----------------------------------------------------------------------------
# 6. Stationarity tests (ADF, KPSS) on revenue and total media spend
# -----------------------------------------------------------------------------
log_msg("Running stationarity tests...")
total_spend <- rowSums(wt |> select(all_of(spend_cols)))
stationarity <- tibble(
  series = c("revenue_dkk", "total_media_spend"),
  adf_stat = c(tseries::adf.test(wt$revenue_dkk)$statistic, tseries::adf.test(total_spend)$statistic),
  adf_p = c(tseries::adf.test(wt$revenue_dkk)$p.value, tseries::adf.test(total_spend)$p.value),
  kpss_stat = c(urca::ur.kpss(wt$revenue_dkk)@teststat, urca::ur.kpss(total_spend)@teststat)
)
write_csv(stationarity, here("results", "tables", "02_stationarity_tests.csv"))
log_msg("Stationarity results (ADF null = unit root/non-stationary; KPSS null = stationary):")
print(stationarity)

# -----------------------------------------------------------------------------
# 7. Platform-reported ROAS by channel -- the number the client's dashboards
#    would show, to be directly compared against MMM-estimated incrementality
#    later. Not adjusted for anything; this is literally last-click / spend.
# -----------------------------------------------------------------------------
log_msg("Computing platform-reported ROAS by channel...")
platform_roas <- channel_names |>
  map_dfr(function(ch) {
    spend <- sum(wt[[paste0("spend_", ch)]])
    rev_col <- paste0("platform_revenue_", ch)
    has_platform_data <- rev_col %in% names(wt) && sum(wt[[rev_col]]) > 0
    tibble(
      channel = ch,
      total_spend_dkk = spend,
      platform_reported_revenue_dkk = if (has_platform_data) sum(wt[[rev_col]]) else NA_real_,
      platform_reported_roas = if (has_platform_data) sum(wt[[rev_col]]) / spend else NA_real_,
      has_platform_attribution = has_platform_data
    )
  }) |>
  arrange(desc(platform_reported_roas))
write_csv(platform_roas, here("results", "tables", "02_platform_reported_roas.csv"))
log_msg("Platform-reported ROAS by channel (NA = no last-click attribution available, e.g. TV/OOH/print):")
print(platform_roas)

p_roas <- ggplot(platform_roas |> filter(!is.na(platform_reported_roas)),
                  aes(reorder(channel, platform_reported_roas), platform_reported_roas)) +
  geom_col(fill = mmm_pal("primary")) +
  coord_flip() +
  labs(title = "Platform-reported (last-click) ROAS by channel",
       subtitle = "Before any MMM adjustment -- compare against Section 5's incrementality-calibrated estimates",
       x = NULL, y = "Platform-reported ROAS") +
  mmm_theme()
ggsave(here("results", "figures", "02_platform_reported_roas.png"), p_roas, width = 8, height = 5, dpi = 130)

log_msg("Done. Wrote figures and tables to results/figures/ and results/tables/ (prefix 02_)")
