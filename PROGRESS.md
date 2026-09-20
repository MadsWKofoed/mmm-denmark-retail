# Progress log

Tracks what has been built, what works, and what is still outstanding. Updated after every phase.

## Phase 0 — Setup (DONE)
- [x] Environment checked: macOS 26.5.2 (arm64), Xcode CLT, Homebrew, R 4.4.2, git, gh (authenticated as MadsWKofoed)
- [x] Quarto CLI 1.6.39 installed manually to `~/opt` (Homebrew cask needed sudo, which is unavailable non-interactively) and symlinked into `~/.local/bin` (added to PATH via `.zshrc`)
- [x] gfortran installed via `brew install gfortran` (formula, no sudo) + `~/.R/Makevars` pointing FC/F77 at it — R's usual `/opt/gfortran` location needs root, this is the no-sudo workaround. Needed for tseries/car/forecast source builds.
- [x] Repo scaffold created at `~/Projects/mmm-denmark-retail`, git initialized on `main`
- [x] `renv::init(bare = TRUE)`; all CORE packages installed into the isolated renv library (tidyverse, here, glmnet, fixest, nloptr, xgboost, ranger, shiny, bslib, testthat, etc.). brms/cmdstanr deferred to Phase 4 (EXTENDED, heavy install).
- [x] renv.lock snapshotted
- [x] GitHub repo created (private) and pushed: https://github.com/MadsWKofoed/mmm-denmark-retail
- [x] MIT LICENSE, .gitignore, .Rproj, README skeleton, Makefile

## Phase 1 — Simulation, raw exports, external data (DONE)
- [x] `config/ground_truth.yml`: full data-generating process spec (adstock/Hill params per channel, non-media driver effects, noise, data-quality gremlins). Fictional client: "Havehjornet", DK home & garden retailer.
- [x] `scripts/00a_fetch_external_data.R`: real data from Open-Meteo (weather, Copenhagen+Aarhus), DST StatBank FORV1 (consumer confidence) and PRIS01 (CPI — **PRIS111 from the brief was verified via the API to be discontinued/inactive**, replaced by active successor PRIS01), computed DK public holidays. All three fetches succeeded live (no fallback needed).
- [x] `R/simulation.R`, `R/danish_calendar.R`, `R/transformations.R`: adstock/Hill functions, DGP.
- [x] `scripts/00b_simulate_ground_truth.R`: builds TRUE weekly revenue + media series → `data/processed/_truth/` (only script 05b may read this).
- [x] `R/raw_exports.R`, `scripts/00c_build_raw_exports.R`: messy per-platform raw exports (google_ads_daily, meta_ads_daily, programmatic_daily, tv_spots, ooh_bookings, leaflet_costs_weekly, client_sales_daily, promo_calendar.xlsx) with mixed date formats, Danish decimal commas, EUR/DKK mixing, duplicate rows, missing days, messy campaign names.
- [x] `config/taxonomy_map.csv`: raw campaign → channel/tactic/funnel-stage mapping.
- [x] `R/cleaning.R`, `scripts/01_ingest_clean.R`: full ETL — parses messy dates/numbers, currency conversion, taxonomy matching, weekly aggregation, validation, reconciliation. Produces `data/processed/weekly_modelling_table.{csv,rds}` + data dictionary.
- [x] testthat coverage for transformations, cleaning helpers, simulator reproducibility (45 tests, all passing).

**Two real bugs found and fixed during this phase** (see "Known issues" below for detail): a dplyr join column collision, and a ~100x data-corruption bug from `readr`'s automatic locale-based number parsing silently misreading Danish decimal commas. Both are the kind of thing a real analyst would hit with real Danish exports — left in the git history as evidence of an honest build, not scrubbed.

- Simulated data checks out: media explains 16.6% of revenue (target 15-30%), per-channel implied short-run ROAS matches configured targets (TV 1.4, leaflets 3.4, search_brand 0.5 true vs 3.06 platform-reported, social_retargeting 0.6 true vs 2.54 platform-reported — the "low true incrementality, high platform ROAS" trap is clearly present in the data).
- Cleaned weekly table reconciles to 96-99% of true spend per channel (the ~1-4% gap is the intentional missing-day/duplicate-row data-quality noise, not a bug).

