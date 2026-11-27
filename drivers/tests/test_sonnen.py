"""sonnen: battery sign and battery control.

sonnen reports Pac_total_W positive while discharging; FTW's battery.w is
positive while charging. The harness script polls the driver against
/api/v2/latestdata bodies in the shape a live unit returns.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")


def run(script: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(LUA), f"drivers/tests/lua_harness/{script}"],
        capture_output=True, text=True, cwd=ROOT)


def test_sonnen_battery_sign_follows_site_convention():
    result = run("test_sonnen_sign.lua")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "OK" in result.stdout


def test_sonnen_control_lease_default_mode_and_refusals():
    """Manual setpoints, clamping, the 60 s lease, default mode with
    readback, orphan clearing at start, no http_put, and refused writes."""
    result = run("test_sonnen_control.lua")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "OK" in result.stdout
