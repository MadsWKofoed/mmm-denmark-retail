make_test_setup <- function() {
  channels <- c("a", "b", "c")
  params <- list(
    a = list(decay = 0.3, ec = 500, shape = 1.5),
    b = list(decay = 0.5, ec = 800, shape = 1.2),
    c = list(decay = 0.1, ec = 300, shape = 2.0)
  )
  set.seed(1)
  beta_draws_mat <- matrix(abs(rnorm(300 * 3, mean = c(0.05, 0.03, 0.08), sd = 0.01)), ncol = 3, byrow = TRUE)
  colnames(beta_draws_mat) <- channels
  current_spend <- c(a = 1000, b = 2000, c = 500)
  list(channels = channels, params = params, beta_draws_mat = beta_draws_mat, current_spend = current_spend, mean_revenue = 20000)
}

test_that("optimise_budget respects the total budget constraint", {
  s <- make_test_setup()
  res <- optimise_budget(s$current_spend, total_budget = sum(s$current_spend), params = s$params,
                          beta_draws_mat = s$beta_draws_mat, mean_revenue = s$mean_revenue,
                          bound_pct = 0.4, contractual_minimum_pct = 0.5)
  expect_equal(sum(res$optimal_spend), sum(s$current_spend), tolerance = 1e-3)
})

test_that("optimise_budget respects per-channel bounds", {
  s <- make_test_setup()
  res <- optimise_budget(s$current_spend, total_budget = sum(s$current_spend), params = s$params,
                          beta_draws_mat = s$beta_draws_mat, mean_revenue = s$mean_revenue,
                          bound_pct = 0.4, contractual_minimum_pct = 0.5)
  lower <- pmax(s$current_spend * 0.6, s$current_spend * 0.5)
  upper <- s$current_spend * 1.4
  expect_true(all(res$optimal_spend >= lower - 1e-6))
  expect_true(all(res$optimal_spend <= upper + 1e-6))
})

test_that("optimise_budget honours a different total budget", {
  s <- make_test_setup()
  new_budget <- sum(s$current_spend) * 1.1
  res <- optimise_budget(s$current_spend, total_budget = new_budget, params = s$params,
                          beta_draws_mat = s$beta_draws_mat, mean_revenue = s$mean_revenue,
                          bound_pct = 0.4, contractual_minimum_pct = 0.5)
  expect_equal(sum(res$optimal_spend), new_budget, tolerance = 1e-3)
})

test_that("evaluate_allocation returns one draw per posterior sample and a matching mean", {
  s <- make_test_setup()
  out <- evaluate_allocation(s$current_spend, s$params, s$beta_draws_mat, s$mean_revenue)
  expect_length(out$draws, nrow(s$beta_draws_mat))
  expect_equal(out$expected, mean(out$draws))
  expect_true(all(out$draws >= 0))
})

test_that("compare_allocations returns a coherent uplift summary", {
  s <- make_test_setup()
  bigger_spend <- s$current_spend * 1.2
  out <- compare_allocations(bigger_spend, s$current_spend, s$params, s$beta_draws_mat, s$mean_revenue)
  expect_true(out$uplift_lower <= out$expected_uplift_dkk)
  expect_true(out$expected_uplift_dkk <= out$uplift_upper)
  expect_true(out$prob_beats_baseline >= 0 && out$prob_beats_baseline <= 1)
  # More spend at positive coefficients should, on average, raise expected contribution.
  expect_gt(out$expected_uplift_dkk, 0)
})
