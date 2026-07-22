"""GoodWe failed reads must not become fresh zero or partial telemetry."""

from pathlib import Path
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[2]
PROFILES = ["community-v1", "gw8kn-et-hk3000"]


@pytest.mark.parametrize("profile", PROFILES)
@pytest.mark.parametrize("scenario", ["all", "middle", "short", "recover"])
def test_goodwe_poll_is_atomic_and_recovers(profile, scenario):
    result = subprocess.run(
        [
            str(ROOT / "lua55"),
            "drivers/tests/lua_harness/test_goodwe_failures.lua",
            profile,
            scenario,
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_goodwe_negative_pv_sentinel_fails_before_emit():
    result = subprocess.run(
        [
            str(ROOT / "lua55"),
            "drivers/tests/lua_harness/test_goodwe_failures.lua",
            "gw8kn-et-hk3000",
            "sentinel",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
