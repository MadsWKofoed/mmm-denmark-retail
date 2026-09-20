# Assumptions and limitations

This is the single most important document in this project to read before trusting any number in
it. Written after building the pipeline, listing what actually went wrong or stayed uncertain --
not a generic disclaimer template.

## Everything here is simulated except the external data

Client sales, all media spend, all platform-reported revenue, and the geo-experiment outcome data
are simulated from a known ground truth (`config/ground_truth.yml`). Weather, Danish consumer
confidence, CPI, and public holidays are real (see `data/external/_fetch_metadata.json` for fetch
dates and source URLs). This is what makes the recovery study (script 05b) possible at all -- and
it is also why none of the ROAS numbers in this project should be read as claims about any real
business.

## The regularised (ridge/elastic-net) model over-attributes revenue to media

Point estimate: media explains ~63.5% of predicted training-period revenue, vs. a true 16.6%. This
is not a coding bug -- it was diagnosed via a lambda sensitivity sweep: more regularisation *can*
pull the media share down toward the true value, but only by sacrificing so much predictive fit
that R² drops below what a model with no media at all achieves. Several media channels are
seasonally correlated with revenue's own baseline shape, so many different attributions fit the
observed data almost equally well -- the causal split is not uniquely identified by a single
CV-optimal regularised fit. Treat the ridge model's contribution split as illustrative of the
*method*, not as a number to act on; the Bayesian model exists specifically to correct this.

## The Bayesian model helps, but doesn't fully solve endogeneity

With a weakly informative prior (half-normal(0, 0.04) on each channel's effect, chosen generically
-- "no single channel plausibly explains most of average revenue," not derived from the true
answer), media share drops to a posterior mean of 24.8% (90% CI [18.5%, 31.7%]), much closer to
16.6%. Per-channel, well-identified channels (TV, social_prospecting, online_video) recover close
to their true ROAS. The two channels deliberately built with endogenous spend (search_brand:
spend follows brand demand TV itself creates; social_retargeting: spend follows a site-traffic
proxy correlated with revenue) remain substantially overestimated even in the Bayesian model
(5.87 vs. true 0.5, and 5.99 vs. true 0.6) -- priors regularise magnitude, they do not fix reverse
causality. That is what the geo experiment (script 07) is for, and even there, only
social_prospecting was tested; search_brand's endogeneity is not addressed anywhere in this project
and would need its own experiment or instrument in a real engagement.

## Adstock decay and Hill-saturation shape are weakly identified

The recovery study (05b) shows ROAS recovers far better than the underlying decay/shape parameters
themselves -- e.g. TV's estimated decay (0.17) vs. true (0.55), leaflets' estimated decay (0.003)
vs. true (0.2). With ~180 weekly training observations, there often isn't enough signal to pin down
*both* the shape of a channel's response curve *and* its overall magnitude precisely; a model can
land on a plausible total effect via a compensating combination of transform parameters that
doesn't match the true carryover pattern. This matters for anything that leans on the *shape* of
the response curve specifically (e.g. "how much does the 500th vs. 5000th DKK of weekly TV spend
return") more than for total ROAS.

## An omitted variable: competitor pressure

The true data-generating process includes a competitor-pressure effect on revenue
(`config/ground_truth.yml: non_media_drivers.competitor_pressure_index`), but no observable proxy
for it was built into the raw-data pipeline -- there's no public "competitor promotion calendar."
Every model in this project (baselines, ridge, Bayesian) is missing this control, which is a
genuine source of omitted-variable bias, and is *realistic*: real MMM engagements frequently lack
clean competitor data too. `docs/data_request.md` flags this as something to explicitly ask a real
client or a data panel provider for.

## Rolling-origin CV is volatile with this much data

The ridge model's full-training-set R² (0.868) is much higher than its stricter rolling-origin CV
R² (mean 0.019 across 7 folds, ranging from -1.91 to 0.60 fold-to-fold). Early folds with limited
training history perform worst. This gap between in-sample and true out-of-fold performance is
reported honestly rather than only quoting the flattering in-sample number -- and is a real risk
with ~180-209 weekly observations split across 24+ predictors: don't expect month-to-month refit
stability to be much better than this without more data or a simpler model.

## The geo experiment's statistical power is a live design choice, not a guarantee

The simulated geo experiment (98 municipalities, 6-week test) recovers a statistically significant
lift close to the true effect with a moderate noise setting -- but an earlier attempt with more
municipality-level noise came back completely non-significant (randomisation p=0.67) purely from
under-powering, with no code bug involved. This is left as an explicit demonstration that a geo
test's value depends heavily on its design (sample size, duration, effect size relative to
municipality-level noise) -- exactly the kind of power calculation a real engagement should run
*before* asking a client to spend budget on a holdout test, not after.

## The Shiny app and Quarto deck read saved results, not live models

Refitting the Bayesian model takes several minutes; the dashboard and deck both read pre-computed
tables/figures from `results/`. If you change `config/ground_truth.yml` or `config/model_config.yml`
and don't re-run the full pipeline, the app and deck will show stale numbers -- there's no
guard against this beyond `PROGRESS.md` and re-running `make all`.

## What would change with real client data

A real engagement would (a) not have ground truth to check against, so the recovery study becomes
impossible and out-of-time validation plus experiments become the *only* way to build confidence;
(b) almost certainly need more non-media controls (competitor data, funnel/traffic data) than were
available here; (c) likely have several years more history, improving identification of the
weaker channels; (d) need the taxonomy mapping validated with the client's actual campaign-naming
conventions rather than pattern-matched.
