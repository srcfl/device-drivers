"""Sofar: battery and inverter temperature, never an invented 0 C.

SofarSolar's Modbus protocol (V1.2) has the battery temperature at 0x0607
and the heat sink temperature at 0x041A, both whole degrees. It has no live
BMS charge or discharge limit, so the driver sends no available_* figures.
See docs/WRITING-A-DRIVER.md, "What a battery can do now".
The values are synthetic, not a capture.
"""

import math
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"
HARNESS = ROOT / "drivers" / "tests" / "lua_harness"
DRIVER = ROOT / "drivers" / "lua" / "sofar.lua"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")

FIELDS = ["temp_c", "available_charge_W", "available_discharge_W"]
METRICS = ["battery_temp_c", "inverter_temp_c",
           "battery_available_charge_w", "battery_available_discharge_w"]


def registers(*, volts_raw=512, bat_temp_raw=19, sink_raw=47) -> dict[int, int]:
    return {
        1540: volts_raw,      # 0x0604 battery voltage, 0.1 V
        1543: bat_temp_raw,   # 0x0607 battery temperature, 1 C
        1050: sink_raw,       # 0x041A heat sink 1, 1 C
    }


def poll(regs: dict[int, int], fail: tuple[int, ...] = ()) -> dict[str, str]:
    setup = "\n".join(
        f"host._modbus_registers.holding[{addr}] = {val}"
        for addr, val in regs.items())
    setup += "\n" + "\n".join(
        f'host._modbus_read_fail_addresses[{addr}] = "Illegal Data Address"'
        for addr in fail)
    fields = ", ".join(f'"{f}"' for f in FIELDS)
    metrics = ", ".join(f'"{m}"' for m in METRICS)
    script = f'''
package.path = "{HARNESS}/?.lua;" .. package.path
require("host_mock")
host.reset()
{setup}
dofile("{DRIVER}")
driver_init({{}})
local ok, err = pcall(driver_poll)
if not ok then print("POLL_ERROR " .. tostring(err)) os.exit(1) end
local bat = host._emitted.battery and host._emitted.battery[1]
print("BATTERY " .. tostring(bat ~= nil))
for _, k in ipairs({{{fields}}}) do print("F_" .. k .. " " .. tostring(bat and bat[k])) end
for _, k in ipairs({{{metrics}}}) do
    local m = host._metrics[k]
    print("M_" .. k .. " " .. tostring(m and m.value))
end
'''
    result = subprocess.run([str(LUA), "-e", script],
                            capture_output=True, text=True, cwd=ROOT)
    assert result.returncode == 0, result.stdout + result.stderr
    return dict(line.split(" ", 1)
                for line in result.stdout.strip().splitlines() if " " in line)


def num(out: dict[str, str], key: str):
    value = out[key]
    return None if value == "nil" else float(value)


def close(actual, expected):
    return actual is not None and math.isclose(actual, expected, rel_tol=1e-5)


def test_sofar_reports_whole_degree_temperatures():
    out = poll(registers())
    assert close(num(out, "F_temp_c"), 19)
    assert close(num(out, "M_battery_temp_c"), 19)
    assert close(num(out, "M_inverter_temp_c"), 47)


def test_sofar_negative_battery_temperature_keeps_its_sign():
    out = poll(registers(bat_temp_raw=0x10000 - 7))
    assert close(num(out, "F_temp_c"), -7)


def test_sofar_sends_no_limits_it_cannot_read():
    out = poll(registers())
    assert out["F_available_charge_W"] == "nil"
    assert out["F_available_discharge_W"] == "nil"
    assert out["M_battery_available_charge_w"] == "nil"


def test_sofar_failed_reads_leave_temperatures_out_not_zero():
    out = poll(registers(), fail=(1543, 1050))
    assert out["BATTERY"] == "true"
    assert out["F_temp_c"] == "nil"
    assert out["M_battery_temp_c"] == "nil"
    assert out["M_inverter_temp_c"] == "nil"


def test_sofar_no_pack_voltage_means_no_battery_temperature():
    """A hybrid without a pack answers 0. That is not a battery at 0 C."""
    out = poll(registers(volts_raw=0, bat_temp_raw=0))
    assert out["F_temp_c"] == "nil"
    assert out["M_battery_temp_c"] == "nil"


def test_sofar_out_of_range_temperatures_are_dropped():
    out = poll(registers(bat_temp_raw=0x7FFF, sink_raw=0x10000 - 60))
    assert out["F_temp_c"] == "nil"
    assert out["M_inverter_temp_c"] == "nil"
