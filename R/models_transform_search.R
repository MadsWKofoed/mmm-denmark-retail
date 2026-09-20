# =============================================================================
# R/models_transform_search.R
#
# Rolling-origin time-series CV and a parallel random search over adstock
# decay / Hill saturation hyperparameters, used to choose the media
# transforms for the regularised (glmnet) MMM in scripts/04a_mmm_ridge.R.
# Ground truth is NEVER read here -- only the search space bounds in
# config/model_config.yml, which are generic and not tuned to the answer.
# =============================================================================

#' Build expanding-window rolling-origin CV folds.
#'
#' @param n Number of rows (weeks) in the training data.
#' @param initial_window Minimum number of weeks in the first training fold.
#' @param step Weeks to expand the training window by, per fold.
#' @param horizon Weeks to forecast ahead in each fold's test set.
#' @return list of list(train = idx, test = idx)
rolling_origin_folds <- function(n, initial_window, step, horizon) {
  folds <- list()
  train_end <- initial_window
  while (train_end + horizon <= n) {
    folds[[length(folds) + 1]] <- list(
      train = seq_len(train_end),
      test = seq(train_end + 1, train_end + horizon)
    )
    train_end <- train_end + step
  }
  folds
}

#' Draw one random set of transform hyperparameters for all channels,
#' reproducibly (seeded per draw index so parallel workers agree).
sample_transform_draw <- function(channels, search_cfg, draw_seed) {
  set.seed(draw_seed)
  stats::setNames(lapply(channels, function(ch) {
    list(
      decay = stats::runif(1, search_cfg$decay_range[1], search_cfg$decay_range[2]),
      ec_quantile = stats::runif(1, search_cfg$ec_quantile_range[1], search_cfg$ec_quantile_range[2]),
      shape = stats::runif(1, search_cfg$shape_range[1], search_cfg$shape_range[2])
    )
  }), channels)
}

#' Resolve a draw's ec_quantile params into absolute ec values against a
#' given (training-only) spend series, to avoid leaking test-period spend
#' distribution into the transform.
resolve_draw <- function(draw, wt_train, channels) {
  stats::setNames(lapply(channels, function(ch) {
    p <- draw[[ch]]
    ec <- resolve_ec_from_quantile(wt_train[[paste0("spend_", ch)]], p$decay, p$ec_quantile)
    list(decay = p$decay, ec = max(ec, 1), shape = p$shape)
  }), channels)
}

#' Evaluate one transform draw via rolling-origin CV with a glmnet elastic
#' net fit on each fold, returning the best (min) average out-of-fold RMSE
#' across the lambda path.
#'
#' Media transforms are resolved using only the FOLD's training window (not
#' the full series), matching how this would work in production refits.
score_transform_draw <- function(draw, wt, channels, folds, alpha, n_lambda) {
  fold_rmses <- lapply(folds, function(fold) {
    wt_train <- wt[fold$train, ]
    wt_test <- wt[fold$test, ]
    params <- resolve_draw(draw, wt_train, channels)

    d_train <- build_design(wt_train, channels, params)
    d_test <- build_design(wt_test, channels, params)

    lower <- c(rep(0, length(channels)), rep(-Inf, length(mmm_control_cols())))

    fit <- tryCatch(
      glmnet::glmnet(d_train$X, d_train$y, alpha = alpha, lower.limits = lower, nlambda = n_lambda, standardize = TRUE),
      error = function(e) NULL
    )
    if (is.null(fit)) {
      return(rep(NA_real_, n_lambda))
    }

    preds <- stats::predict(fit, newx = d_test$X) # n_test x n_lambda(actual)
    rmse_per_lambda <- sqrt(colMeans((preds - d_test$y)^2))
    # pad to n_lambda for consistent matrix binding across folds (glmnet can stop early)
    length(rmse_per_lambda) <- n_lambda
    rmse_per_lambda
  })

  rmse_mat <- do.call(rbind, fold_rmses)
  avg_rmse_per_lambda <- colMeans(rmse_mat, na.rm = TRUE)
  min(avg_rmse_per_lambda, na.rm = TRUE)
}

#' Random search over transform hyperparameters, parallelised with furrr.
#' Returns a tibble of draw_id, score, plus the draws themselves as a list-column.
random_search_transforms <- function(wt_train, channels, cv_cfg, search_cfg, n_draws, alpha, n_lambda, base_seed) {
  folds <- rolling_origin_folds(nrow(wt_train), cv_cfg$initial_window_weeks, cv_cfg$step_weeks, cv_cfg$horizon_weeks)
  stopifnot(length(folds) >= 2)

  draw_seeds <- base_seed + seq_len(n_draws)
  results <- furrr::future_map(draw_seeds, function(ds) {
    draw <- sample_transform_draw(channels, search_cfg, ds)
    score <- score_transform_draw(draw, wt_train, channels, folds, alpha, n_lambda)
    list(seed = ds, score = score, draw = draw)
  }, .options = furrr::furrr_options(seed = TRUE))

  scores <- vapply(results, function(r) r$score, numeric(1))
  list(
    summary = tibble::tibble(draw_seed = draw_seeds, cv_rmse = scores) |> dplyr::arrange(cv_rmse),
    draws = results,
    n_folds = length(folds)
  )
}
