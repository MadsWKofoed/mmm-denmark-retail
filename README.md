# Marketing Mix Modelling — Danish home & garden retailer (portfolio project)

A complete, from-scratch Marketing Mix Modelling (MMM) project in R: messy raw data ingestion,
cleaning, exploratory analysis, naive baselines with full diagnostics, a regularised (elastic net)
MMM, a Bayesian MMM, a simulated geo experiment used to calibrate it, an ML benchmark, budget
optimisation, scenario simulation, an agile monthly refresh backtest, and client-ready deliverables
(deck, dashboard, Excel workbook, plain-language docs).

This project does not represent, and does not use data from, any real company, client or employer.

## Data: what's real, what's simulated

**All client sales, media spend, and platform-reported revenue are simulated**, generated from a
documented, known ground truth (`config/ground_truth.yml`), so model estimates can be checked
against the true underlying effects — something never possible with real client data. That check
is script `05b_recovery_study.R`, and it's the reason this project exists as a portfolio piece.

**Weather (Open-Meteo), Danish consumer confidence and CPI (Statistics Denmark StatBank), and
Danish public holidays are real**, fetched live from public APIs (see
`data/external/_fetch_metadata.json` for fetch dates and sources).

## Method

1. **Simulate** messy, realistic raw platform exports (mixed date formats, Danish decimal commas,
   EUR/DKK mixing, duplicate rows, missing days) from the true data-generating process.
2. **Clean and validate**: parse, standardise, deduplicate, reconcile totals against raw, build a
   weekly modelling table with a full data dictionary.
3. **Diagnose naive baselines** (seasonal naive, no-media, plain OLS on raw spend) to show exactly
   what goes wrong without adstock/saturation transforms and regularisation.
4. **Fit a regularised MMM** (glmnet elastic net, non-negative media coefficients) with adstock
   decay and Hill saturation per channel, chosen by a parallel random search over rolling-origin
   time-series cross-validation — never touching the true answer.
5. **Fit a Bayesian MMM** (brms + cmdstanr) with weakly informative priors and AR(1) errors,
   reporting posterior ROAS and contribution with 90% credible intervals.
6. **Simulate a geo experiment**: paid social prospecting switched off in a randomly assigned half
   of Denmark's 98 municipalities for 6 weeks, analysed with difference-in-differences (two-way
   fixed effects, event study, parallel-trends test, randomisation inference, cluster bootstrap,
   power/MDE) — and use the result to calibrate the Bayesian model.
7. **Validate out-of-time** on a final 26-week holdout untouched by any tuning, plus a rolling
   monthly refresh backtest tracking estimate stability over the last year.
8. **Optimise a budget allocation** (nloptr SLSQP) and simulate campaigns/scenarios, all
   uncertainty-aware via the Bayesian posterior.

## Key results (real numbers, from `results/tables/`)

- Media explains **16.6%** of revenue in the true simulation. The regularised model's point
  estimate is **63.5%** (a real, diagnosed limitation — see below); the Bayesian model with
  informative priors recovers **24.8%** (90% CI [18.5%, 31.7%]).
- Platform-reported ROAS for brand search and retargeting (3.06x and 2.5-2.9x) is far above their
  true incremental ROAS (0.5x and 0.6x) — the classic "looks great on the dashboard, barely moves
  the needle" trap.
- The simulated geo experiment on 98 municipalities found a statistically significant lift
  (randomisation p=0.004; 90% bootstrap CI excludes zero), implying an ROAS of 2.42 (SE 0.91) for
  paid social prospecting vs. a true 2.6 — and using it to calibrate the Bayesian model tightens
  and improves that channel's estimate (error vs. truth: 0.27 → 0.12).
- Out-of-time holdout (26 weeks, untouched by tuning): seasonal naive wins on pure accuracy
  (5.6% MAPE — strong, repeatable category seasonality), MMMs land 12-13% MAPE. xgboost beats every
  MMM on accuracy (6.7% MAPE) but produces no usable ROAS/contribution decomposition.
- A monthly agile refresh backtest over the last year shows well-identified channels (TV, leaflets)
  have stable ROAS refresh to refresh, while the two deliberately-confounded channels
  (social_retargeting, search_brand) swing wildly (up to 100+x ROAS in some refreshes) — a real
  signal, not noise, that those estimates shouldn't be trusted at face value.
- Recommended budget reallocation: **+703,697 DKK/week expected uplift** (90% CI
  [297,187, 1,124,437]), with an explicit caveat that the recommended increases for search_brand
  and social_retargeting rely on still-inflated estimates and should be discounted.

## Repository layout

```
config/     ground_truth.yml (data-generating process, never read by modelling scripts 01-04b)
            model_config.yml (CV design, search space, MCMC settings)
R/          reusable functions (simulation, transforms, cleaning, models, diagnostics, optimisation, plotting)
scripts/    numbered pipeline stages, 00a through 10
data/       raw (simulated messy exports), external (real public data), processed (clean modelling table)
results/    fitted model objects, tables, figures, the Excel workbook
app/        Shiny dashboard (bslib) -- reads saved results, no runtime refitting
reports/    Quarto slide deck (renders to pptx)
docs/       plain-language write-ups: client_brief, data_request, methodology,
            assumptions_and_limitations, interview_qa, screenshots/
tests/      testthat unit tests
```

## How to run

```
make setup   # renv::restore() -- installs pinned package versions
make all     # run the full pipeline end to end (fixed seeds; ~15-20 min, mostly two Bayesian fits)
make quick   # fast smoke version (reduced CV grid / MCMC iterations, ~2-3 min)
make test    # run the testthat suite
make app     # launch the Shiny dashboard locally
```

Rendering the deck (`quarto render reports/deck.qmd`) and building the Excel workbook
(`Rscript scripts/10_build_excel_workbook.R`) both read already-computed results, so run them
after `make all`.

**Runtimes** (this machine, Apple Silicon, sequential MCMC chains — see
`docs/assumptions_and_limitations.md` for why chains run sequentially here): each Bayesian fit
(scripts 04b and 07) takes ~5-6 minutes; the rest of the pipeline (00a-03, 04a, 05, 05b, 06, 08, 09)
runs in well under a minute combined.

## Limitations

See `docs/assumptions_and_limitations.md` for the full, honest list — including the regularised
model's over-attribution problem, why decay/saturation shape parameters are weakly identified even
when ROAS recovers well, the missing competitor-activity control, and CV volatility with this much
data. Nothing here is swept under the rug.

## What I would do with real client data

Request the operational data this project had to go without (a real competitor-activity proxy,
site-traffic/funnel data), validate the taxonomy mapping against the client's actual campaign
naming, extend the geo-experiment approach to search_brand (the other clearly endogenous channel),
and run the recovery-study-style check across many refits over time rather than once, since with
real data there is no ground truth left to check against directly — out-of-time validation and
experiments become the only way to build confidence.
