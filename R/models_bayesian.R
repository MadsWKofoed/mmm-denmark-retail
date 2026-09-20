# =============================================================================
# R/models_bayesian.R
#
# Helpers for the Bayesian MMM (scripts/04b_mmm_bayesian.R). The Bayesian
# model reuses the SAME media transforms (adstock decay, Hill ec/shape)
# chosen by the rolling-origin CV search in 04a -- re-estimating 27 transform
# hyperparameters simultaneously with a full Bayesian model is a much bigger
# undertaking (weakly-identified nonlinear MCMC) than a portfolio project
# needs; fixing transforms from 04a and focusing the Bayesian machinery on
# effect-size estimation, AR(1) errors, and honest posterior uncertainty is
# a common, defensible simplification, and is documented as such.
# =============================================================================

#' Build the brms model formula + priors for the Bayesian MMM.
#'
#' Response is scaled by mean training revenue so that weakly-informative
#' priors on media effects can be specified on an interpretable "share of
#' average weekly revenue at full saturation" scale, rather than needing to
#' know DKK magnitudes in advance.
#'
#' Media effects need a PER-CHANNEL non-negativity bound, which plain brms
#' linear formulas don't support (`coef=` cannot be combined with `lb=`).
#' The standard brms workaround is a nonlinear (nl=TRUE) formula where each
#' media channel gets its own nlpar (which DOES support per-parameter
#' bounds); controls stay as an ordinary linear block sharing one prior.
#'
#' @param media_cols Character vector of media column names in the design matrix.
#' @param control_cols Character vector of control column names.
#' @param bcfg The `bayesian` block from config/model_config.yml.
#' @param prior_overrides Optional named list, e.g.
#'   list(social_prospecting = list(mean = 0.09, sd = 0.02)), giving a
#'   channel-specific normal(mean, sd) [lb=0] prior instead of the shared
#'   half-normal(0, media_effect_prior_sd) -- used to fold an experiment's
#'   estimated lift in as an informative prior (scripts/07).
build_bayes_formula_priors <- function(media_cols, control_cols, bcfg, prior_overrides = list()) {
  # brms nlpar names may not contain dots or underscores -- use eff1..effN
  # and keep the channel mapping alongside for later coefficient lookup.
  #
  # A plain "+ control1 + control2" term is silently DROPPED by brms in a
  # nl=TRUE formula -- every term must belong to an nlpar. So controls are
  # wrapped into their own "baseline" nlpar, which is itself a full linear
  # sub-model (nlpar formulas aren't restricted to "~1"): this gives one
  # shared "b"-class prior across all control coefficients, as intended.
  nlpar_names <- paste0("eff", seq_along(media_cols))
  media_terms <- paste(sprintf("%s * %s", nlpar_names, media_cols), collapse = " + ")
  main_formula <- stats::as.formula(paste0("y_scaled ~ ", media_terms, " + baseline"))
  media_nlpar_formulas <- lapply(nlpar_names, function(nm) stats::as.formula(paste0(nm, " ~ 1")))
  baseline_formula <- stats::as.formula(paste0("baseline ~ 1 + ", paste(control_cols, collapse = " + ")))
  # AR(1) errors: brms >=2.20 wants autocor as its own bf() argument (a
  # one-sided formula calling ar()), not appended inside the main formula.
  bf_obj <- do.call(brms::bf, c(
    list(main_formula), media_nlpar_formulas, list(baseline_formula),
    list(nl = TRUE, autocor = ~ brms::ar(time = t, p = 1))
  ))

  # Half-normal (via lb=0) on each media nlpar -- weakly informative, NOT
  # derived from ground truth: just the generic business judgement that a
  # single channel fully saturated is unlikely to explain more than a
  # modest share of average weekly revenue.
  media_priors <- Reduce(`+`, lapply(seq_along(media_cols), function(i) {
    ov <- prior_overrides[[media_cols[i]]]
    if (is.null(ov)) {
      brms::prior_string(sprintf("normal(0, %f)", bcfg$media_effect_prior_sd), nlpar = nlpar_names[i], lb = 0)
    } else {
      brms::prior_string(sprintf("normal(%f, %f)", ov$mean, ov$sd), nlpar = nlpar_names[i], lb = 0)
    }
  }))
  control_priors <- brms::prior_string(sprintf("normal(0, %f)", bcfg$control_effect_prior_sd), class = "b", nlpar = "baseline")

  list(formula = bf_obj, prior = media_priors + control_priors, nlpar_names = nlpar_names)
}

#' Extract posterior draws of media contributions (in DKK) and ROAS by
#' channel from a fitted brms model, given the (unscaled) media design
#' matrix and the response scale factor used to fit the model.
posterior_channel_summary <- function(fit, media_matrix, spend_totals, scale_factor, prob = 0.90) {
  draws <- brms::as_draws_matrix(fit)
  media_cols <- colnames(media_matrix)
  lower <- (1 - prob) / 2
  upper <- 1 - lower

  purrr::imap_dfr(media_cols, function(ch, i) {
    beta_draws <- as.numeric(draws[, sprintf("b_eff%d_Intercept", i)])
    # total contribution (DKK) per posterior draw = sum_t(media_index_t) * beta * scale_factor
    contrib_draws <- sum(media_matrix[, ch]) * beta_draws * scale_factor
    roas_draws <- contrib_draws / spend_totals[[ch]]
    tibble::tibble(
      channel = ch,
      contribution_mean = mean(contrib_draws),
      contribution_lower = stats::quantile(contrib_draws, lower),
      contribution_upper = stats::quantile(contrib_draws, upper),
      roas_mean = mean(roas_draws),
      roas_lower = stats::quantile(roas_draws, lower),
      roas_upper = stats::quantile(roas_draws, upper)
    )
  })
}
