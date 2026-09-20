# Interview Q&A

15 questions I should be able to answer cold about this project, answered from the actual results
(not generic MMM theory). Numbers are pulled from `results/tables/` and `PROGRESS.md`; re-check
those files if this doc and a table ever disagree (the table is the source of truth).

**1. What's the headline result?**
Media explains roughly 16.6% of revenue in the true simulation; the Bayesian MMM recovers a
posterior mean of 24.8% (90% CI [18.5%, 31.7%]), a large improvement over the regularised
(ridge/elastic-net) model's point estimate of 63.5%. TV, paid social prospecting, and online video
recover close to their true ROAS; brand search and retargeting remain overestimated in both models
because their spend is deliberately endogenous (follows demand, not the other way around).

**2. Why does the regularised model over-attribute revenue to media?**
Several channels' spend correlates with revenue's own seasonal shape (leaflets and search
non-brand genuinely have big, seasonally-timed effects; retargeting and search brand's correlation
is confounding, not signal). A lambda-sensitivity sweep showed no single regularisation strength is
simultaneously well-fitting and causally accurate — more regularisation can pull the media share
down, but only by making the model fit worse than one with no media terms at all. This is a
non-identifiability problem, not a bug: several different attributions explain the data almost
equally well.

**3. Why does the Bayesian model do better?**
It's told upfront, via a prior, that a single channel fully saturated is unlikely to explain most
of average weekly revenue — a generic business judgement, not derived from the true answer. That
prior competes with the likelihood's tendency to over-attribute, pulling the posterior toward more
plausible territory while barely hurting fit (R² 0.858 vs. ridge's 0.868).

**4. Does the Bayesian model fix everything?**
No. Search brand (true ROAS 0.5, estimated 5.87) and social retargeting (true ROAS 0.6, estimated
5.99) remain badly overestimated. Priors regularise *magnitude*; they don't fix *reverse
causality* — search brand spend follows brand demand that TV itself creates, and retargeting spend
follows a site-traffic proxy correlated with revenue. Only an experiment (or a valid instrument)
can identify that.

**5. What did the geo experiment show?**
Switching paid social prospecting off in a randomly assigned half of Denmark's 98 municipalities
for 6 weeks produced a statistically significant lift estimate (DiD p=0.004 by randomisation
inference; 90% bootstrap CI excludes zero) implying an ROAS of 2.42 (SE 0.91) — close to the true
2.6. Feeding that as an informative prior for social_prospecting specifically and refitting
improved the estimate materially: error vs. true ROAS dropped from 0.27 to 0.12, and the 90%
credible interval tightened from [0.24, 5.47] to [1.00, 3.98] (`results/tables/07_calibration_comparison.csv`).

**6. Why was that channel already reasonably well-recovered even without the experiment?**
Social prospecting's spend is "always-on with bursts," not tied to revenue's own seasonal
shape the way retargeting/search non-brand are — so it was one of the *better*-identified channels
to begin with. The experiment's value here is mostly about tightening confidence and validating the
model, not fixing a large bias, which is itself a realistic and useful outcome to report (not every
experiment needs to overturn the prior model to be worth running).

**7. What went wrong with the geo experiment on the first attempt?**
An initial noise setting for municipality-level heterogeneity made the effect statistically
undetectable (randomisation p=0.67) purely from being underpowered — the injected per-observation
noise was several times larger than the true per-capita effect size. No code bug, just a bad
initial power assumption, caught by checking the numbers before trusting the result. This is left
documented in `docs/assumptions_and_limitations.md` deliberately, since "did we power this test
correctly" is exactly the kind of question a real client should ask before running one.

**8. How does this compare to what platform dashboards report?**
Platform-reported (last-click) ROAS for search_brand is 3.06x and for social_retargeting is
2.54-2.88x (see `results/tables/02_platform_reported_roas.csv`) — both far above their true
incremental ROAS (0.5 and 0.6). This is the classic "looks great on the dashboard, barely moves the
needle" trap, reproduced deliberately in the simulated data.

**9. Why not just use xgboost/random forest — they had better holdout accuracy?**
They did (xgboost 6.7% holdout MAPE vs. the Bayesian MMM's 13.0%). But feature importance (gain/
impurity) is not a contribution decomposition or an ROAS — it ranks predictive usefulness, with no
guarantee of a monotonic, plausible response curve, and no non-negativity constraint. You cannot
ask an xgboost model "what happens to revenue if I move 100K DKK from channel A to channel B" without
building substantial additional (and still fragile) machinery on top. The MMM's transforms answer
that by construction.

**10. Why did seasonal naive beat every model on holdout accuracy?**
Havehjornet's category has strong, highly repeatable seasonality (garden peak, Black Friday,
Christmas, January trough) that recurs at nearly the same calendar weeks every year. "Same week
last year" is a genuinely strong predictor when seasonality dominates noise. This doesn't make the
MMM useless — it makes a different claim (a causal decomposition and a budget answer), which
seasonal naive cannot provide at all.

**11. What's the single biggest limitation of this project?**
Two: (a) no observable proxy for competitor activity, even though it's a true driver in the
simulation — an omitted-variable gap that's realistic but real; (b) adstock decay and saturation
shape are weakly identified even when overall ROAS recovers reasonably well (e.g. TV's estimated
decay 0.17 vs. true 0.55) — trust the ROAS numbers more than the specific carryover-curve shapes.

**12. How would you validate this differently with a real client?**
No ground truth to check against, so: rolling-origin out-of-time validation (already built), the
geo experiment approach (already built, would need real power calculations against real
municipality/region-level data), and triangulation against any incrementality tests the client
or their agencies have already run, plus sanity-checking media coefficients against category
knowledge and finance's own sense of baseline growth.

**13. Why 26 weeks for the final holdout?**
Roughly half a year — long enough to include a full seasonal cycle's worth of variation (though
not a full year), short enough to leave ~183 weeks for training and cross-validation. It was fixed
in `config/model_config.yml` before any tuning and never touched by the transform search or lambda
selection.

**14. What would the budget reallocation recommend, and how confident is it?**
See `results/tables/08_budget_allocation.csv` and `08_optimiser_summary.csv` for the specific
numbers — the optimiser reallocates within ±40% per-channel bounds (and a 50%-of-current
contractual floor) to maximise expected revenue across posterior draws from the calibrated
Bayesian model, reporting the probability the recommended mix beats the current one, not just a
single "optimal" number.

**15. If you had one more week, what would you do next?**
Run the geo experiment (or an equivalent instrument) on search_brand, since it's the other
clearly-endogenous channel this project never got to test. Add a real competitor-activity proxy.
Extend the recovery study to check calibration (does the 90% credible interval actually cover the
truth 90% of the time) across many simulated re-draws of the data, not just this one draw.
