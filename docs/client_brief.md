# Client brief (fictional)

This brief is fictional, written to frame the modelling work in this project the way a real
engagement brief would. Havehjornet is not a real company.

## The client

**Havehjornet** ("The Garden Corner") is a mid-sized Danish home & garden retailer: roughly 60
physical stores (54 through 2023, expanding to 62 from January 2024) plus a webshop, selling
garden furniture, plants, tools, and seasonal outdoor goods. Category demand is strongly seasonal
(spring/garden peak, a Black Friday/Christmas gifting spike, a quiet January) and weather-sensitive.

## The business question

"We spend money across TV, online video, paid social (prospecting and retargeting), paid search
(brand and non-brand), programmatic display, out-of-home, and weekly leaflets ('tilbudsavis'). Our
platform dashboards each report their own ROAS, and they don't agree with each other or with what
finance sees in total revenue. We need to know:

1. How much of our revenue is actually driven by marketing, versus underlying demand, season, price,
   promotions, weather, and the new stores we opened in 2024?
2. Which channels are genuinely incremental, and which ones are just reporting spend against
   demand that would have converted anyway (we suspect retargeting and brand search)?
3. Given a fixed budget, how should we reallocate spend across channels to grow revenue?
4. How confident can we be in any of this, and what would make us more confident?"

## Constraints and context

- Weekly reporting cadence; store and webshop revenue are both in scope.
- No prior MMM has been run; historical platform-reported ROAS is the only benchmark available today.
- Marketing has budget to run a controlled test (e.g. a geo holdout) if it would meaningfully
  improve confidence in the numbers.
- The client wants a model that will be refreshed regularly (monthly), not a one-off report.

## What "done" looks like

A model that: (a) reconciles to total revenue, (b) separates baseline from media and media from
each other honestly, including flagging channels where confidence is low, (c) produces a
recommended reallocation with an uncertainty range, not a single "optimal" number presented as
fact, and (d) is explainable to people who are not statisticians.
