#!/usr/bin/env python3
"""Verify that a workflow pins the newest official commit in its HMBIRD track."""

from __future__ import annotations

import argparse
import json
import os
import re
import urllib.parse
import urllib.request


VERSION_RE = re.compile(r"(?<!\d)16\.0\.(\d+)(?:\.\d+)?\b")


def in_track(message: str, track: str) -> bool:
    versions = [int(match) for match in VERSION_RE.findall(message)]
    if track == "gold":
        return any(version >= 7 for version in versions)
    return any(version < 7 for version in versions)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--branch", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--track", choices=("gold", "purple"), required=True)
    args = parser.parse_args()

    query = urllib.parse.urlencode({"sha": args.branch, "per_page": 100})
    url = f"https://api.github.com/repos/{args.repo}/commits?{query}"
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "miiza-hmbird-source-verifier",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    token = os.environ.get("GH_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"

    with urllib.request.urlopen(urllib.request.Request(url, headers=headers)) as response:
        commits = json.load(response)

    matching = [
        commit
        for commit in commits
        if in_track(commit["commit"]["message"].splitlines()[0], args.track)
    ]
    if not matching:
        raise SystemExit(
            f"official branch {args.repo}@{args.branch} has no {args.track} commit"
        )

    latest = matching[0]
    latest_sha = latest["sha"]
    latest_title = latest["commit"]["message"].splitlines()[0]
    if latest_sha != args.commit:
        raise SystemExit(
            f"stale {args.track} commit: pinned={args.commit}, "
            f"latest={latest_sha} ({latest_title})"
        )

    print(f"verified latest {args.track} HMBIRD source: {latest_sha} {latest_title}")


if __name__ == "__main__":
    main()
