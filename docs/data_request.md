# Data request: what a real client would need to supply

This project simulates all client/media/sales data (see README.md and `data/external/_fetch_metadata.json`
for exactly which pieces of data in this repo are real vs. simulated). This document lists what a
*real* engagement would need to request from a client and their media agencies, based on what this
project's pipeline actually needed to build a working MMM -- including the gaps this project hit.

## Media data (one export per platform, expect it to be messy)

| Source | Grain | Fields needed | Notes from this project |
|---|---|---|---|
| Google Ads | Daily, per campaign | Date, campaign name, cost, clicks, impressions, conversions, conversion value, currency | Request brand vs. non-brand split explicitly if not taxonomised already -- campaign-name pattern matching is fragile |
| Meta Ads | Daily, per campaign | Date, campaign name, amount spent, impressions, link clicks, purchases, purchase value, currency | Same taxonomy issue for prospecting vs. retargeting |
| Programmatic/DSP | Daily, per line item | Date, line item, spend, impressions, clicks, viewability, attributed revenue | Video vs. display split needed |
| TV | Per spot or weekly batch | Date/week, station, spot length, GRPs, cost | GRPs let you sanity-check cost-per-GRP consistency over time |
| Out-of-home | Per booking | Booking start/end, format, geography, cost | Booking-level, not daily -- needs its own aggregation logic |
| Print/leaflets | Weekly | Print run size, distribution cost, print cost | Often the most under-instrumented channel despite being a large budget line |
| Store list | As-of dates | Store open/close dates, store count over time | Needed as a distribution control; often not proactively offered by a client, ask for it explicitly |

## Sales data

- Daily store + webshop revenue, ideally with a split (this project used it to reconcile weekly
  totals and to check for missing days).
- Promo calendar: campaign name, start/end date, discount depth -- ideally a real calendar export,
  not reconstructed from price data after the fact.

## What this project could NOT get from public/simulated sources, and would ask a real client for

- **Competitor activity/pricing.** This project's simulator includes a true competitor-pressure
  effect on revenue, but no observable proxy for it was built into the pipeline -- there is no
  public "competitor promotion calendar." A real engagement should ask the client for competitor
  price-tracking data (many retailers already buy this from a panel provider) or explicitly flag
  its absence as a source of omitted-variable bias in the model.
- **Site traffic / conversion funnel data**, which would help separate genuine retargeting
  incrementality from "retargeting spend that just follows people who were already converting."
- **A geo or holdout test already run**, or budget/appetite to run one -- this project simulates
  one (script 07) specifically because it is the single highest-value ask for de-confounding the
  most endogenous channels (brand search, retargeting).

## Real external data used in this project (for comparison)

Weather (Open-Meteo), Danish consumer confidence and CPI (Statistics Denmark StatBank), and
computed Danish public holidays -- all free, public, and worth pulling into any real Danish MMM
without waiting on the client.
