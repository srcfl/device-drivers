"""Growatt: battery power keeps the site sign, charge positive.

Growatt's Modbus RTU Protocol II V1.39 puts the discharge power first and
the charge power second in the storage input registers:

  1009-1010  Pdischarge1  discharge power, U32, 0.1 W
  1011-1012  Pcharge1     charge power,    U32, 0.1 W

Growatt-Local-Modbus (storage_120.py) maps the same two addresses the same
way. Up to 2.2.0 this driver read them the other way round, so a charging
battery showed as discharging (srcfl/device-drivers#263).
The values are synthetic, not a capture.
"""

import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"
HARNESS = ROOT / "drivers" / "tests" / "lua_harness"
DRIVER = ROOT / "drivers" / "lua" / "growatt.lua"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")


def battery_w(*, discharge_raw: int, charge_raw: int) -> float:
    """Poll once with a present battery and return battery.w."""
    script = f'''
package.path = "{HARNESS}/?.lua;" .. package.path
require("host_mock")
host.reset()
local input = host._modbus_registers.input
input[1009] = {{0, {discharge_raw}}}   -- Pdischarge1, 0.1 W
input[1011] = {{0, {charge_raw}}}      -- Pcharge1, 0.1 W
input[1013] = {{520}}                  -- 52.0 V
input[1014] = {{60}}                   -- 60 %
dofile("{DRIVER}")
driver_init({{}})
local ok, err = pcall(driver_poll)
if not ok then print("POLL_ERROR " .. tostring(err)) os.exit(1) end
local bat = host._emitted.battery and host._emitted.battery[1]
print("W " .. tostring(bat and bat.w))
'''
    result = subprocess.run([str(LUA), "-e", script],
                            capture_output=True, text=True, cwd=ROOT)
    assert result.returncode == 0, result.stdout + result.stderr
    out = dict(line.split(" ", 1)
               for line in result.stdout.strip().splitlines() if " " in line)
    assert out["W"] != "nil", result.stdout
    return float(out["W"])


def test_growatt_charging_battery_is_positive():
    # 1011 says 2500 W of charge, 1009 says no discharge.
    assert battery_w(discharge_raw=0, charge_raw=25000) == pytest.approx(2500.0)


def test_growatt_discharging_battery_is_negative():
    # 1009 says 1800 W of discharge, 1011 says no charge.
    assert battery_w(discharge_raw=18000, charge_raw=0) == pytest.approx(-1800.0)
