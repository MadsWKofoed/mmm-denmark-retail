# =============================================================================
# R/optimisation.R
#
# Budget allocator and scenario/campaign simulator helpers, built on the
# Bayesian MMM's posterior draws (uncertainty-aware) using the SAME adstock
# decay / Hill ec / shape transforms chosen in 04a. Steady-state adstock
# (spend / (1 - decay)) is used for the budget allocator, the standard MMM
# simplification for "if we sustained this weekly spend indefinitely" --
# appropriate for allocating an ongoing weekly budget, not a one-off burst.
# =============================================================================

#' Steady-state contribution for one channel at a given weekly spend level,
#' for every posterior draw of that channel's effect coefficient.
#'
#' @param spend Single weekly spend level (DKK).
#' @param decay,ec,shape Channel's chosen adstock/Hill parameters.
#' @param beta_draws Numeric vector of posterior draws for the channel's nlpar coefficient.
#' @param mean_revenue Scale factor (mean training revenue) linking the nlpar's
#'   y_scaled units back to DKK.
#' @return Numeric vector, one predicted DKK contribution per posterior draw.
steady_state_contribution_draws <- function(spend, decay, ec, shape, beta_draws, mean_revenue) {
  steady_state_adstock <- spend / (1 - decay)
  sat <- hill_saturation(steady_state_adstock, ec = ec, shape = shape)
  beta_draws * sat * mean_revenue
}

#' Expected (posterior-mean) total revenue contribution across all channels
#' at a given spend allocation, plus optionally the full draw-level totals.
#'
#' @param spend_vec Named numeric vector, weekly spend per channel.
#' @param params List of per-channel list(decay, ec, shape) (from 04a).
#' @param beta_draws_mat Matrix, posterior draws x channels (columns named by channel).
#' @param mean_revenue Scale factor.
#' @return list(expected = scalar, draws = numeric vector of total contribution per draw)
evaluate_allocation <- function(spend_vec, params, beta_draws_mat, mean_revenue) {
  channels <- names(spend_vec)
  contrib_draws <- sapply(channels, function(ch) {
    p <- params[[ch]]
    steady_state_contribution_draws(spend_vec[[ch]], p$decay, p$ec, p$shape, beta_draws_mat[, ch], mean_revenue)
  })
  total_draws <- rowSums(contrib_draws)
  list(expected = mean(total_draws), draws = total_draws)
}

#' Optimise a fixed total budget across channels to maximise expected
#' (posterior-mean) revenue contribution, subject to per-channel bounds and
#' a contractual minimum, using nloptr's SLSQP.
#'
#' @param current_spend Named numeric vector, current weekly spend per channel.
#' @param total_budget Total weekly budget to allocate (defaults to sum(current_spend)).
#' @param params,beta_draws_mat,mean_revenue As in evaluate_allocation().
#' @param bound_pct,contractual_minimum_pct From config$optimiser.
optimise_budget <- function(current_spend, total_budget = sum(current_spend), params, beta_draws_mat,
                            mean_revenue, bound_pct = 0.4, contractual_minimum_pct = 0.5) {
  channels <- names(current_spend)
  n <- length(channels)
  beta_mean <- colMeans(beta_draws_mat)[channels]

  objective <- function(x) {
    names(x) <- channels
    -evaluate_allocation(x, params, beta_draws_mat, mean_revenue)$expected
  }
  eq_constraint <- function(x) sum(x) - total_budget

  lower <- pmax(current_spend * (1 - bound_pct), current_spend * contractual_minimum_pct)
  upper <- current_spend * (1 + bound_pct)
  # Rescale the starting point / bounds if the budget differs materially
  # from current total spend, so the equality constraint is feasible.
  scale <- total_budget / sum(current_spend)
  x0 <- pmin(pmax(current_spend * scale, lower), upper)

  res <- nloptr::slsqp(
    x0 = x0, fn = objective, lower = lower, upper = upper, heq = eq_constraint,
    control = list(xtol_rel = 1e-8, maxeval = 2000)
  )

  optimal_spend <- stats::setNames(res$par, channels)
  list(optimal_spend = optimal_spend, converged = res$convergence >= 0, message = res$message)
}

#' Compare two allocations (e.g. optimal vs. current) across the full
#' posterior, returning expected uplift, a 90% interval, and the posterior
#' probability that the new allocation beats the baseline.
compare_allocations <- function(new_spend, baseline_spend, params, beta_draws_mat, mean_revenue, prob = 0.90) {
  new_eval <- evaluate_allocation(new_spend, params, beta_draws_mat, mean_revenue)
  base_eval <- evaluate_allocation(baseline_spend, params, beta_draws_mat, mean_revenue)
  uplift_draws <- new_eval$draws - base_eval$draws
  lower <- (1 - prob) / 2
  upper <- 1 - lower
  list(
    expected_uplift_dkk = mean(uplift_draws),
    uplift_lower = stats::quantile(uplift_draws, lower),
    uplift_upper = stats::quantile(uplift_draws, upper),
    prob_beats_baseline = mean(uplift_draws > 0)
  )
}
