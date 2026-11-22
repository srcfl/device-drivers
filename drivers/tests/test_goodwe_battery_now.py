"""GoodWe: what the battery can do now, and no invented temperature.

Core judges a battery against what its BMS allows now. The driver reads
GoodWe's "BMS Operation Data" block (37000-37023) for the pack temperature,
the BMS charge and discharge current limits and the cell temperature
extremes, and multiplies the limits by the battery 1 voltage (35180) read
in the same poll. The block counts only while 37011 names a BMS protocol:
a battery with no BMS link answers zeros. See docs/WRITING-A-DRIVER.md,
"What a battery can do now".

The values come from GoodWe's "Modbus Protocol Hybrid for Energy Storage
Inverters" (2 February 2024). They are synthetic here, not a capture.
"""

import math
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"
HARNESS = ROOT / "drivers" / "tests" / "lua_harness"
DRIVER = ROOT / "drivers" / "lua" / "goodwe.lua"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")

FIELDS = ["temp_c", "available_charge_W", "available_discharge_W"]
METRICS = [
    "battery_temp_c",
    "battery_charge_limit_a", "battery_discharge_limit_a",
    "battery_available_charge_w", "battery_available_discharge_w",
    "battery_cell_temp_max_c", "battery_cell_temp_min_c",
    "inverter_temp_c",
]


def _lua_list(values) -> str:
    return "{" + ", ".join(str(v) for v in values) + "}"


PYLONTECH = 0x101       # GoodWe Table 8-33
EMS_BATTERY = 0x11F     # "no direct communication between inverter and battery"


def registers(*, volts_raw=4000, mode=3, pack_raw=251, charge_a=25,
              discharge_a=30, cell_max_raw=280, cell_min_raw=230,
              sink_raw=455, protocol=PYLONTECH) -> dict[int, list[int]]:
    """A charging HV pack at 400.0 V. Raw values as the registers hold them."""
    bms = [0] * 24
    bms[11] = protocol         # 37011, battery protocol
    bms[3] = pack_raw          # 37003, 0.1 C
    bms[4] = charge_a          # 37004, A
    bms[5] = discharge_a       # 37005, A
    bms[20] = cell_max_raw     # 37020, 0.1 C
    bms[21] = cell_min_raw     # 37021, 0.1 C
    return {
        35180: [volts_raw, 0, 0, 0, mode],   # V1, I1, P1 (2), mode
        37000: bms,
        35176: [sink_raw],
    }