## Phase 2 — ETL, validation, EDA (DONE)
- [x] ETL (folded into Phase 1 above, since 01_ingest_clean.R needed to exist before raw export mess could be verified)
- [x] `R/plotting.R`: shared ggplot2 theme + validated CVD-safe categorical palette (fixed channel color order), used by every figure from here on.
- [x] `scripts/02_eda.R`: spend-pattern small multiples, spend correlation matrix, VIF on raw spend, STL seasonal decomposition, ADF/KPSS stationarity tests, platform-reported ROAS by channel.
- Correlation matrix confirms the intended collinearity traps: TV/OOH r=0.89, TV/online_video r=0.73, search_brand/TV r=0.58 (the endogeneity link). VIF flags TV (5.56) and OOH (5.31) as problematic (>5) on raw untransformed spend -- exactly the naive-OLS failure mode Phase 3 will demonstrate.
- ADF/KPSS both indicate revenue and total spend are stationary in levels (strong seasonality + noise dominate the mild 2.5%/yr trend) -- worth stating plainly rather than assuming non-stationarity.
- Platform-reported ROAS: search_brand 3.06x, social_prospecting 2.88x, social_retargeting 2.54x -- TV/OOH/leaflets have no platform attribution at all (realistic: no last-click tracking for offline channels), which is itself a useful EDA finding to carry into the deck.
- Fixed one figure bug: white correlation-value text was invisible on near-white (low |r|) cells; made label color conditional on |r|.

## Phase 2 — ETL, validation, EDA
- [ ] Not started

## Phase 3 — Naive baselines + diagnostics (DONE)
- [x] `scripts/03_baselines.R`: seasonal naive, no-media model, naive OLS on raw untransformed spend, all diagnosed (VIF, Durbin-Watson, Breusch-Godfrey, Breusch-Pagan, residual ACF, Newey-West HAC SEs).
- Seasonal naive MAPE 13.7%. No-media model R²=0.538 (the ceiling controls alone explain). Naive OLS R²=0.608 -- barely better, and the coefficients are not trustworthy: OOH comes out **negative** (wrong-signed) despite a genuinely positive true effect, purely from TV/OOH collinearity (VIF 5.3-5.6, per Phase 2). social_retargeting's coefficient is 93.8 DKK revenue per DKK spend -- a naive ~94x ROAS -- vs. a configured true ROAS of 0.6, because retargeting spend endogenously follows site traffic (reverse causality) and OLS can't tell the difference.
- Breusch-Godfrey strongly rejects (p<0.0001): residuals are autocorrelated beyond lag 1. Breusch-Pagan rejects (p=0.019): heteroskedastic residuals. Newey-West HAC SEs widen appropriately, but **do not fix** the social_retargeting bias -- it stays "significant" under HAC too, which is the point: HAC corrects inference (valid SEs), it does not correct endogeneity/omitted-variable bias in the point estimate itself. This distinction is worth having sharp for interview questions.
- This whole script is the "here's what goes wrong" chapter Phase 4's adstock+saturation+regularised MMM is the answer to.

**Mid-phase fix (before starting Phase 4):** realised the weekly modelling table was missing two controls the brief explicitly calls for -- holidays and the distribution/store-count change. Added `data/raw/store_count_weekly.csv` (client-supplied-style operational data, step function 54->62 stores in Jan 2024) and holiday-week dummies computed from `data/external/danish_holidays.csv` (Easter/Ascension/Whit Monday/Great Prayer Day/Christmas), joined into the weekly table in `01_ingest_clean.R`. Also fixed `write_danish_csv()` to round to 2dp even for the non-comma-formatted files (google_ads_daily and programmatic_daily now deliberately use plain decimal points, simulating an internationally-formatted platform export, per `data_quality$decimal_comma_share`). Re-ran phases 1-3: no-media model R² jumped from 0.538 to 0.826 once holidays/distribution are controlled for, and naive OLS now shows 3 of 9 channels wrong-signed (up from 1) -- search_brand flips negative too, which is a cleaner illustration of the endogeneity trap now that more baseline variance is properly absorbed by controls.

