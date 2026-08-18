#!/usr/bin/env Rscript
# Snapshot GitHub repo traffic so history outlives GitHub's window.
#
# GitHub retains only 14 days of traffic data. Each run appends the
# current window to data/views.csv, so a cron accumulates an
# indefinite history we own outright -- no third-party service and no
# external uptime dependency.
#
# Env:
#   GH_TOKEN  PAT with push access to the repos being read. The
#             traffic API requires push access even for public repos,
#             so a read-only token returns 403.

library(curl)
library(jsonlite)

api <- "https://api.github.com"
out_csv <- "data/views.csv"
badge_svg <- "svg/badge.svg"


# Fetch helpers ------

# Returns NULL rather than aborting so one inaccessible repo cannot
# kill the whole run. 403s are expected for repos we lack push on.
api_get <- function(path) {
  h <- new_handle()
  handle_setheaders(h, Authorization = paste("Bearer", Sys.getenv("GH_TOKEN")),
                    Accept = "application/vnd.github+json",
                    `X-GitHub-Api-Version` = "2022-11-28",
                    `User-Agent` = "profile-views-collector"
  )
  res <- curl_fetch_memory(paste0(api, path), handle = h)
  if (res$status_code >= 300L) {
    message("  skip ", path, ": HTTP ", res$status_code)
    return(NULL)
  }
  fromJSON(rawToChar(res$content), simplifyVector = FALSE)
}

# Own repos only. Paginated because the API caps a page at 100.
list_repos <- function() {
  names <- character(0L)
  page <- 1L
  repeat {
    path <- sprintf("/user/repos?affiliation=owner&per_page=100&page=%d", page)
    batch <- api_get(path)
    if (is.null(batch) || length(batch) == 0L) {
      break
    }
    names <- c(names, vapply(batch, \(.x) .x$full_name, character(1L)))
    if (length(batch) < 100L) {
      break
    }
    page <- page + 1L
  }
  names
}


# Data ------

empty_views <- function() {
  data.frame(repo = character(0L),
             date = character(0L),
             views = integer(0L),
             uniques = integer(0L)
  )
}

read_views <- function(path) {
  if (!file.exists(path)) {
    return(empty_views())
  }
  read.csv(path,
           colClasses = c("character", "character", "integer", "integer"))
}

collect_views <- function(names, fetch = api_get) {
  rows <- lapply(names, function(.name) {
    data <- fetch(sprintf("/repos/%s/traffic/views", .name))
    if (is.null(data) || length(data$views) == 0L) {
      return(NULL)
    }
    data.frame(
      repo = .name,
      date = vapply(data$views, \(.d) substr(.d$timestamp, 1L, 10L), ""),
      views = vapply(data$views, \(.d) as.integer(.d$count), 1L),
      uniques = vapply(data$views, \(.d) as.integer(.d$uniques), 1L)
    )
  })
  do.call(rbind, c(list(empty_views()), rows))
}

# Fresh rows win on (repo, date). This makes reruns idempotent and
# lets late corrections from GitHub heal earlier snapshots. Days that
# have aged out of the 14-day window are never revisited, so they
# persist untouched.
upsert_views <- function(old, new) {
  both <- rbind(new, old)
  key  <- paste(both$repo, both$date)
  both <- both[!duplicated(key), , drop = FALSE]
  both[order(both$repo, both$date), , drop = FALSE]
}

write_views <- function(views, path) {
  dir.create(dirname(path), showWarnings = FALSE, recursive = TRUE)
  write.csv(views, path, row.names = FALSE, quote = FALSE)
}


# Badge ------

# Approximate rendered width at font-size 11. Avoids a font-metrics
# dependency; a few pixels of slack is invisible on a badge.
text_width <- function(text) {
  as.integer(nchar(text) * 6.6) + 20L
}

# Self-contained flat badge. No shields.io, no external service, so
# it cannot break when a third party disappears.
write_badge <- function(label, value, path = badge_svg) {
  lw <- text_width(label)
  vw <- text_width(value)
  total <- lw + vw
  svg <- sprintf(
     paste0(
            '<svg xmlns="http://www.w3.org/2000/svg" width="%d"',
            ' height="20" role="img" aria-label="%s: %s">\n',
            '  <title>%s: %s</title>\n',
            '  <linearGradient id="s" x2="0" y2="100%%">\n',
            '    <stop offset="0" stop-color="#bbb" stop-opacity=".1"/>',
            '<stop offset="1" stop-opacity=".1"/>\n',
            '  </linearGradient>\n',
            '  <clipPath id="r">',
            '<rect width="%d" height="20" rx="3" fill="#fff"/></clipPath>\n',
            '  <g clip-path="url(#r)">\n',
            '    <rect width="%d" height="20" fill="#555"/>\n',
            '    <rect x="%d" width="%d" height="20" fill="#0e75b6"/>\n',
            '    <rect width="%d" height="20" fill="url(#s)"/>\n',
            '  </g>\n',
            '  <g fill="#fff" text-anchor="middle"',
            ' font-family="Verdana,Geneva,DejaVu Sans,sans-serif"',
            ' font-size="11">\n',
            '    <text x="%.1f" y="14">%s</text>\n',
            '    <text x="%.1f" y="14">%s</text>\n',
            '  </g>\n</svg>\n'
            ),
     total, label, value, label, value, total, lw, lw, vw, total,
     lw / 2, label, lw + vw / 2, value
  )
  dir.create(dirname(path), showWarnings = FALSE, recursive = TRUE)
  writeLines(svg, path, useBytes = TRUE)
  total
}


# Main ------
main <- function() {
  old <- read_views(out_csv)
  views <- upsert_views(old, collect_views(list_repos()))
  write_views(views, out_csv)
  # Cumulative across all history ever recorded -- the number GitHub
  # itself cannot report, since it keeps only 14 days.
  total <- sum(views$views)
  write_badge("repo views", format(total, big.mark = ","))
  message(sprintf(
                  "%s: %d -> %d rows | total views %d",
                  out_csv, nrow(old), nrow(views), total
                  ))
}

# Runs on `Rscript collect_views.R` but not when sourced,
# which keeps the functions testable in isolation.
if (sys.nframe() == 0L) {
  main()
}
