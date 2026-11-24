"""Solis: what the battery can do now, and no invented temperature.

Solis's "RS485_MODBUS RTU Hybrid Inverter Protocol" marks the charge and
discharge current limits at 33143 and 33144 "(From BMS)". The driver sends
them as watts, multiplied by the battery voltage (33133) of the same poll,
and only while 33160 names a battery maker: a lead-acid or BMS-less battery
reports 0 A there. See docs/WRITING-A-DRIVER.md, "What a battery can do now".

33096 is the inverter's lead-acid battery probe. Without that probe it reads
200.2 C (Pho3niX90/solis_modbus#186), which the range check drops.
The values are synthetic, not a capture.
"""

import math
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"
HARNESS = ROOT / "drivers" / "tests" / "lua_harness"
DRIVER = ROOT / "drivers" / "lua" / "solis.lua"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")

FIELDS = ["temp_c", "available_charge_W", "available_discharge_W"]
PV_FIELDS = ["temp_c"]
METRICS = [
    "battery_temp_c",
    "battery_charge_limit_a", "battery_discharge_limit_a",
    "battery_available_charge_w", "battery_available_discharge_w",
    "inverter_temp_c",
]


def _lua_list(values) -> str:
    return "{" + ", ".join(str(v) for v in values) + "}"


PYLON_LV = 0x0001   # Solis map, 33160 "Current Battery Model"


def registers(*, volts_raw=512, charge_raw=1000, discharge_raw=1500,
              bat_temp_raw=231, inv_temp_raw=412,
              model=PYLON_LV) -> dict[int, list[int]]:
    """A 51.2 V LV pack allowed 100.0 A charge and 150.0 A discharge."""
    block = [0] * 18                     # 33143-33160, one read
    block[0] = charge_raw                # 33143
    block[1] = discharge_raw             # 33144
    block[17] = model                    # 33160
    return {
        33133: [volts_raw],
        33143: block,
        33096: [bat_temp_raw],
        33093: [inv_temp_raw],
    }


def poll(regs: dict[int, list[int]], fail: tuple[int, ...] = ()) -> dict[str, str]:
    setup = "\n".join(
        f"host._modbus_registers.input[{addr}] = {_lua_list(vals)}"
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


def test_solis_reports_bms_limits_in_watts():
    out = poll(registers())
    # 100.0 A and 150.0 A at 51.2 V.
    assert close(num(out, "F_available_charge_W"), 5120)
    assert close(num(out, "F_available_discharge_W"), 7680)
    assert close(num(out, "M_battery_charge_limit_a"), 100.0)
    assert close(num(out, "M_battery_discharge_limit_a"), 150.0)
    assert close(num(out, "M_battery_available_charge_w"), 5120)
    assert close(num(out, "M_battery_available_discharge_w"), 7680)


@pytest.mark.parametrize("model", [0x0003, 0x0004, 0x0100, 0x0300, 0x0600])
def test_solis_battery_makers_report_limits(model):
    out = poll(registers(model=model))
    assert close(num(out, "F_available_charge_W"), 5120)


@pytest.mark.parametrize("model", [
    0x0000,   # no battery model
    0x0002,   # LV "User define"
    0x0200,   # HV "User define"
    101,      # LV lead-acid (Pho3niX90/solis_modbus battery-model list)
    100,      # LV generic lithium
    0x6300,   # HV generic lithium
    0x0201,   # not a code either list gives
    0xFFFF,
])
def test_solis_no_bms_battery_model_sends_no_limit(model):
    """A lead-acid or BMS-less battery reports 0 A; 0 W would be a lie."""
    out = poll(registers(model=model, charge_raw=0, discharge_raw=0))
    assert out["F_available_charge_W"] == "nil"
    assert out["F_available_discharge_W"] == "nil"
    assert out["M_battery_charge_limit_a"] == "nil"
    assert out["M_battery_available_discharge_w"] == "nil"


def test_solis_reports_temperatures():
    out = poll(registers())
    assert close(num(out, "F_temp_c"), 23.1)
    assert close(num(out, "M_battery_temp_c"), 23.1)
    assert close(num(out, "PV_temp_c"), 41.2)
    assert close(num(out, "M_inverter_temp_c"), 41.2)


def test_solis_zero_limit_means_not_allowed_now():
    out = poll(registers(charge_raw=0))
    assert num(out, "F_available_charge_W") == 0
    assert close(num(out, "F_available_discharge_W"), 7680)


def test_solis_failed_reads_leave_fields_out_not_zero():
    out = poll(registers(), fail=(33143, 33096, 33093))
    assert out["BATTERY"] == "true"
    for field in FIELDS:
        assert out[f"F_{field}"] == "nil", field
    assert out["PV_temp_c"] == "nil"
    for metric in METRICS:
        assert out[f"M_{metric}"] == "nil", metric


def test_solis_failed_voltage_read_leaves_watts_out():
    out = poll(registers(), fail=(33133,))
    assert out["F_available_charge_W"] == "nil"
    assert out["F_available_discharge_W"] == "nil"
    assert out["M_battery_charge_limit_a"] == "nil"


def test_solis_zero_voltage_gives_no_watts():
    out = poll(registers(volts_raw=0))
    assert out["F_available_charge_W"] == "nil"
    assert out["F_available_discharge_W"] == "nil"


def test_solis_missing_lead_acid_probe_is_dropped():
    """Without a lead-acid probe 33096 reads 200.2 C. That is not a battery."""
    out = poll(registers(bat_temp_raw=2002))
    assert out["F_temp_c"] == "nil"
    assert out["M_battery_temp_c"] == "nil"


def test_solis_out_of_range_values_are_dropped():
    out = poll(registers(charge_raw=0xFFFF, discharge_raw=25000,
                         inv_temp_raw=0x10000 - 450))
    assert out["F_available_charge_W"] == "nil"      # 6553.5 A
    assert out["F_available_discharge_W"] == "nil"   # 2500 A x 51.2 V = 128 kW
    assert out["M_battery_charge_limit_a"] == "nil"
    assert out["PV_temp_c"] == "nil"                 # -45.0 C
    assert out["M_inverter_temp_c"] == "nil"
