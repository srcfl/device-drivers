"""Growatt: battery, cell and inverter temperature, never an invented 0 C.

Growatt's Modbus RTU Protocol II V1.39 gives the battery temperature at
input 1040, the BMS's max and min cell temperature at 1114 and 1115, and the
inverter temperature at 93, all in 0.1 C. Its one BMS current figure (1090,
BMS_MaxCurr) covers charge and discharge together and has no documented
unit, so the driver sends no available_* figures.
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
DRIVER = ROOT / "drivers" / "lua" / "growatt.lua"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")

FIELDS = ["temp_c", "available_charge_W", "available_discharge_W"]
METRICS = ["battery_temp_c", "battery_cell_temp_max_c",
           "battery_cell_temp_min_c", "inverter_temp_c",
           "battery_available_charge_w"]


def _lua_list(values) -> str:
    return "{" + ", ".join(str(v) for v in values) + "}"


def registers(*, volts_raw=520, soc=60, bat_temp_raw=212, cell_max_raw=230,
              cell_min_raw=198, inv_temp_raw=387) -> dict[int, list[int]]:
    return {
        1013: [volts_raw],                  # 52.0 V
        1014: [soc],
        1040: [bat_temp_raw],               # 0.1 C
        1114: [cell_max_raw, cell_min_raw], # 0.1 C
        93: [inv_temp_raw],                 # 0.1 C
    }


def poll(regs: dict[int, list[int]], fail: tuple[int, ...] = ()) -> dict[str, str]:
    setup = "\n".join(
        f"host._modbus_registers.input[{addr}] = {_lua_list(vals)}"
        for addr, vals in regs.items())
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


def test_growatt_reports_battery_cell_and_inverter_temperatures():
    out = poll(registers())
    assert out["BATTERY"] == "true"
    assert close(num(out, "F_temp_c"), 21.2)
    assert close(num(out, "M_battery_temp_c"), 21.2)
    assert close(num(out, "M_battery_cell_temp_max_c"), 23.0)
    assert close(num(out, "M_battery_cell_temp_min_c"), 19.8)
    assert close(num(out, "M_inverter_temp_c"), 38.7)


def test_growatt_sends_no_limits_it_cannot_read():
    out = poll(registers())
    assert out["F_available_charge_W"] == "nil"
    assert out["F_available_discharge_W"] == "nil"
    assert out["M_battery_available_charge_w"] == "nil"


def test_growatt_failed_reads_leave_temperatures_out_not_zero():
    out = poll(registers(), fail=(1040, 1114, 93))
    assert out["BATTERY"] == "true"
    assert out["F_temp_c"] == "nil"
    for metric in METRICS:
        assert out[f"M_{metric}"] == "nil", metric


def test_growatt_pv_only_reports_no_battery_temperatures():
    """No battery: no battery stream and no cell temperatures, but the
    inverter's own temperature still reaches history."""
    out = poll(registers(volts_raw=0, soc=0, bat_temp_raw=0, cell_max_raw=0,
                         cell_min_raw=0))
    assert out["BATTERY"] == "false"
    assert out["M_battery_temp_c"] == "nil"
    assert out["M_battery_cell_temp_max_c"] == "nil"
    assert out["M_battery_cell_temp_min_c"] == "nil"
    assert close(num(out, "M_inverter_temp_c"), 38.7)


def test_growatt_out_of_range_temperatures_are_dropped():
    out = poll(registers(bat_temp_raw=0xFFFF, cell_max_raw=1200,
                         cell_min_raw=0x10000 - 100, inv_temp_raw=1500))
    assert out["F_temp_c"] == "nil"
    assert out["M_battery_temp_c"] == "nil"
    assert out["M_battery_cell_temp_max_c"] == "nil"
    assert out["M_battery_cell_temp_min_c"] == "nil"
    assert out["M_inverter_temp_c"] == "nil"