## Phase 4 — Core MMM (ridge, Bayesian), validation, recovery study (4a DONE, 4b in progress)
- [x] `config/model_config.yml`: CV design, transform search space, glmnet/Bayesian settings (never reads ground truth).
- [x] `R/model_design.R`, `R/models_transform_search.R`: shared design-matrix builder, rolling-origin CV folds, seeded parallel random search over adstock decay / Hill ec-quantile / shape per channel (furrr).
- [x] `scripts/04a_mmm_ridge.R`: 250-draw random search (rolling-origin CV, expanding window) -> elastic net (alpha=0.15, mostly ridge) with non-negative media coefficients, final lambda via 5-fold CV (`lambda.1se`). Final 26 weeks (2025-07-07 to 2025-12-29) held out untouched for Phase 5.

**Important honest finding, not a bug:** the regularised model over-attributes revenue to media -- training-period media share comes out ~64% vs. the true ~16.6%. Diagnosed via a lambda sensitivity sweep: heavier regularisation *can* pull media share down toward the true value, but only by sacrificing so much fit that R² drops below the no-media baseline (e.g. R²=0.45 at 10x lambda.1se, worse than the 0.83 no-media model gets for free) -- there is no single ridge/elastic-net lambda that is simultaneously well-fitting AND causally accurate here. This is because several media channels (search_nonbrand, leaflets, social_retargeting) are seasonally-correlated with revenue's own baseline shape, so many different linear attributions fit the observed data almost equally well (non-identifiability from observational data alone). TV recovers reasonably (estimated ROAS 1.15-1.26 vs true 1.4); the seasonally-correlated channels are the ones that blow up. This is precisely the gap 04b (Bayesian, informative priors) and the geo experiment (07) are meant to close -- documented in the script's own log output, not swept under the rug.

**Mid-phase tuning:** the initial simulator had social_retargeting and search_nonbrand spend correlate almost mechanically with revenue's own seasonal shape (r=0.84-0.90), producing a degenerate/unidentifiable model (95%+ media share, TV coefficient shrunk to exactly zero). Dampened both channels' coupling to their demand proxies (fractional-power dampening + more idiosyncratic noise) so correlations with revenue dropped to r=0.30 (retargeting) and r=0.70 (search_nonbrand) -- still elevated/endogenous as intended, but not mechanically collinear with the DV itself. Also switched glmnet alpha from 0.5 to 0.15 (more ridge, less lasso) so real-but-smaller-effect channels don't get zeroed out by the L1 penalty. Re-ran phases 1-3 after this change (results above reflect the final calibration).

- [x] `scripts/04b_mmm_bayesian.R` (brms/cmdstanr): reuses 04a's chosen transforms; nonlinear (nl=TRUE) brms formula with one nlpar per channel (half-normal(0, 0.04) prior, lb=0) plus a "baseline" nlpar bundling all controls (normal(0,2) prior), AR(1) errors, gaussian family, response scaled by mean training revenue so priors are interpretable as "share of average revenue at full saturation."

**Bayesian model materially improves on the ridge model's over-attribution problem:** media share drops from ridge's 63.5% point estimate to a Bayesian posterior mean of 24.8% (90% CI [18.5%, 31.7%]) -- much closer to the true 16.6%, at the cost of only a small drop in fit (Bayesian R²=0.858 vs ridge R²=0.868). Per-channel: TV recovers almost exactly (1.47 vs true 1.4), social_prospecting and online_video recover well (2.33 vs 2.6, 2.31 vs 1.9); the deliberately confounded channels (search_brand 5.87 vs true 0.5, social_retargeting 5.99 vs true 0.6) remain substantially overestimated -- exactly the intended "regularisation/priors alone can't fix endogeneity" result the geo experiment (07) exists to address. Convergence is excellent: max Rhat=1.003, min bulk ESS=1826, zero divergent transitions.

**Environment issue found and fixed:** cmdstanr spawning >1 parallel chain process (`cores>1`) crashes silently in this machine's sandboxed shell (no error, process just dies) -- confirmed reproducible by isolating with a minimal test. Fixed by hardcoding `cores=1` (sequential chains); full run takes ~5.4 minutes instead of the ~1.5 minutes parallel chains would take, which is an acceptable tradeoff for a portfolio project. Filed as product feedback (not a project bug).

