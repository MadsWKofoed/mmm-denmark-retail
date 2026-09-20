# =============================================================================
# app/app.R
#
# Shiny dashboard for the Havehjornet MMM. Reads SAVED results only -- no
# refitting at runtime (models take minutes to fit; the app must be instant).
# Tabs: sales decomposition, channel performance, budget allocator, scenario
# simulator.
# =============================================================================

library(shiny)
library(bslib)
library(tidyverse)
library(here)
library(plotly)
library(DT)

source(here("R", "plotting.R"))

# -----------------------------------------------------------------------------
# Load saved results (all pre-computed by scripts/01-09)
# -----------------------------------------------------------------------------
load_or_null <- function(path) if (file.exists(path)) readRDS(path) else NULL
read_csv_or_null <- function(path) if (file.exists(path)) readr::read_csv(path, show_col_types = FALSE) else NULL

decomposition <- read_csv_or_null(here("results", "tables", "04a_decomposition.csv"))
ridge_roas <- read_csv_or_null(here("results", "tables", "04a_channel_roas.csv"))
bayes_roas <- read_csv_or_null(here("results", "tables", "04b_channel_roas_posterior.csv"))
platform_roas <- read_csv_or_null(here("results", "tables", "02_platform_reported_roas.csv"))
recovery <- read_csv_or_null(here("results", "tables", "05b_roas_recovery.csv"))
allocation <- read_csv_or_null(here("results", "tables", "08_budget_allocation.csv"))
optimiser_summary <- read_csv_or_null(here("results", "tables", "08_optimiser_summary.csv"))
holdout_comparison <- read_csv_or_null(here("results", "tables", "05_holdout_comparison.csv"))
scenarios <- read_csv_or_null(here("results", "tables", "08_scenarios.csv"))
weekly_table <- read_csv_or_null(here("data", "processed", "weekly_modelling_table.csv"))

ridge_model <- load_or_null(here("results", "models", "04a_ridge_model.rds"))
channels <- if (!is.null(ridge_model)) ridge_model$channels else character(0)

# -----------------------------------------------------------------------------
# UI
# -----------------------------------------------------------------------------
ui <- page_navbar(
  title = "Havehjornet MMM",
  theme = bs_theme(version = 5, bootswatch = "flatly", primary = "#2a78d6"),

  nav_panel("Sales decomposition",
    layout_columns(
      col_widths = c(12),
      card(
        card_header("Weekly revenue: baseline vs. media"),
        plotlyOutput("decomp_plot", height = "420px")
      )
    ),
    layout_columns(
      col_widths = c(6, 6),
      card(card_header("Out-of-time holdout accuracy (untouched 26 weeks)"), tableOutput("holdout_table")),
      card(card_header("Model notes"), textOutput("decomp_notes"))
    )
  ),

  nav_panel("Channel performance",
    layout_columns(
      col_widths = c(12),
      card(
        card_header("Estimated ROAS: platform-reported vs. ridge MMM vs. Bayesian MMM"),
        plotlyOutput("roas_compare_plot", height = "450px")
      )
    ),
    card(card_header("Recovery vs. ground truth (portfolio-project only -- not available with real client data)"),
         DTOutput("recovery_table"))
  ),

  nav_panel("Budget allocator",
    layout_columns(
      col_widths = c(12),
      card(
        card_header("Current vs. recommended weekly spend"),
        plotlyOutput("allocation_plot", height = "450px")
      )
    ),
    layout_columns(
      col_widths = c(4, 4, 4),
      value_box(title = "Expected weekly uplift", value = textOutput("uplift_value"), theme = "primary"),
      value_box(title = "90% interval", value = textOutput("uplift_interval"), theme = "secondary"),
      value_box(title = "P(beats current mix)", value = textOutput("prob_beat"), theme = "success")
    )
  ),

  nav_panel("Scenario simulator",
    card(
      card_header("Non-media driver scenarios: weekly revenue impact"),
      plotlyOutput("scenario_plot", height = "400px")
    ),
    card(card_header("About this tab"),
         p("Scenarios apply the fitted Bayesian model's coefficients for non-media drivers (consumer confidence, temperature) to a hypothetical shift, holding media spend fixed. Competitor pressure is a known limitation: it drives revenue in the underlying simulation, but no clean competitor-activity data was available to include as a model control -- exactly the kind of gap flagged in docs/data_request.md for a real engagement."))
  ),

  nav_spacer(),
  nav_item(tags$a("Source", href = "https://github.com/MadsWKofoed/mmm-denmark-retail", target = "_blank"))
)

