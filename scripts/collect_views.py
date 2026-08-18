#!/usr/bin/env python3
"""Snapshot GitHub repo traffic into a CSV so history outlives GitHub's window.

GitHub only retains 14 days of traffic data. This script appends each day's
numbers to data/views.csv, so running it on a cron accumulates an indefinite
history that we own outright -- no third-party service, no external uptime
dependency.

Stdlib only, so the workflow needs no pip install and no setup-python step.

Env:
  GH_TOKEN  PAT with push access to the repos being read. The traffic API
            requires push access even for public repos, so a read-only
            token returns 403.
"""

import csv
import json
import os
import sys
import urllib.error
import urllib.request

API = "https://api.github.com"
OUT = "data/views.csv"
FIELDS = ["repo", "date", "views", "uniques"]


def get(path):
    """GET a JSON endpoint. Returns None on 403 so one bad repo cannot
    abort the whole run (common when a repo denies traffic access)."""
    req = urllib.request.Request(
        f"{API}{path}",
        headers={
            "Authorization": f"Bearer {os.environ['GH_TOKEN']}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "profile-views-collector",
        },
    )
    try:
        with urllib.request.urlopen(req) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        print(f"  skip {path}: HTTP {e.code}", file=sys.stderr)
        return None


def repos():
    """Own repos only. Paginates because the default page size is 30."""
    out, page = [], 1
    while True:
        batch = get(f"/user/repos?affiliation=owner&per_page=100&page={page}")
        if not batch:
            return out
        out += [r["full_name"] for r in batch]
        if len(batch) < 100:
            return out
        page += 1


def load(path):
    """Existing rows keyed by (repo, date)."""
    if not os.path.exists(path):
        return {}
    with open(path, newline="") as f:
        return {(r["repo"], r["date"]): r for r in csv.DictReader(f)}


def save(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS)
        w.writeheader()
        for key in sorted(rows):
            w.writerow(rows[key])


def collect(names, fetch=get):
    """Build {(repo, date): row} from the traffic API."""
    rows = {}
    for name in names:
        data = fetch(f"/repos/{name}/traffic/views")
        if not data:
            continue
        for day in data.get("views", []):
            date = day["timestamp"][:10]
            rows[(name, date)] = {
                "repo": name,
                "date": date,
                "views": day["count"],
                "uniques": day["uniques"],
            }
    return rows


def main():
    rows = load(OUT)
    before = len(rows)
    # Overwriting by (repo, date) makes reruns idempotent and lets late
    # corrections from GitHub heal earlier snapshots. Days older than the
    # 14-day window are simply never revisited, so they persist untouched.
    rows.update(collect(repos()))
    save(OUT, rows)
    print(f"{OUT}: {before} -> {len(rows)} rows")


if __name__ == "__main__":
    main()
