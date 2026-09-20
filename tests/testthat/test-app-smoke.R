test_that("the Shiny app starts without error and renders its nav panels", {
  skip_if_not_installed("shinytest2")
  skip_if_not(file.exists(here::here("app", "app.R")), "app/app.R not found")
  skip_if_not(file.exists(here::here("results", "models", "04a_ridge_model.rds")),
              "app depends on pipeline outputs that haven't been built yet")

  app <- shinytest2::AppDriver$new(here::here("app"), name = "mmm-app-smoke", height = 900, width = 1400)
  on.exit(app$stop(), add = TRUE)

  # The app should be up and its navbar title should be present in the HTML.
  html <- app$get_html("body")
  expect_true(grepl("Havehjornet MMM", html, fixed = TRUE))
})
