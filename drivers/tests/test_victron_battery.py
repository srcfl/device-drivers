"""victron (Modbus): register 844 is the battery state, not a temperature,
and a failed battery read sends no battery reading."""

from pathlib import Path
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")


@pytest.mark.parametrize(
    "scenario",
    [
        "battery",
        "battery_read_fails",
    ],
)
def test_victron_battery(scenario):
    result = subprocess.run(
        [str(LUA), "drivers/tests/lua_harness/test_victron_battery.lua", scenario],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
