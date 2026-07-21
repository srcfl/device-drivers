#!/usr/bin/env python3
"""Report GitHub release download counts for FTW driver assets."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections.abc import Iterable
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


ASSET_RE = re.compile(
    r"^driver-(?P<id>[A-Za-z0-9_][A-Za-z0-9._-]*)-v"
    r"(?P<version>[0-9]+\.[0-9]+\.[0-9]+)-(?P<digest>[0-9a-f]{16})\.lua$"
)
API_ROOT = "https://api.github.com"


class StatsError(RuntimeError):
    """A GitHub statistics request or response error."""


def parse_assets(channel: str, assets: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for asset in assets:
        name = asset.get("name")
        match = ASSET_RE.fullmatch(name) if isinstance(name, str) else None
        if not match:
            continue
        count = asset.get("download_count")
        if not isinstance(count, int) or count < 0:
            raise StatsError(f"{name}: invalid download_count")
        rows.append(
            {
                "channel": channel,
                "driver": match.group("id"),
                "version": match.group("version"),
                "sha256_prefix": match.group("digest"),
                "downloads": count,
                "url": str(asset.get("browser_download_url", "")),
            }
        )
    return sorted(rows, key=lambda row: (row["driver"], row["version"], row["sha256_prefix"]))


def _github_json(url: str, token: str) -> Any:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "srcfl-device-drivers-stats",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    try:
        with urlopen(Request(url, headers=headers), timeout=20) as response:
            return json.load(response)
    except (HTTPError, URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise StatsError(f"GitHub request failed for {url}: {exc}") from exc


def fetch_channel(repo: str, tag: str, token: str = "") -> list[dict[str, Any]]:
    release = _github_json(f"{API_ROOT}/repos/{repo}/releases/tags/{tag}", token)
    if not isinstance(release, dict) or not isinstance(release.get("assets_url"), str):
        raise StatsError(f"{tag}: GitHub returned an invalid release")
    assets: list[dict[str, Any]] = []
    page = 1
    while True:
        query = urlencode({"per_page": 100, "page": page})
        batch = _github_json(f"{release['assets_url']}?{query}", token)
        if not isinstance(batch, list) or not all(isinstance(item, dict) for item in batch):
            raise StatsError(f"{tag}: GitHub returned an invalid asset list")
        assets.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    return parse_assets(tag.removeprefix("drivers-"), assets)


def _markdown(rows: list[dict[str, Any]]) -> str:
    lines = [
        "| Driver | Version | Channel | Downloads |",
        "|---|---:|---|---:|",
    ]
    lines.extend(
        f"| {row['driver']} | {row['version']} | {row['channel']} | {row['downloads']} |"
        for row in rows
    )
    lines.append("")
    lines.append(f"Total driver asset downloads: {sum(row['downloads'] for row in rows)}")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default="srcfl/device-drivers")
    parser.add_argument("--channel", choices=("beta", "stable", "all"), default="all")
    parser.add_argument("--format", choices=("markdown", "json"), default="markdown")
    args = parser.parse_args()
    channels = ("beta", "stable") if args.channel == "all" else (args.channel,)
    token = os.environ.get("GITHUB_TOKEN", "")
    try:
        rows = [
            row
            for channel in channels
            for row in fetch_channel(args.repo, f"drivers-{channel}", token)
        ]
    except StatsError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    rows.sort(key=lambda row: (row["driver"], row["channel"], row["version"]))
    if args.format == "json":
        print(json.dumps({"drivers": rows}, indent=2, sort_keys=True))
    else:
        print(_markdown(rows))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
