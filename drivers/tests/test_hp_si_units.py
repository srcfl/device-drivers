"""nibe_local and myuplink convert vendor kW/kWh to W/Wh at emit."""

from pathlib import Path
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")


def test_nibe_local_myuplink_si_units_at_emit():
    result = subprocess.run(
        [
            str(LUA),
            "drivers/tests/lua_harness/test_hp_si_units.lua",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "PASS" in result.stdout
