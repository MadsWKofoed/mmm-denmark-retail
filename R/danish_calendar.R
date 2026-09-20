# Danish public holiday calendar, computed (not looked up), for 2022-2025.
#
# Great Prayer Day ("Store Bededag") was abolished as a public holiday from
# 2024 onwards (converted to an ordinary working day, with an extra tax on
# earnings replacing the day off) -- this is intentional and matches the
# stated scenario ("Great Prayer Day until 2023").

#' Compute Easter Sunday (Gregorian) for a given year using the anonymous
#' Gregorian algorithm (Meeus/Jones/Butcher).
#' @param year Integer year.
#' @return Date of Easter Sunday.
easter_sunday <- function(year) {
  a <- year %% 19
  b <- year %/% 100
  c <- year %% 100
  d <- b %/% 4
  e <- b %% 4
  f <- (b + 8) %/% 25
  g <- (b - f + 1) %/% 3
  h <- (19 * a + b - d - g + 15) %% 30
  i <- c %/% 4
  k <- c %% 4
  l <- (32 + 2 * e + 2 * i - h - k) %% 7
  m <- (a + 11 * h + 22 * l) %/% 451
  month <- (h + l - 7 * m + 114) %/% 31
  day <- ((h + l - 7 * m + 114) %% 31) + 1
  as.Date(sprintf("%04d-%02d-%02d", year, month, day))
}

#' Danish public holidays for a set of years.
#'
#' @param years Integer vector of years.
#' @return tibble with columns date, holiday_name, in_effect_from, in_effect_to
danish_holidays <- function(years) {
  purrr::map_dfr(years, function(yr) {
    easter <- easter_sunday(yr)
    holidays <- tibble::tibble(
      date = c(
        as.Date(sprintf("%d-01-01", yr)),   # New Year's Day
        easter - 3,                          # Maundy Thursday
        easter - 2,                          # Good Friday
        easter,                              # Easter Sunday
        easter + 1,                          # Easter Monday
        easter + 26,                         # Great Prayer Day (4th Friday after Easter)
        easter + 39,                         # Ascension Day
        easter + 49,                         # Whit Sunday
        easter + 50,                         # Whit Monday
        as.Date(sprintf("%d-12-24", yr)),   # Christmas Eve (half day, retail-relevant)
        as.Date(sprintf("%d-12-25", yr)),   # Christmas Day
        as.Date(sprintf("%d-12-26", yr)),   # 2nd Christmas Day
        as.Date(sprintf("%d-12-31", yr))    # New Year's Eve
      ),
      holiday_name = c(
        "Nytaarsdag", "Skaertorsdag", "Langfredag", "Paaskedag", "2. Paaskedag",
        "Store Bededag", "Kristi Himmelfartsdag", "Pinsedag", "2. Pinsedag",
        "Juleaftensdag", "Juledag", "2. Juledag", "Nytaarsaften"
      )
    )
    if (yr >= 2024) {
      holidays <- dplyr::filter(holidays, holiday_name != "Store Bededag")
    }
    holidays$year <- yr
    holidays
  })
}
