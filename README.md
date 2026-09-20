# Marketing Mix Modelling — Danish home & garden retailer (portfolio project)

> **Status: work in progress.** This README is a placeholder created during initial setup and will be
> rewritten with full method, results and figures once the pipeline runs end to end. See `PROGRESS.md`
> for the current build status.

## What this is

A complete, from-scratch Marketing Mix Modelling (MMM) project in R, built as a portfolio piece to
demonstrate the full lifecycle of econometric marketing measurement: messy raw data ingestion,
cleaning, exploratory analysis, naive baselines, regularised and Bayesian MMM, causal calibration via
a simulated geo experiment, budget optimisation, scenario simulation, and client-ready deliverables
(deck, dashboard, workbook, documentation).

**All client sales and media data in this project are simulated**, generated from a documented,
known ground truth (`config/ground_truth.yml`), so that model estimates can be checked against the
true underlying effects — something never possible with real client data. External data (weather,
Danish macro indicators, public holidays) is real, pulled from public APIs and cached with fetch
dates in `data/external/`.

This project does not represent, and does not use data from, any real company, client or employer.

## Repository layout

See the directory structure below; each `scripts/NN_*.R` file is one pipeline stage and can be run
independently once its inputs exist.

```
config/     ground truth and model configuration
R/          reusable functions (simulation, transforms, cleaning, models, diagnostics, optimisation, plotting)
scripts/    numbered pipeline stages, 01 through 09
data/       raw (simulated messy exports), external (real public data), processed (clean modelling table)
results/    fitted model objects, tables, figures
app/        Shiny dashboard
reports/    Quarto slide deck
docs/       plain-language write-ups (methodology, data request, assumptions, interview Q&A)
tests/      testthat unit tests
```

## How to run

Full instructions will be added once the pipeline is complete. In short:

```
make setup   # renv::restore()
make all     # run the full pipeline end to end
make quick   # fast smoke version (reduced CV grid / MCMC iterations)
make test    # run the testthat suite
```

## Limitations

This is a portfolio project with simulated client data. Section to be completed with full,
honest limitations once modelling is done.
