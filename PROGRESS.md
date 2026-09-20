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

## Phase 2 — ETL, validation, EDA
- [x] ETL is done (folded into Phase 1 above, since 01_ingest_clean.R needed to exist before raw export mess could be verified)
- [ ] EDA script (02_eda.R) not started

## Phase 2 — ETL, validation, EDA
- [ ] Not started

## Phase 3 — Naive baselines + diagnostics
- [ ] Not started

## Phase 4 — Core MMM (ridge, Bayesian), validation, recovery study
- [ ] Not started

## Phase 5 — Geo experiment (DiD) + calibration
- [ ] Not started

## Phase 6 — Budget optimiser + simulators
- [ ] Not started

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
