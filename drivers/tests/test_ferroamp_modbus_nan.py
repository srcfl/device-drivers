"""ferroamp_modbus leaves out a float that answers NaN or infinity.

docs/WRITING-A-DRIVER.md, "Never fabricate" and "Numbers": the EnergyHub
uses NaN and infinity for "not present". Up to 2.2.1 the decoder turned them
into 0, so a 0 W meter or a 0 % SoC went out as a reading.
"""

from pathlib import Path
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")


@pytest.mark.parametrize("scenario", [
    "nan_grid_power",
    "inf_pv_power",
    "nan_one_phase",
    "nan_frequency_and_counter",
    "nan_battery",
    "largest_float_scaled",
    "real_zero_kept",
])
def test_ferroamp_modbus_nan(scenario):
    result = subprocess.run(
        [str(LUA), "drivers/tests/lua_harness/test_ferroamp_modbus_nan.lua", scenario],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
