test_that("adstock_geometric with decay 0 returns the input unchanged", {
  x <- c(10, 20, 0, 5, 15)
  expect_equal(adstock_geometric(x, decay = 0), x)
})

test_that("adstock_geometric carries over spend correctly", {
  x <- c(100, 0, 0, 0)
  out <- adstock_geometric(x, decay = 0.5)
  expect_equal(out, c(100, 50, 25, 12.5))
})

test_that("adstock_geometric preserves length and is non-negative for non-negative input", {
  x <- c(5, 0, 10, 2, 0, 7)
  out <- adstock_geometric(x, decay = 0.3)
  expect_length(out, length(x))
  expect_true(all(out >= 0))
})

test_that("adstock_geometric rejects invalid decay", {
  expect_error(adstock_geometric(c(1, 2), decay = 1))
  expect_error(adstock_geometric(c(1, 2), decay = -0.1))
})

test_that("hill_saturation is 0.5 at the half-saturation point", {
  expect_equal(hill_saturation(100, ec = 100, shape = 2), 0.5)
})

test_that("hill_saturation is monotonically increasing in x", {
  x <- seq(0, 1000, length.out = 50)
  y <- hill_saturation(x, ec = 200, shape = 1.5)
  expect_true(all(diff(y) >= 0))
})

test_that("hill_saturation is bounded in [0, 1)", {
  y <- hill_saturation(c(0, 1, 100, 1e6), ec = 200, shape = 1.5)
  expect_true(all(y >= 0 & y < 1))
})

test_that("hill_saturation at x = 0 is 0", {
  expect_equal(hill_saturation(0, ec = 50, shape = 2), 0)
})

test_that("transform_media composes adstock then Hill and stays in [0, 1)", {
  x <- c(0, 100, 200, 50, 0, 300)
  out <- transform_media(x, decay = 0.4, ec = 150, shape = 1.5)
  expect_length(out, length(x))
  expect_true(all(out >= 0 & out < 1))
})
