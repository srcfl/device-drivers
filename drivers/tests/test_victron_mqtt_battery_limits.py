"""victron_mqtt reports what the BMS allows now: CCL and DCL times the BMS's
own voltage, battery and cell temperatures, each left out when unknown or
when its source has gone quiet for too long."""

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
        "limits",
        "bms_forbids_discharge",
        "no_bms_voltage",
        "null_and_gone_clear",
        "picks_active_bms",
        "out_of_range",
        "nothing_invented",
        "bms_goes_quiet",
        "fixed_ccl_kept",
        "link_gap_forgets",
        "link_gap_after_idle_poll",
        "short_gap_keeps",
    ],
)
def test_victron_mqtt_battery_limits(scenario):
    result = subprocess.run(
        [str(LUA), "drivers/tests/lua_harness/test_victron_mqtt_battery_limits.lua", scenario],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