**brms API friction, all resolved:** (1) `purrr::flatten()` corrupts `brmsprior` objects (they're data-frame-like S3 objects) -- combine priors with `+` instead. (2) `coef=` cannot be combined with `lb=` bounds in plain linear formulas -- per-channel non-negativity needs a nonlinear (`nl=TRUE`) formula with one nlpar per channel, since nlpar-level bounds ARE supported. (3) nlpar names can't contain underscores or dots -- used `eff1..eff9` with an explicit index mapping. (4) a bare `+ control` term is silently DROPPED in `nl=TRUE` formulas -- wrapped all controls into their own `baseline` nlpar (itself a full linear sub-model) instead. (5) AR(1) errors go via `bf(..., autocor = ~ar(time=t, p=1))`, not `y | ar(...) ~ ...` bar syntax (which errored as an invalid addition term in brms 2.23).

## Phase 5 (validation) — DONE
- [x] `scripts/05_validation.R`: out-of-time holdout comparison (all 5 models), rolling-origin CV for the ridge MMM, residual diagnostics.
- Holdout MAPE: seasonal naive 5.6% (best -- strong, repeatable category seasonality makes it a genuinely hard baseline to beat on pure accuracy), ridge MMM 12.2%, naive OLS 12.7%, Bayesian MMM 13.0%, no-media 15.5%. Bayesian's 90% predictive interval covers 80.8% of holdout weeks (a bit under nominal 90%, reasonable for 26 weeks).
- Rolling-origin CV (stricter, fold-specific lambda selection, not the search's own optimistic in-search scoring): mean R²=0.019 across 7 folds, with high fold-to-fold volatility (fold 3 R²=-1.91, others 0.3-0.6) -- documented honestly as a sign the model overfits more than its full-training-set R²=0.868 suggests, especially in early folds with limited history.
- [x] `scripts/05b_recovery_study.R` (the only script besides 00b/00c allowed to touch ground truth): Bayesian model's 90% credible interval covers the true ROAS for 7/9 channels, and is closer to truth than the ridge point estimate for 7/9 channels. Decay/shape parameters recover much more noisily than ROAS itself (expected -- classic MMM weak-identification issue, documented as a limitation).

## Phase 6 (ML benchmark) — DONE
- [x] `scripts/06_ml_benchmark.R`: xgboost + ranger, same rolling-origin CV design. xgboost holdout MAPE 6.7% (2nd best overall, beats every MMM/baseline except seasonal naive), ranger 8.7%. Feature importance (gain/impurity) is NOT a contribution/ROAS decomposition -- explicitly flagged as the central "why predictive accuracy alone isn't enough for budget decisions" point requested by the brief.

## Phase 7 (geo experiment + calibration) — DONE
- [x] `R/geo_experiment.R`: 98 real Danish municipality names with simulated (not real) population weights, simple random treatment assignment, per-capita panel construction.
- [x] `scripts/07_geo_experiment.R`: two-way fixed-effects DiD (fixest), event study, parallel-trends Wald test, 500-permutation randomisation inference, 500-resample cluster bootstrap, power/MDE, and a Bayesian recalibration for social_prospecting.
- DiD estimate: -0.07 DKK/capita/week (clustered SE 0.02, p=0.0088), implying a national weekly lift of ~340,468 DKK (SE 127,317) from having prospecting on -- close to the true average weekly contribution (~386,000 DKK). Randomisation-inference p=0.004. Parallel trends holds (Wald p=0.099). Event-study plot is textbook: flat noisy pre-period, clean sustained drop exactly at test start.
- Achieved power for the observed effect: 73.6%; MDE at 90% power: 0.08 DKK/capita.
- Experiment-implied ROAS: 2.42 (SE 0.91) vs. true 2.6 -- a good independent check.
- **Calibration works:** feeding the experiment estimate in as an informative prior and refitting improves social_prospecting's recovery (error vs. true ROAS: 0.27 -> 0.12) and tightens the 90% credible interval from [0.24, 5.47] to [1.00, 3.98].

**Two bugs found and fixed:**
1. A latent footgun present in every script: `log <- function(...) cat(...)` (a console-logging helper) shadows base R's `log()` math function for any sourced `R/*.R` function that calls it, since `source()` evaluates into the global environment. Bit exactly once -- `danish_municipalities()` calling `log(28000)` -- but renamed to `log_msg` across all 12 affected scripts to remove the whole class of risk rather than patch the one call site.
2. The geo panel's first noise calibration (municipality-level heterogeneity + idiosyncratic noise) was large enough to swamp the tiny true per-capita signal, producing a completely non-significant experiment (randomisation p=0.67) -- not a bug, just bad initial power assumptions, caught by sanity-checking the SE against the signal before trusting the result. Retuned noise levels to a realistic, well-powered design and documented the original underpowered attempt in `docs/assumptions_and_limitations.md` as a deliberate illustration of why experiment power matters.

## Phase 8 (decision tools) — DONE
- [x] `R/optimisation.R`, `scripts/08_decision_tools.R`: nloptr SLSQP budget allocator (±40% per-channel bounds, 50% contractual minimum), uncertainty-aware via the (geo-calibrated where available) Bayesian posterior draws; campaign simulator with carryover-safe forecasting; non-media scenarios (consumer confidence, temperature).
- Recommended reallocation: expected uplift +703,697 DKK/week (90% CI [297,187, 1,124,437]), P(beats current mix) = 100%.
- **Important honest caveat, surfaced directly in the script's own output and the allocation table (`low_confidence_estimate` column):** the optimiser recommends MORE spend on search_brand and social_retargeting -- exactly the two channels whose posterior ROAS remains inflated by known, uncorrected endogeneity. A real recommendation should discount or exclude those channels pending further identification work; the optimiser has no way to know its own inputs are untrustworthy there, which is precisely the point being illustrated.
- Competitor-pressure scenario dropped (no model control exists for it -- honest gap, matches docs/data_request.md).

## Phase 7 — Deliverables (README, deck, app, workbook, docs)
- [ ] Not started

## Phase 8 — Refresh backtest, tests, polish
- [ ] Not started

## Known issues / decisions log
- Quarto CLI installed without admin rights (tarball to `~/opt`, symlinked in `~/.local/bin`). If this machine's PATH doesn't pick it up in a new shell, run `export PATH="$HOME/.local/bin:$PATH"`.
- gfortran likewise needed a no-sudo workaround: `brew install gfortran` (formula) + `~/.R/Makevars` setting FC/F77, since R expects it at `/opt/gfortran` which requires root to create.
- PRIS111 (suggested in the brief for CPI) is discontinued at Statistics Denmark (verified live via the StatBank API's tableinfo endpoint: `"active": false`). Used PRIS01, its active successor with the same underlying series, instead. Documented in `scripts/00a_fetch_external_data.R` and the external-data metadata file.
- The brief's "208 ISO weeks" for 2022-01-03 to 2025-12-29 is actually 209 weeks by direct date arithmetic; kept the explicit date range and corrected the week count (see `config/ground_truth.yml`).
- Bug fixed: `attach_external_drivers()` left-joined weather data that had its own `week_start` column, colliding with the calendar's `week_start` and silently producing `week_start.x`/`.y` — broke `simulate_ground_truth()`. Fixed by selecting only the needed columns from weather before the join (same fix applied in `01_ingest_clean.R`).
- Bug fixed (the big one): raw CSVs are semicolon-delimited with Danish decimal commas (e.g. "100257,62"). `readr::read_delim()`'s default locale has `grouping_mark = ","`, so it silently "parsed" these as thousands-grouped integers (100257,62 → 10025762), inflating every spend/revenue figure by ~100x *before* the custom Danish-number parser ever ran. Fixed by adding `read_raw_csv()` in `R/cleaning.R`, which forces every raw column to character on read so `parse_danish_number()` does the actual parsing. Caught by comparing the cleaned weekly table's totals against the known ground truth — exactly the kind of check a real analyst should run when the raw/clean totals look implausible.
- TV, OOH and leaflets deliberately have no `platform_revenue_*` column in the modelling table — real linear TV/OOH/print bookings have no last-click platform attribution, so there is nothing to compare against MMM-estimated incrementality for those channels (this is realistic, not a gap).
