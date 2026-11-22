"""ferroamp_modbus sends each battery field only from a register that answered."""

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
        "power_read_fails",
        "all_battery_reads_fail",
        "energy_read_fails",
        "soc_read_fails",
    ],
)
def test_ferroamp_modbus_battery(scenario):
    result = subprocess.run(
        [str(LUA), "drivers/tests/lua_harness/test_ferroamp_modbus_battery.lua", scenario],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
