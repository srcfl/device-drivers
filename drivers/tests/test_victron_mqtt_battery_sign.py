"""victron_mqtt: battery power keeps Victron's sign, charge positive.

Victron's D-Bus documentation (victronenergy/venus wiki, "dbus") gives the
battery service's /Dc/0/Power as "positive when charged, negative when
discharged". dbus-systemcalc-py copies that value into the system service's
/Dc/Battery/Power, which this driver reads over MQTT, and calls the battery
charging when it is above +30 W. That is the site convention already, so the
driver passes it through. victron.lua reads the same value at Modbus 842 and
does not negate it either. Up to 1.1.0 this driver negated it
(srcfl/device-drivers#255). The values are synthetic, not a capture.
"""

import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"
HARNESS = ROOT / "drivers" / "tests" / "lua_harness"
DRIVER = ROOT / "drivers" / "lua" / "victron_mqtt.lua"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")


def battery_w(victron_w: float) -> float:
    """Feed one Dc/Battery/Power message and return the emitted battery W."""
    script = f'''
package.path = "{HARNESS}/?.lua;" .. package.path
require("host_mock")
host.reset()
dofile("{DRIVER}")
driver_init({{}})
host._mqtt_buffer = {{
    {{ topic = "N/c0ffee/system/0/Dc/Battery/Power",
      payload = '{{"value": {victron_w}}}' }},
}}
local ok, err = pcall(driver_poll)
if not ok then print("POLL_ERROR " .. tostring(err)) os.exit(1) end
local bat = host._emitted.battery and host._emitted.battery[1]
print("W " .. tostring(bat and bat.W))
'''
    result = subprocess.run([str(LUA), "-e", script],
                            capture_output=True, text=True, cwd=ROOT)
    assert result.returncode == 0, result.stdout + result.stderr
    out = dict(line.split(" ", 1)
               for line in result.stdout.strip().splitlines() if " " in line)
    assert out["W"] != "nil", result.stdout
    return float(out["W"])


def test_victron_mqtt_charging_battery_is_positive():
    # Victron: +1500 W, the battery is being charged.
    assert battery_w(1500) == pytest.approx(1500.0)


def test_victron_mqtt_discharging_battery_is_negative():
    # Victron: -900 W, the battery is discharging.
    assert battery_w(-900) == pytest.approx(-900.0)
