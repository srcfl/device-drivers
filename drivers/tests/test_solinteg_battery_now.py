"""Solinteg: battery, cell and inverter temperature, never an invented 0 C.

The 33000 block is the BMS's. 33003 is the pack temperature, 33009 and
33011 the max and min cell temperature, and 11032 the inverter's first
temperature sensor, all in 0.1 C (M-TEC Energy Butler RTU protocol,
croedel/MTECmqtt, homeassistant-solax-modbus). No source settles the address
of a live charge or discharge limit, so the driver sends no available_*
figures. See docs/WRITING-A-DRIVER.md, "What a battery can do now".
The values are synthetic, not a capture.
"""

import math
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"
HARNESS = ROOT / "drivers" / "tests" / "lua_harness"
DRIVER = ROOT / "drivers" / "lua" / "solinteg.lua"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")

FIELDS = ["temperature_C", "available_charge_W", "available_discharge_W"]
PV_FIELDS = ["temperature_C"]
METRICS = ["battery_temp_c", "battery_cell_temp_max_c",
           "battery_cell_temp_min_c", "inverter_temp_c",
           "battery_available_charge_w"]


def _lua_list(values) -> str:
    return "{" + ", ".join(str(v) for v in values) + "}"


def registers(*, volts_raw=5120, pack_raw=226, cell_max_raw=241,
              cell_min_raw=215, inv_raw=402) -> dict[int, list[int]]:
    return {
        30254: [volts_raw, 0, 1, 0, 0, 0],      # 512.0 V, charging
        33003: [pack_raw],
        33009: [cell_max_raw, 0, cell_min_raw],
        11032: [inv_raw],
    }


def poll(regs: dict[int, list[int]], fail: tuple[int, ...] = ()) -> dict[str, str]:
    setup = "\n".join(
        f"host._modbus_registers.holding[{addr}] = {_lua_list(vals)}"
        for addr, vals in regs.items())
    setup += "\n" + "\n".join(
        f'host._modbus_read_fail_addresses[{addr}] = "Illegal Data Address"'
        for addr in fail)
    fields = ", ".join(f'"{f}"' for f in FIELDS)
    pv_fields = ", ".join(f'"{f}"' for f in PV_FIELDS)
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
local pv = host._emitted.pv and host._emitted.pv[1]
print("BATTERY " .. tostring(bat ~= nil))
for _, k in ipairs({{{fields}}}) do print("F_" .. k .. " " .. tostring(bat and bat[k])) end
for _, k in ipairs({{{pv_fields}}}) do print("PV_" .. k .. " " .. tostring(pv and pv[k])) end
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


def test_solinteg_reports_pack_cell_and_inverter_temperatures():
    out = poll(registers())
    assert close(num(out, "F_temperature_C"), 22.6)
    assert close(num(out, "M_battery_temp_c"), 22.6)
    assert close(num(out, "M_battery_cell_temp_max_c"), 24.1)
    assert close(num(out, "M_battery_cell_temp_min_c"), 21.5)
    assert close(num(out, "PV_temperature_C"), 40.2)
    assert close(num(out, "M_inverter_temp_c"), 40.2)


def test_solinteg_sends_no_limits_it_cannot_place():
    out = poll(registers())
    assert out["F_available_charge_W"] == "nil"
    assert out["F_available_discharge_W"] == "nil"
    assert out["M_battery_available_charge_w"] == "nil"


def test_solinteg_failed_reads_leave_temperatures_out_not_zero():
    out = poll(registers(), fail=(33003, 33009, 11032))
    assert out["BATTERY"] == "true"
    assert out["F_temperature_C"] == "nil"
    assert out["PV_temperature_C"] == "nil"
    for metric in METRICS:
        assert out[f"M_{metric}"] == "nil", metric


def test_solinteg_no_pack_voltage_means_no_battery_temperatures():
    """A hybrid without a pack answers zeros. That is not a battery at 0 C."""
    out = poll(registers(volts_raw=0, pack_raw=0, cell_max_raw=0,
                         cell_min_raw=0))
    assert out["F_temperature_C"] == "nil"
    assert out["M_battery_temp_c"] == "nil"
    assert out["M_battery_cell_temp_max_c"] == "nil"
    assert out["M_battery_cell_temp_min_c"] == "nil"


def test_solinteg_out_of_range_temperatures_are_dropped():
    out = poll(registers(pack_raw=0x10000 - 450, cell_max_raw=0xFFFF,
                         cell_min_raw=1010, inv_raw=0x7FFF))
    assert out["F_temperature_C"] == "nil"           # -45.0 C
    assert out["M_battery_cell_temp_max_c"] == "nil"
    assert out["M_battery_cell_temp_min_c"] == "nil"  # 101.0 C
    assert out["PV_temperature_C"] == "nil"
    assert out["M_inverter_temp_c"] == "nil"
