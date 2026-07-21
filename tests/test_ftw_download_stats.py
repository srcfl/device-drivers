"""Tests for FTW release download statistics."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from ftw_download_stats import StatsError, _markdown, parse_assets  # noqa: E402


def test_parse_assets_keeps_each_driver_version() -> None:
    rows = parse_assets(
        "stable",
        [
            {
                "name": "driver-goodwe-v1.0.1-0123456789abcdef.lua",
                "download_count": 42,
                "browser_download_url": "https://example.test/goodwe",
            },
            {
                "name": "driver-goodwe-v1.1.0-fedcba9876543210.lua",
                "download_count": 7,
                "browser_download_url": "https://example.test/goodwe-new",
            },
            {"name": "manifest.json", "download_count": 100},
        ],
    )

    assert [(row["driver"], row["version"], row["downloads"]) for row in rows] == [
        ("goodwe", "1.0.1", 42),
        ("goodwe", "1.1.0", 7),
    ]
    assert "Total driver asset downloads: 49" in _markdown(rows)


def test_parse_assets_rejects_invalid_download_count() -> None:
    with pytest.raises(StatsError, match="invalid download_count"):
        parse_assets(
            "beta",
            [
                {
                    "name": "driver-sdm630-v1.0.0-0123456789abcdef.lua",
                    "download_count": -1,
                }
            ],
        )
