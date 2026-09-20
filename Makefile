.PHONY: setup all quick test clean

RSCRIPT := Rscript

setup:
	$(RSCRIPT) -e 'renv::restore()'

# Full pipeline, reproducible from a clean checkout. Fixed seeds throughout.
all:
	$(RSCRIPT) scripts/00a_fetch_external_data.R
	$(RSCRIPT) scripts/00b_simulate_ground_truth.R
	$(RSCRIPT) scripts/00c_build_raw_exports.R
	$(RSCRIPT) scripts/01_ingest_clean.R
	$(RSCRIPT) scripts/02_eda.R
	$(RSCRIPT) scripts/03_baselines.R
	$(RSCRIPT) scripts/04a_mmm_ridge.R
	$(RSCRIPT) scripts/04b_mmm_bayesian.R
	$(RSCRIPT) scripts/05_validation.R
	$(RSCRIPT) scripts/05b_recovery_study.R
	$(RSCRIPT) scripts/06_ml_benchmark.R
	$(RSCRIPT) scripts/07_geo_experiment.R
	$(RSCRIPT) scripts/08_decision_tools.R
	$(RSCRIPT) scripts/09_refresh_backtest.R

# Fast smoke version: reduced CV grid / MCMC iterations, for quick checks.
quick:
	MMM_QUICK=1 $(RSCRIPT) scripts/00a_fetch_external_data.R
	MMM_QUICK=1 $(RSCRIPT) scripts/00b_simulate_ground_truth.R
	MMM_QUICK=1 $(RSCRIPT) scripts/00c_build_raw_exports.R
	MMM_QUICK=1 $(RSCRIPT) scripts/01_ingest_clean.R
	MMM_QUICK=1 $(RSCRIPT) scripts/02_eda.R
	MMM_QUICK=1 $(RSCRIPT) scripts/03_baselines.R
	MMM_QUICK=1 $(RSCRIPT) scripts/04a_mmm_ridge.R
	MMM_QUICK=1 $(RSCRIPT) scripts/04b_mmm_bayesian.R
	MMM_QUICK=1 $(RSCRIPT) scripts/05_validation.R
	MMM_QUICK=1 $(RSCRIPT) scripts/05b_recovery_study.R

test:
	$(RSCRIPT) -e 'testthat::test_dir("tests/testthat")'

clean:
	rm -rf data/processed/* data/raw/* results/models/* results/tables/* results/figures/*