def poll(regs: dict[int, list[int]], fail: tuple[int, ...] = (),
         polls: int = 1) -> dict[str, str]:
    setup = "\n".join(
        f"host._modbus_registers.holding[{addr}] = {_lua_list(vals)}"
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
for i = 1, {polls} do
    host._emitted = {{}}
    host._metrics = {{}}
    local ok, err = pcall(driver_poll)
    if not ok then print("POLL_ERROR " .. tostring(err)) os.exit(1) end
end
local list = host._emitted.battery
local bat = list and list[#list]
print("BATTERY " .. tostring(bat ~= nil))
for _, k in ipairs({{{fields}}}) do print("F_" .. k .. " " .. tostring(bat and bat[k])) end
for _, k in ipairs({{{metrics}}}) do
    local m = host._metrics[k]
    print("M_" .. k .. " " .. tostring(m and m.value))
end
local reads = {{}}
for _, c in ipairs(host._calls) do
    if c.func == "modbus_read" then reads[#reads + 1] = tostring(c.args[1]) end
end
print("READS " .. table.concat(reads, ","))
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


def test_goodwe_reports_bms_temperature_and_limits_in_watts():
    out = poll(registers())
    assert out["BATTERY"] == "true"
    assert close(num(out, "F_temp_c"), 25.1)
    # 25 A and 30 A at 400.0 V.
    assert close(num(out, "F_available_charge_W"), 10000)
    assert close(num(out, "F_available_discharge_W"), 12000)

    assert close(num(out, "M_battery_temp_c"), 25.1)
    assert close(num(out, "M_battery_charge_limit_a"), 25)
    assert close(num(out, "M_battery_discharge_limit_a"), 30)
    assert close(num(out, "M_battery_available_charge_w"), 10000)
    assert close(num(out, "M_battery_available_discharge_w"), 12000)
    assert close(num(out, "M_battery_cell_temp_max_c"), 28.0)
    assert close(num(out, "M_battery_cell_temp_min_c"), 23.0)
    assert close(num(out, "M_inverter_temp_c"), 45.5)


def test_goodwe_negative_pack_temperature_keeps_its_sign():
    out = poll(registers(pack_raw=0x10000 - 52))   # -5.2 C
    assert close(num(out, "F_temp_c"), -5.2)


def test_goodwe_zero_limit_means_not_allowed_now():
    out = poll(registers(charge_a=0))
    assert num(out, "F_available_charge_W") == 0
    assert close(num(out, "F_available_discharge_W"), 12000)


def test_goodwe_no_battery_mode_leaves_bms_figures_out():
    """Mode 0 is "no battery": the BMS block is not read and nothing is sent."""
    out = poll(registers(mode=0))
    assert out["BATTERY"] == "true"
    for field in FIELDS:
        assert out[f"F_{field}"] == "nil", field
    for metric in METRICS[:-1]:
        assert out[f"M_{metric}"] == "nil", metric
    assert "37000" not in out["READS"].split(",")


def test_goodwe_battery_without_a_talking_bms_sends_nothing():
    """Mode 1 says a battery is there; an all-zero block says no BMS talks.

    0 C and 0 W would read as a cold battery that may not charge.
    """
    zeros = registers(mode=1)
    zeros[37000] = [0] * 24
    out = poll(zeros)
    assert out["BATTERY"] == "true"
    for field in FIELDS:
        assert out[f"F_{field}"] == "nil", field
    for metric in METRICS[:-1]:
        assert out[f"M_{metric}"] == "nil", metric


@pytest.mark.parametrize("protocol", [0, EMS_BATTERY, 0xFFFF])
def test_goodwe_no_direct_bms_link_sends_no_bms_figures(protocol):
    out = poll(registers(protocol=protocol))
    for field in FIELDS:
        assert out[f"F_{field}"] == "nil", field
    for metric in METRICS[:-1]:
        assert out[f"M_{metric}"] == "nil", metric


def test_goodwe_talking_bms_with_zero_limits_still_says_zero():
    """A BMS that talks and allows nothing is not hidden."""
    out = poll(registers(charge_a=0, discharge_a=0, protocol=0x122))
    assert num(out, "F_available_charge_W") == 0
    assert num(out, "F_available_discharge_W") == 0
    assert close(num(out, "F_temp_c"), 25.1)


def test_goodwe_failed_bms_read_leaves_fields_out_not_zero():
    out = poll(registers(), fail=(37000,))
    assert out["BATTERY"] == "true"
    for field in FIELDS:
        assert out[f"F_{field}"] == "nil", field
    for metric in METRICS[:-1]:
        assert out[f"M_{metric}"] == "nil", metric


def test_goodwe_failed_voltage_read_leaves_limits_out():
    out = poll(registers(), fail=(35180,))
    assert out["F_available_charge_W"] == "nil"
    assert out["F_available_discharge_W"] == "nil"
    assert out["M_battery_charge_limit_a"] == "nil"


def test_goodwe_zero_voltage_gives_no_watts():
    out = poll(registers(volts_raw=0))
    assert close(num(out, "F_temp_c"), 25.1)
    assert out["F_available_charge_W"] == "nil"
    assert out["F_available_discharge_W"] == "nil"


def test_goodwe_out_of_range_values_are_dropped():
    out = poll(registers(pack_raw=1500, cell_max_raw=0xFFFF, cell_min_raw=0x7FFF,
                         charge_a=300, discharge_a=65535, sink_raw=0xFFFF))
    assert out["F_temp_c"] == "nil"               # 150.0 C
    assert out["M_battery_temp_c"] == "nil"
    assert out["M_battery_cell_temp_max_c"] == "nil"   # 0xFFFF: no value
    assert out["M_battery_cell_temp_min_c"] == "nil"   # 0x7FFF: no value
    assert out["F_available_charge_W"] == "nil"   # 300 A x 400 V = 120 kW
    assert out["M_battery_charge_limit_a"] == "nil"
    assert out["F_available_discharge_W"] == "nil"
    assert out["M_inverter_temp_c"] == "nil"


def test_goodwe_absent_bms_block_settles():
    """Three failures, then the driver stops asking, as for every register."""
    out = poll(registers(), fail=(37000,), polls=8)
    assert out["READS"].split(",").count("37000") == 3
