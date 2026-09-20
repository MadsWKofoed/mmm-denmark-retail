# Standalone test runner (this project is not an R package, so we don't use
# testthat::test_check()). Run via `make test` or:
#   Rscript -e 'testthat::test_dir("tests/testthat")'
library(testthat)
library(here)

for (f in list.files(here("R"), pattern = "\\.R$", full.names = TRUE)) source(f)

test_dir(here("tests", "testthat"), reporter = "summary")
