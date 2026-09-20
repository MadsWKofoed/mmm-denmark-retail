# =============================================================================
# R/plotting.R
#
# Shared ggplot2 theme and palette for every figure in this project (EDA,
# validation, deck, dashboard). Colors follow a validated categorical
# palette (fixed hue order, CVD-safe on adjacent pairs -- see the palette
# reference this was derived from) rather than ggplot2 defaults, kept
# consistent across every chart so the deck and dashboard read as one system.
# =============================================================================

# Fixed-order categorical palette (do not reorder or recycle across charts --
# order is the CVD-safety mechanism). Roles beyond "categorical" are named.
mmm_colors <- list(
  categorical = c("#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4",
                   "#008300", "#4a3aa7", "#e34948", "#898781"),  # 9th = muted grey "Other"
  primary = "#2a78d6",
  positive = "#1baf7a",
  negative = "#e34948",
  warning = "#eda100",
  ink_primary = "#0b0b0b",
  ink_secondary = "#52514e",
  ink_muted = "#898781",
  gridline = "#e1e0d9",
  baseline = "#c3c2b7",
  surface = "#fcfcfb",
  good = "#0ca30c",
  critical = "#d03b3b"
)

#' Retrieve a named color from the project palette.
mmm_pal <- function(role = "primary") {
  mmm_colors[[role]] %||% mmm_colors$primary
}
`%||%` <- function(a, b) if (is.null(a)) b else a

#' Fixed channel display order + colors, used everywhere a channel is a
#' categorical dimension (spend charts, contribution charts, ROAS charts).
mmm_channel_levels <- c("tv_linear", "online_video", "social_prospecting",
                         "social_retargeting", "search_brand", "search_nonbrand",
                         "programmatic_display", "ooh", "leaflets")
mmm_channel_labels <- c(
  tv_linear = "TV (linear)", online_video = "Online video",
  social_prospecting = "Social prospecting", social_retargeting = "Social retargeting",
  search_brand = "Search (brand)", search_nonbrand = "Search (non-brand)",
  programmatic_display = "Programmatic display", ooh = "Out-of-home", leaflets = "Leaflets"
)

mmm_channel_scale_color <- function() {
  ggplot2::scale_color_manual(values = setNames(mmm_colors$categorical, mmm_channel_levels),
                               labels = mmm_channel_labels, breaks = mmm_channel_levels)
}
mmm_channel_scale_fill <- function() {
  ggplot2::scale_fill_manual(values = setNames(mmm_colors$categorical, mmm_channel_levels),
                              labels = mmm_channel_labels, breaks = mmm_channel_levels)
}

#' Consistent ggplot2 theme: recessive gridlines/axes, system sans, no chart
#' junk. Used for every static figure in results/figures/.
mmm_theme <- function(base_size = 11) {
  ggplot2::theme_minimal(base_size = base_size, base_family = "") +
    ggplot2::theme(
      plot.background = ggplot2::element_rect(fill = mmm_colors$surface, color = NA),
      panel.background = ggplot2::element_rect(fill = mmm_colors$surface, color = NA),
      panel.grid.minor = ggplot2::element_blank(),
      panel.grid.major = ggplot2::element_line(color = mmm_colors$gridline, linewidth = 0.3),
      axis.line = ggplot2::element_line(color = mmm_colors$baseline, linewidth = 0.3),
      axis.text = ggplot2::element_text(color = mmm_colors$ink_muted),
      axis.title = ggplot2::element_text(color = mmm_colors$ink_secondary),
      plot.title = ggplot2::element_text(color = mmm_colors$ink_primary, face = "bold", size = ggplot2::rel(1.15)),
      plot.subtitle = ggplot2::element_text(color = mmm_colors$ink_secondary, size = ggplot2::rel(0.95)),
      legend.title = ggplot2::element_text(color = mmm_colors$ink_secondary),
      legend.text = ggplot2::element_text(color = mmm_colors$ink_secondary),
      legend.position = "bottom",
      strip.text = ggplot2::element_text(color = mmm_colors$ink_primary, face = "bold")
    )
}
