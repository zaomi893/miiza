#!/usr/bin/env python3
"""Verify a workflow's official HMBIRD baseline and track selection."""

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
        return any(version >= 6 for version in versions)
    return any(version < 6 for version in versions)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--branch", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--track", choices=("gold", "purple"), required=True)
    parser.add_argument(
        "--allow-pinned-equivalent-baseline",
        action="store_true",
        help="accept a documented equivalent source commit after verifying it is on the official branch",
    )
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

    if args.allow_pinned_equivalent_baseline:
        pinned = next((commit for commit in commits if commit["sha"] == args.commit), None)
        if pinned is None:
            raise SystemExit(
                f"pinned commit {args.commit} is not present in {args.repo}@{args.branch}"
            )
        pinned_title = pinned["commit"]["message"].splitlines()[0]
        if not in_track(pinned_title, args.track):
            raise SystemExit(
                f"pinned commit {args.commit} does not belong to the {args.track} track: {pinned_title}"
            )
        print(f"verified explicitly pinned {args.track} HMBIRD baseline: {args.commit} {pinned_title}")
        return

    matching = [
        commit
        for commit in commits
        if in_track(commit["commit"]["message"].splitlines()[0], args.track)
    ]
    gold_fallback = False
    if args.track == "gold" and not matching:
        # Some device branches have not published a >=16.0.6 HMBIRD update.
        # Gold builds still use the newest public source available for that
        # device instead of borrowing a different device's source baseline.
        matching = [
            commit
            for commit in commits
            if VERSION_RE.search(commit["commit"]["message"].splitlines()[0])
        ]
        gold_fallback = bool(matching)
    if not matching:
        raise SystemExit(
            f"official branch {args.repo}@{args.branch} has no versioned HMBIRD source"
        )

    latest = matching[0]
    latest_sha = latest["sha"]
    latest_title = latest["commit"]["message"].splitlines()[0]
    if latest_sha != args.commit:
        raise SystemExit(
            f"stale {args.track} commit: pinned={args.commit}, "
            f"latest={latest_sha} ({latest_title})"
        )

    label = "latest available HMBIRD source (gold fallback)" if gold_fallback else f"latest {args.track} HMBIRD source"
    print(f"verified {label}: {latest_sha} {latest_title}")


if __name__ == "__main__":
    main()
