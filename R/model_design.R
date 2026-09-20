# =============================================================================
# R/model_design.R
#
# Shared design-matrix construction for the regularised MMM (04a), Bayesian
# MMM (04b), and validation/recovery scripts. Keeps the control-variable set
# and time-feature construction identical across every model that's compared.
# =============================================================================

#' Add trend + Fourier seasonality features to a weekly table (matches the
#' construction used in 03_baselines.R, factored out here for reuse).
add_time_features <- function(wt) {
  wt |>
    dplyr::mutate(
      t = dplyr::row_number(),
      fourier_sin1 = sin(2 * pi * t / 52.18), fourier_cos1 = cos(2 * pi * t / 52.18),
      fourier_sin2 = sin(4 * pi * t / 52.18), fourier_cos2 = cos(4 * pi * t / 52.18)
    )
}

#' The fixed set of non-media control columns used by every MMM in this
#' project (must exist in the weekly table after add_time_features()).
mmm_control_cols <- function() {
  c(
    "t", "fourier_sin1", "fourier_cos1", "fourier_sin2", "fourier_cos2",
    "promo_depth_pct", "temperature_c", "precipitation_mm", "consumer_confidence",
    "cpi_index", "n_stores", "is_easter_week", "is_ascension_week",
    "is_whitmonday_week", "is_great_prayer_week", "is_christmas_week"
  )
}

#' Transform every media channel's raw weekly spend into a saturated-adstock
#' index in [0, 1) using per-channel parameters, and return it as a matrix
#' (columns named by channel, in the order given).
#'
#' @param wt Weekly table (must have spend_<channel> columns).
#' @param channels Character vector of channel names (without "spend_" prefix).
#' @param params Named list, one element per channel, each list(decay, ec, shape).
#'   `ec` here is an ABSOLUTE value (already resolved from a quantile if that's
#'   how it was searched -- see resolve_ec_from_quantile()).
build_media_matrix <- function(wt, channels, params) {
  mat <- sapply(channels, function(ch) {
    x <- wt[[paste0("spend_", ch)]]
    p <- params[[ch]]
    transform_media(x, decay = p$decay, ec = p$ec, shape = p$shape)
  })
  colnames(mat) <- channels
  mat
}

#' Resolve an ec_quantile (0-1, searched hyperparameter) into an absolute ec
#' value in adstocked-spend units for one channel, given its raw spend.
resolve_ec_from_quantile <- function(spend, decay, ec_quantile) {
  adstocked <- adstock_geometric(spend, decay)
  as.numeric(stats::quantile(adstocked[adstocked > 0], ec_quantile, na.rm = TRUE))
}

#' Build the media matrix for a FULL weekly table (spanning training +
#' holdout), then split by row index -- this preserves adstock carryover
#' across the train/holdout boundary (adstock_geometric() is a recursive
#' filter; transforming the holdout rows alone would incorrectly reset
#' carryover to zero at the holdout's first week, biasing early-holdout
#' predictions downward). Always use this, never build_media_matrix()
#' directly, when a holdout period follows the training period in time.
build_media_matrix_full_then_split <- function(wt_full, channels, params, train_idx, test_idx) {
  mat_full <- build_media_matrix(wt_full, channels, params)
  list(train = mat_full[train_idx, , drop = FALSE], test = mat_full[test_idx, , drop = FALSE])
}

#' Build the full design matrix (media + controls) and response vector for a
#' weekly table + a resolved parameter set (ec already absolute, not quantile).
build_design <- function(wt, channels, params) {
  media_mat <- build_media_matrix(wt, channels, params)
  control_mat <- as.matrix(wt[, mmm_control_cols()])
  X <- cbind(media_mat, control_mat)
  y <- wt$revenue_dkk
  list(X = X, y = y, media_cols = channels, control_cols = mmm_control_cols())
}
