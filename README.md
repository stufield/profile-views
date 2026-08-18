# Repo Traffic Views

Self-contained snapshots of GitHub repository traffic, with a
generated badge. No third-party services, no external uptime
dependency.

[![repo views](https://raw.githubusercontent.com/stufield/profile-views/master/svg/views-badge.svg)](https://github.com/stufield/profile-views)

## Why

GitHub retains only **14 days** of traffic data. Once a day ages
out of that window it is gone permanently, and there is no way to
recover it.

This repository runs a cron job that appends the current window to
a CSV under version control. History accumulates indefinitely and
is owned outright, so it cannot be lost to a service shutting down
or rate-limiting its free tier.

## What it measures

**Repository traffic views** — visits to your repo pages,
aggregated across every repo you own.

This is *not* profile page views. GitHub exposes no API for
profile README views, so any counter claiming to report them is
using an external tracking pixel. That is the dependency this
repository exists to avoid.

## How it works

`.github/workflows/action.yml` runs every 6 hours:

1. Check out the repo using `VIEWS_TOKEN`.
2. Install R plus `curl` and `jsonlite` from Posit Package
   Manager binaries.
3. Run `scripts/collect-views.R`.
4. Commit `data/views.csv` and `svg/views-badge.svg` if either changed.

The script lists every repo you own, reads
`/repos/{owner}/{repo}/traffic/views` for each, and upserts the
results by `(repo, date)`.

Upserting rather than appending makes reruns **idempotent** — the
cron fires four times a day inside the same 14-day window, so rows
are overwritten, never duplicated. It also lets late corrections
from GitHub heal earlier snapshots.

## Files

| Path                       | Purpose                       |
|----------------------------|-------------------------------|
| `scripts/collect-views.R`  | Fetch, upsert, write badge    |
| `data/views.csv`           | Accumulated daily history     |
| `svg/views-badge.svg`      | Generated cumulative badge    |
| `.github/workflows/`       | Scheduled workflow            |

### Data schema

`data/views.csv` holds one row per repo per day:

```
repo,date,views,uniques
stufield/helpr,2026-08-18,25,5
```

## Setup

Create a personal access token and store it as the repository
secret `VIEWS_TOKEN` under **Settings → Secrets and variables →
Actions**.

The traffic API requires **push** access even for public repos, so
a read-only token returns 403. Minimum scope is `public_repo`; use
`repo` to include private repositories.

The same token authenticates the commit back to this repository,
so no separate push credential is needed.

## Running locally

```sh
Rscript --vanilla scripts/collect-views.R
```

Functions are testable in isolation — `main()` only fires under
`Rscript`, not when the file is sourced:

```r
source("scripts/collect-views.R")
views <- read_views("data/views.csv")
sum(views$views)
```

`collect_views()` takes a `fetch` argument, so it can be driven
from a mock payload without touching the network.

## Using the badge

```html
<img src="https://raw.githubusercontent.com/stufield/profile-views/master/svg/views-badge.svg" alt="Repo Views" />
```

Use `raw.githubusercontent.com`. A `/blob/` URL serves an HTML
page, not an image, and will not render.

## Limitations

- GitHub proxies and caches README images, so the displayed count
  lags the 12-hour cron. The data is current; the display is not.
- Repos without push access are logged and skipped rather than
  failing the run.
- Only owned repos are collected — no forks or org repos you
  merely contribute to.