# -----------------------------------------------------------------------------
# Server
# -----------------------------------------------------------------------------
server <- function(input, output, session) {

  output$decomp_plot <- renderPlotly({
    req(decomposition)
    df <- decomposition |>
      select(week_start, baseline_contrib, media_contrib) |>
      pivot_longer(-week_start, names_to = "component", values_to = "value") |>
      mutate(component = recode(component, baseline_contrib = "Baseline", media_contrib = "Media"))
    p <- ggplot(df, aes(week_start, value, fill = component)) +
      geom_area() +
      scale_fill_manual(values = c(Baseline = mmm_pal("ink_muted"), Media = mmm_pal("primary")), name = NULL) +
      scale_y_continuous(labels = scales::label_number(scale = 1e-6, suffix = "M")) +
      labs(x = NULL, y = "Revenue (DKK)") +
      mmm_theme()
    ggplotly(p)
  })

  output$holdout_table <- renderTable({ req(holdout_comparison); holdout_comparison }, digits = 1)
  output$decomp_notes <- renderText({
    "Decomposition uses the ridge/elastic-net MMM (scripts/04a). See docs/assumptions_and_limitations.md for the known media-share over-attribution issue and how the Bayesian model (with informative priors) partially corrects it."
  })

  output$roas_compare_plot <- renderPlotly({
    req(ridge_roas, bayes_roas)
    df <- bind_rows(
      ridge_roas |> transmute(channel, roas, model = "Ridge MMM"),
      bayes_roas |> transmute(channel, roas = roas_mean, model = "Bayesian MMM"),
      if (!is.null(platform_roas)) platform_roas |> filter(!is.na(platform_reported_roas)) |>
        transmute(channel, roas = platform_reported_roas, model = "Platform-reported") else NULL
    )
    p <- ggplot(df, aes(reorder(channel, roas), roas, fill = model)) +
      geom_col(position = "dodge") +
      coord_flip() +
      labs(x = NULL, y = "ROAS") +
      mmm_theme()
    ggplotly(p)
  })

  output$recovery_table <- renderDT({ req(recovery); recovery }, options = list(pageLength = 10))

  output$allocation_plot <- renderPlotly({
    req(allocation)
    df <- allocation |> select(channel, current_spend_dkk, optimal_spend_dkk) |>
      pivot_longer(-channel, names_to = "type", values_to = "spend") |>
      mutate(type = recode(type, current_spend_dkk = "Current", optimal_spend_dkk = "Recommended"))
    p <- ggplot(df, aes(reorder(channel, spend), spend, fill = type)) +
      geom_col(position = "dodge") +
      coord_flip() +
      scale_fill_manual(values = c(Current = mmm_pal("ink_muted"), Recommended = mmm_pal("primary")), name = NULL) +
      labs(x = NULL, y = "Weekly spend (DKK)") +
      mmm_theme()
    ggplotly(p)
  })

  output$uplift_value <- renderText({
    req(optimiser_summary)
    paste0(scales::comma(round(optimiser_summary$expected_uplift_dkk)), " DKK/week")
  })
  output$uplift_interval <- renderText({
    req(optimiser_summary)
    sprintf("[%s, %s]", scales::comma(round(optimiser_summary$uplift_lower_90)), scales::comma(round(optimiser_summary$uplift_upper_90)))
  })
  output$prob_beat <- renderText({
    req(optimiser_summary)
    sprintf("%.0f%%", optimiser_summary$prob_beats_current_mix * 100)
  })

  output$scenario_plot <- renderPlotly({
    req(scenarios)
    p <- ggplot(scenarios, aes(reorder(scenario, weekly_revenue_impact_mean), weekly_revenue_impact_mean)) +
      geom_col(fill = mmm_pal("primary")) +
      geom_hline(yintercept = 0, color = mmm_pal("ink_secondary")) +
      coord_flip() +
      labs(x = NULL, y = "Mean weekly revenue impact (DKK)") +
      mmm_theme()
    ggplotly(p)
  })
}

shinyApp(ui, server)
