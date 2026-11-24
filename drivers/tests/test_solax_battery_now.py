"""SolaX: what the battery can do now, and the battery temperature in degrees.

SolaX's "Energy Storage Inverter Modbus TCP&RTU Communication protocols"
V3.28 (X1/X3 Hybrid G4) gives the BMS charge and discharge max current at
input 0x0024 and 0x0025 in 0.1 A, "real time". The driver sends them as
watts, multiplied by the battery voltage (0x0014) of the same poll. The
battery temperature (0x0018) and radiator temperature (0x0008) are whole
degrees; releases before 1.2.0 scaled the battery one by 0.1.
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
DRIVER = ROOT / "drivers" / "lua" / "solax.lua"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")

FIELDS = ["temperature_C", "available_charge_W", "available_discharge_W"]
METRICS = [
    "battery_temp_c",
    "battery_charge_limit_a", "battery_discharge_limit_a",
    "battery_available_charge_w", "battery_available_discharge_w",
    "inverter_temp_c",
]


def _lua_list(values) -> str:
    return "{" + ", ".join(str(v) for v in values) + "}"


def registers(*, volts_raw=3200, charge_raw=250, discharge_raw=300,
              bat_temp_raw=24, inv_temp_raw=38) -> dict[int, list[int]]:
    """A 320.0 V HV pack allowed 25.0 A charge and 30.0 A discharge."""
    return {
        0x14: [volts_raw],
        0x24: [charge_raw, discharge_raw],
        0x18: [bat_temp_raw],
        0x08: [inv_temp_raw],
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


def test_solax_reports_bms_limits_in_watts():
    out = poll(registers())
    # 25.0 A and 30.0 A at 320.0 V.
    assert close(num(out, "F_available_charge_W"), 8000)
    assert close(num(out, "F_available_discharge_W"), 9600)
    assert close(num(out, "M_battery_charge_limit_a"), 25.0)
    assert close(num(out, "M_battery_discharge_limit_a"), 30.0)
    assert close(num(out, "M_battery_available_charge_w"), 8000)
    assert close(num(out, "M_battery_available_discharge_w"), 9600)


def test_solax_battery_temperature_is_whole_degrees():
    out = poll(registers())
    assert close(num(out, "F_temperature_C"), 24)
    assert close(num(out, "M_battery_temp_c"), 24)
    assert close(num(out, "M_inverter_temp_c"), 38)


def test_solax_zero_limit_means_not_allowed_now():
    out = poll(registers(discharge_raw=0))
    assert close(num(out, "F_available_charge_W"), 8000)
    assert num(out, "F_available_discharge_W") == 0


def test_solax_failed_reads_leave_fields_out_not_zero():
    out = poll(registers(), fail=(0x24, 0x18, 0x08))
    assert out["BATTERY"] == "true"
    for field in FIELDS:
        assert out[f"F_{field}"] == "nil", field
    for metric in METRICS:
        assert out[f"M_{metric}"] == "nil", metric


def test_solax_no_pack_voltage_means_no_temperature_or_limits():
    """A hybrid without a pack answers zeros: not a cold battery at 0 W."""
    out = poll(registers(volts_raw=0, bat_temp_raw=0, charge_raw=0,
                         discharge_raw=0))
    for field in FIELDS:
        assert out[f"F_{field}"] == "nil", field


def test_solax_failed_voltage_read_leaves_watts_out():
    out = poll(registers(), fail=(0x14,))
    assert out["F_available_charge_W"] == "nil"
    assert out["F_available_discharge_W"] == "nil"
    assert out["F_temperature_C"] == "nil"


def test_solax_out_of_range_values_are_dropped():
    out = poll(registers(charge_raw=0xFFFF, discharge_raw=4000,
                         bat_temp_raw=0x10000 - 50, inv_temp_raw=450))
    assert out["F_available_charge_W"] == "nil"      # 6553.5 A
    assert out["F_available_discharge_W"] == "nil"   # 400 A x 320 V = 128 kW
    assert out["F_temperature_C"] == "nil"           # -50 C
    assert out["M_inverter_temp_c"] == "nil"         # 450 C
