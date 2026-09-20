# Media transformation functions: geometric adstock and Hill saturation.
#
# These are used both by the data simulator (to build the TRUE data-generating
# process, R/simulation.R) and by the modelling code (R/models_*.R), which
# estimate decay/saturation parameters from data without ever seeing the true
# values used to simulate it.

#' Geometric adstock transformation
#'
#' Applies exponentially decaying carryover to a spend/exposure vector:
#' adstocked[t] = x[t] + decay * adstocked[t-1]
#'
#' @param x Numeric vector of weekly spend or exposure, in time order.
#' @param decay Retention rate in [0, 1). Higher = longer carryover.
#' @return Numeric vector, same length as x.
adstock_geometric <- function(x, decay) {
  stopifnot(is.numeric(x), length(decay) == 1, decay >= 0, decay < 1)
  n <- length(x)
  out <- numeric(n)
  if (n == 0) {
    return(out)
  }
  out[1] <- x[1]
  if (n > 1) {
    for (t in 2:n) {
      out[t] <- x[t] + decay * out[t - 1]
    }
  }
  out
}

#' Hill saturation transformation
#'
#' Maps adstocked spend to a diminishing-returns response in [0, 1):
#' response = x^shape / (ec^shape + x^shape)
#'
#' @param x Numeric vector of (adstocked) spend, >= 0.
#' @param ec Half-saturation point: the spend level at which response = 0.5.
#' @param shape Hill exponent controlling steepness of the S-curve.
#' @return Numeric vector in [0, 1), same length as x.
hill_saturation <- function(x, ec, shape) {
  stopifnot(is.numeric(x), ec > 0, shape > 0)
  x <- pmax(x, 0)
  x_s <- x^shape
  x_s / (ec^shape + x_s)
}

#' Combined adstock + Hill transform, the standard MMM media transform
#'
#' @param x Raw weekly spend vector.
#' @param decay Adstock retention rate.
#' @param ec Hill half-saturation point (in adstocked-spend units).
#' @param shape Hill shape parameter.
#' @return Numeric vector in [0, 1), the saturated adstocked media index.
transform_media <- function(x, decay, ec, shape) {
  hill_saturation(adstock_geometric(x, decay), ec = ec, shape = shape)
}
