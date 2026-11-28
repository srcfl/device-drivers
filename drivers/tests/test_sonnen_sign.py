"""sonnen: battery.w follows the site convention.

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


def test_sonnen_battery_sign_follows_site_convention():
    result = subprocess.run(
        [str(LUA), "drivers/tests/lua_harness/test_sonnen_sign.lua"],
        capture_output=True, text=True, cwd=ROOT)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "OK" in result.stdout
