# Progress log

Tracks what has been built, what works, and what is still outstanding. Updated after every phase.

## Phase 0 — Setup
- [x] Environment checked: macOS 26.5.2 (arm64), Xcode CLT, Homebrew, R 4.4.2, git, gh (authenticated as MadsWKofoed)
- [x] Quarto CLI 1.6.39 installed manually to `~/opt` (Homebrew cask needed sudo, which is unavailable non-interactively) and symlinked into `~/.local/bin` (added to PATH via `.zshrc`)
- [x] Repo scaffold created at `~/Projects/mmm-denmark-retail`, git initialized on `main`
- [x] `renv::init(bare = TRUE)` run; core packages installing
- [ ] renv snapshot committed
- [ ] GitHub repo created (private) and pushed
- [ ] MIT LICENSE, .gitignore, .Rproj — done

## Phase 1 — Simulation, raw exports, external data
- [ ] Not started

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
