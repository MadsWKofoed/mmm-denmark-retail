# =============================================================================
# 09_refresh_backtest.R
#
# Agile refresh backtest: expanding-window monthly refits of the ridge MMM
# over the last 12 months, tracking stability of ROAS/contributions and
# one-month-ahead forecast error across refreshes. This is the "always-on
# MMM" pattern real Nordic MMM operations run -- a model that's refit
# regularly as new weeks of data arrive, not fit once and left alone.
#
# Uses the ridge (glmnet) model only, not the Bayesian model -- refitting
# brms 12+ times sequentially (cores=1, per this machine's sandbox
# limitation) would take well over an hour; the ridge model captures the
# same qualitative stability story much faster and is the right tool for
# a monthly-cadence operational backtest anyway.
#
# Inputs:  data/processed/weekly_modelling_table.rds, config/model_config.yml
# Outputs: results/tables/09_*.csv, results/figures/09_*.png
# =============================================================================

library(tidyverse)
library(here)
library(yaml)
library(glmnet)

source(here("R", "transformations.R"))
source(here("R", "model_design.R"))
source(here("R", "models_transform_search.R"))
source(here("R", "plotting.R"))

log <- function(...) cat(sprintf("[%s] ", format(Sys.time(), "%H:%M:%S")), sprintf(...), "\n")

quick <- Sys.getenv("MMM_QUICK", "0") == "1"
mcfg <- read_yaml(here("config", "model_config.yml"))
channels <- mcfg$media_channels
dir.create(here("results", "tables"), recursive = TRUE, showWarnings = FALSE)
dir.create(here("results", "figures"), recursive = TRUE, showWarnings = FALSE)

wt <- readRDS(here("data", "processed", "weekly_modelling_table.rds")) |> add_time_features()
n_total <- nrow(wt)

# 12 monthly refresh points over the last 12 months (~4.33 weeks/month),
# each an EXPANDING window: refit uses everything up to that point, then
# forecasts the following 4 weeks (roughly "next month").
n_refreshes <- if (quick) 3 else 12
step_weeks <- 4
last_refresh_end <- n_total - step_weeks  # last refresh must leave room to forecast
refresh_ends <- round(seq(last_refresh_end - (n_refreshes - 1) * step_weeks, last_refresh_end, by = step_weeks))
refresh_ends <- refresh_ends[refresh_ends > 100]  # need enough history to fit at all

log("Running %d monthly expanding-window refreshes (forecasting %d weeks ahead each time)...", length(refresh_ends), step_weeks)

n_draws_refresh <- if (quick) 15 else 60  # smaller than 04a's full search -- this runs many times
cv_cfg <- mcfg$cv$quick  # keep each refresh's own internal CV light; this script's expense is in the NUMBER of refreshes, not each one's depth

