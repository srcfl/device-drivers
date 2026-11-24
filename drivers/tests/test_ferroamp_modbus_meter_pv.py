"""ferroamp_modbus sends meter and PV only from registers that answered (srcfl/device-drivers#258).

docs/WRITING-A-DRIVER.md, "Never fabricate": a field that did not answer is
left out, and a stream whose power read did not answer is not emitted. A 0 W
meter reading from a failed read looks like a site in balance.
"""

from pathlib import Path
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")


@pytest.mark.parametrize("scenario", ["all_answer", "grid_power_fails", "voltage_fails", "current_fails", "frequency_and_energy_fail", "pv_power_fails", "pv_energy_fails", "short_reply", "nothing_answers"])
def test_ferroamp_modbus_meter_pv(scenario):
    result = subprocess.run(
        [str(LUA), "drivers/tests/lua_harness/test_ferroamp_modbus_meter_pv.lua", scenario],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
