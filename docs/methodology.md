# Methodology (plain language)

This document explains the modelling approach in this project without assuming a statistics
background. See `docs/assumptions_and_limitations.md` for a companion list of what NOT to trust
from this project, and `docs/interview_qa.md` for specific Q&A grounded in the actual results.

## The core idea: separating "would have happened anyway" from "marketing caused it"

Revenue moves every week for lots of reasons that have nothing to do with this week's marketing
spend: the season (Danes buy garden furniture in spring, not January), holidays, the weather,
prices, promotions, how many stores are open, and the general state of consumer confidence. A
Marketing Mix Model's job is to explain revenue using ALL of these factors at once, so that
whatever's left over and attributable to media spend is a genuine estimate of media's effect, not
just "media spend happened to be high in a month when revenue was also high for unrelated reasons."

## Two effects specific to media, modelled explicitly

- **Carryover (adstock):** an ad seen this week can still influence a purchase next week or the
  week after. Modelled as geometric decay: each week, a fraction of last week's "ad effect" carries
  into this week.
- **Diminishing returns (saturation):** the first krone spent on a channel each week is more
  effective than the millionth. Modelled with a Hill (S-curve) function: effect rises with spend,
  then flattens out.

Both are applied per channel with their own decay rate and saturation curve, since TV behaves very
differently from paid search.

## Three ways this project tried to estimate the model, in order of what they get right

1. **Naive baselines** (script 03): a seasonal repeat-last-year forecast, a model with no media at
   all, and a plain linear regression of revenue on raw (untransformed) spend. All are diagnosed
   with standard econometric tests. The plain regression is included specifically to SHOW what goes
   wrong: highly correlated spend (TV and out-of-home booked in the same weeks) produces unstable,
   sometimes wrong-signed coefficients, and a channel whose spend happens to track overall demand
   (retargeting) gets credited with an absurd ROI.
2. **Regularised regression** (script 04a): the same idea, but with adstock/saturation transforms
   and a penalty (ridge/elastic net) that keeps coefficients from swinging wildly, plus a
   constraint that media effects can't be negative. Better, but this project found -- and reports
   honestly -- that it still over-attributes revenue to a few seasonally-correlated channels,
   because several plausible attributions fit the observed data almost equally well.
3. **Bayesian regression** (script 04b): the same transforms, but instead of letting the data
   alone decide how much credit each channel gets, the model is told upfront (via a prior
   distribution) that no single channel plausibly explains most of weekly revenue on its own. This
   materially improves the decomposition without ever looking at the true answer (which only
   exists in this project because the data is simulated).

## Why an experiment matters even with a good model (script 07)

No amount of clever regression can fully separate "retargeting causes purchases" from
"retargeting spend follows people who were already about to buy" using observational data alone --
both explanations predict the same pattern in the data. A geo experiment (switching a channel off
for some regions and comparing to regions where it stayed on) breaks that ambiguity by design: the
regions were randomly assigned, so any difference in outcome can only be attributed to the channel
being on or off. This project simulates such an experiment on Denmark's 98 municipalities and uses
its result to sharpen the Bayesian model's estimate for the tested channel.

## What "validation" means here

- **Rolling-origin cross-validation**: repeatedly fit on an expanding window of past weeks and
  check accuracy on the following weeks, to see how the model would have performed if refit
  regularly over time (rather than checking accuracy on data it was fit on, which flatters every
  model).
- **A final 26-week holdout**, never touched by any tuning decision, used exactly once at the end
  to report out-of-time accuracy.
- **A recovery study** (script 05b) that, because this project's client data is simulated with a
  known true answer, can directly check estimated ROAS against the true ROAS -- something never
  possible with real client data, and the main reason this project exists as a portfolio piece.