refresh_results <- map_dfr(seq_along(refresh_ends), function(i) {
  end_idx <- refresh_ends[i]
  wt_upto <- wt[seq_len(end_idx), ]
  wt_next <- wt[seq(end_idx + 1, min(end_idx + step_weeks, n_total)), ]

  search <- random_search_transforms(wt_upto, channels, cv_cfg, mcfg$transform_search, n_draws_refresh,
                                      alpha = mcfg$glmnet$alpha, n_lambda = 50, base_seed = mcfg$seed + i * 1000)
  best_draw <- search$draws[[which.min(sapply(search$draws, `[[`, "score"))]]$draw
  params <- resolve_draw(best_draw, wt_upto, channels)

  d_fit <- build_design(wt_upto, channels, params)
  lower <- c(rep(0, length(channels)), rep(-Inf, length(mmm_control_cols())))
  cvfit <- tryCatch(cv.glmnet(d_fit$X, d_fit$y, alpha = mcfg$glmnet$alpha, lower.limits = lower, nfolds = 5, standardize = TRUE),
                     error = function(e) NULL)
  if (is.null(cvfit)) return(NULL)
  fit <- glmnet(d_fit$X, d_fit$y, alpha = mcfg$glmnet$alpha, lower.limits = lower, lambda = cvfit$lambda.1se, standardize = TRUE)

  coefs <- as.matrix(coef(fit))[channels, 1]
  media_mat <- build_media_matrix(wt_upto, channels, params)
  contrib <- sweep(media_mat, 2, coefs, `*`)
  roas <- map_dfr(channels, function(ch) {
    tibble(channel = ch, roas = sum(contrib[, ch]) / sum(wt_upto[[paste0("spend_", ch)]]))
  })

  # Forecast next step_weeks (carryover-safe: build media on wt (full) then slice)
  fc_metrics <- NULL
  if (nrow(wt_next) > 0) {
    full_media <- build_media_matrix_full_then_split(wt, channels, params, seq_len(end_idx), seq(end_idx + 1, min(end_idx + step_weeks, n_total)))
    X_next <- cbind(full_media$test, as.matrix(wt_next[, mmm_control_cols()]))
    pred_next <- as.numeric(predict(fit, newx = X_next))
    fc_metrics <- tibble(
      mape_pct = mean(abs((wt_next$revenue_dkk - pred_next) / wt_next$revenue_dkk)) * 100,
      rmse = sqrt(mean((wt_next$revenue_dkk - pred_next)^2))
    )
  }

  tibble(
    refresh = i, refresh_date = wt_upto$week_start[end_idx], n_train_weeks = end_idx,
    roas |> pivot_wider(names_from = channel, values_from = roas, names_prefix = "roas_"),
    next_period_mape_pct = if (!is.null(fc_metrics)) fc_metrics$mape_pct else NA_real_,
    next_period_rmse = if (!is.null(fc_metrics)) fc_metrics$rmse else NA_real_
  )
})

write_csv(refresh_results, here("results", "tables", "09_refresh_backtest.csv"))

# -----------------------------------------------------------------------------
# Stability plot: ROAS by channel across refreshes
# -----------------------------------------------------------------------------
roas_long <- refresh_results |>
  select(refresh_date, starts_with("roas_")) |>
  pivot_longer(-refresh_date, names_to = "channel", values_to = "roas") |>
  mutate(channel = str_remove(channel, "roas_"))

p_stability <- ggplot(roas_long, aes(refresh_date, roas, color = channel)) +
  geom_line(linewidth = 0.7) +
  geom_point(size = 1.5) +
  mmm_channel_scale_color() +
  labs(title = "Agile refresh backtest: ROAS stability across monthly refits",
       subtitle = "Expanding window, ridge/elastic-net MMM refit each period",
       x = NULL, y = "Estimated ROAS") +
  mmm_theme()
ggsave(here("results", "figures", "09_roas_stability.png"), p_stability, width = 10, height = 6, dpi = 130)

p_forecast_err <- ggplot(refresh_results, aes(refresh_date, next_period_mape_pct)) +
  geom_col(fill = mmm_pal("primary")) +
  labs(title = "Agile refresh backtest: next-period forecast error", x = NULL, y = "MAPE (%) forecasting the next period") +
  mmm_theme()
ggsave(here("results", "figures", "09_forecast_error_over_time.png"), p_forecast_err, width = 9, height = 5, dpi = 130)

log("Refresh backtest summary: mean next-period MAPE=%.1f%%, ROAS coefficient of variation by channel:",
    mean(refresh_results$next_period_mape_pct, na.rm = TRUE))
cv_by_channel <- roas_long |> group_by(channel) |> summarise(mean_roas = mean(roas), cv = sd(roas) / mean(roas), .groups = "drop") |> arrange(desc(cv))
write_csv(cv_by_channel, here("results", "tables", "09_roas_stability_summary.csv"))
print(cv_by_channel)

log("Done. Wrote tables/figures with prefix 09_")
