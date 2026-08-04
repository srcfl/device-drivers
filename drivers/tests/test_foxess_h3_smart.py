"""The H3-Smart map driver must reproduce its hardware capture.

Every expected value below comes from a live read of a 1K5-HI-10-V1
(three-phase hybrid, one battery string, mid-generation): the strings
were making 3121 W and 3475 W, the battery was charging at 3727 W and
93% SoC, and the site was exporting 2004.5 W. The driver's job is to
turn those vendor-sign registers into site-convention telemetry, so the
test asserts the emitted signs and scales against what the hardware
actually said.

The device answers unknown registers with silence rather than a Modbus
exception, so each block read that fails must drop its emit rather than
fabricate zeros — a zero-watt meter reading is an instruction to the
controller, not an absence.
"""

from __future__ import annotations

import math
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"
HARNESS = ROOT / "drivers" / "tests" / "lua_harness"
DRIVER = ROOT / "drivers" / "lua" / "foxess_h3_smart.lua"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")


def _ascii_regs(text: str, width: int) -> list[int]:
    """Pack ASCII into `width` big-endian 16-bit registers, NUL padded."""
    padded = text.encode("ascii").ljust(width * 2, b"\x00")
    return [padded[i] << 8 | padded[i + 1] for i in range(0, width * 2, 2)]


def _i32_regs(value: int) -> tuple[int, int]:
    """Split a signed 32-bit value into (high, low) registers."""
    raw = value & 0xFFFFFFFF
    return raw >> 16, raw & 0xFFFF


def _lua_list(values) -> str:
    return "{" + ", ".join(str(v) for v in values) + "}"


# The capture: vendor signs, raw register units.
MODEL = "1K5-HI-10-V1"
SERIAL = "TESTSN12345"

BAT_POWER_RAW = -3727     # vendor: negative = charging
BAT_CURRENT_RAW = -15000  # mA, follows the power's sign
CT_RAW = 20045            # 0.1 W, vendor: positive = export


def fixture_registers() -> str:
    """Lua statements loading the capture into the mock's register map."""
    bat_w_hi, bat_w_lo = _i32_regs(BAT_POWER_RAW)
    bat_a_hi, bat_a_lo = _i32_regs(BAT_CURRENT_RAW)
    singles = {
        # status block: pv V/A, grid V, frequency, inverter temp
        39070: 2752, 39071: 1130, 39072: 3043, 39073: 1140,
        39123: 2352, 39124: 2344, 39125: 2357, 39139: 4999, 39141: 354,
        # power block: battery voltage/current/power (inverter side)
        39227: 1839,
        39228: bat_a_hi, 39229: bat_a_lo,
        39237: bat_w_hi, 39238: bat_w_lo,
        # energy counters, u32 pairs in 0.01 kWh
        39601: _i32_regs(123456)[0], 39602: _i32_regs(123456)[1],
        39613: _i32_regs(111111)[0], 39614: _i32_regs(111111)[1],
        39617: _i32_regs(654321)[0], 39618: _i32_regs(654321)[1],
        # BMS singles
        37611: 354, 37612: 93,
    }
    lines = [
        "host._modbus_registers.holding[30000] = "
        + _lua_list(_ascii_regs(MODEL, 16) + _ascii_regs(SERIAL, 16)),
        "host._modbus_registers.holding[39279] = "
        + _lua_list([0, 3121, 0, 3475, 0, 0, 0, 0]),
        "host._modbus_registers.holding[38814] = "
        + _lua_list(_i32_regs(CT_RAW)),
    ]
    lines += [
        f"host._modbus_registers.holding[{addr}] = {value}"
        for addr, value in singles.items()
    ]
    return "\n".join(lines)


def run_lua(body: str) -> dict[str, str]:
    script = f'''
package.path = "{HARNESS}/?.lua;" .. package.path
require("host_mock")
host.reset()
{body}
'''
    result = subprocess.run([str(LUA), "-e", script],
                            capture_output=True, text=True, cwd=ROOT)
    assert result.returncode == 0, result.stdout + result.stderr
    return dict(line.split(" ", 1)
                for line in result.stdout.strip().splitlines() if " " in line)


REPORT = '''
local function last(t) return t and t[#t] or nil end
local pv = last(host._emitted["pv"])
local bat = last(host._emitted["battery"])
local met = last(host._emitted["meter"])
print("PV_EMITS " .. tostring(host._emitted["pv"] and #host._emitted["pv"] or 0))
print("BAT_EMITS " .. tostring(host._emitted["battery"] and #host._emitted["battery"] or 0))
print("MET_EMITS " .. tostring(host._emitted["meter"] and #host._emitted["meter"] or 0))
if pv then
    print("PV_W " .. pv.W)
    print("PV_MPPTS " .. #pv.mppts)
    print("PV_MPPT1_V " .. pv.mppts[1].V)
    print("PV_MPPT2_W " .. pv.mppts[2].W)
    print("PV_GEN_WH " .. tostring(pv.total_generation_Wh))
end
if bat then
    print("BAT_W " .. bat.W)
    print("BAT_V " .. bat.V)
    print("BAT_A " .. bat.A)
    print("BAT_SOC " .. tostring(bat.SoC_nom_fract))
    print("BAT_TEMP " .. tostring(bat.temperature_C))
end
if met then
    print("MET_W " .. met.W)
    print("MET_HZ " .. tostring(met.Hz))
    print("MET_L1V " .. tostring(met.L1_V))
    print("MET_IMPORT_WH " .. tostring(met.total_import_Wh))
    print("MET_EXPORT_WH " .. tostring(met.total_export_Wh))
end
print("MAKE " .. tostring(host._make))
print("MODEL " .. tostring(host._model))
print("SN " .. tostring(host._sn))
'''


def poll_once(extra: str = "") -> dict[str, str]:
    return run_lua(f'''
{fixture_registers()}
{extra}
dofile("{DRIVER}")
driver_init({{}})
local ok, err = pcall(driver_poll)
if not ok then print("POLL_ERROR " .. tostring(err)) os.exit(1) end
{REPORT}
''')


def test_capture_reproduces_in_site_convention():
    out = poll_once()

    # PV: two fitted strings, generation negative, absent strings dropped.
    assert out["PV_EMITS"] == "1"
    assert float(out["PV_W"]) == -(3121 + 3475)
    assert out["PV_MPPTS"] == "2"
    assert math.isclose(float(out["PV_MPPT1_V"]), 275.2, rel_tol=1e-5)
    assert float(out["PV_MPPT2_W"]) == 3475
    assert float(out["PV_GEN_WH"]) == 1234560

    # Battery: vendor negative-charging flips to site positive-charging.
    assert float(out["BAT_W"]) == 3727
    assert math.isclose(float(out["BAT_V"]), 183.9, rel_tol=1e-5)
    assert math.isclose(float(out["BAT_A"]), 15.0, rel_tol=1e-5)
    assert math.isclose(float(out["BAT_SOC"]), 0.93, rel_tol=1e-5)
    assert math.isclose(float(out["BAT_TEMP"]), 35.4, rel_tol=1e-5)

    # Meter: vendor positive-export flips to site negative-export.
    assert math.isclose(float(out["MET_W"]), -2004.5, rel_tol=1e-5)
    assert math.isclose(float(out["MET_HZ"]), 49.99, rel_tol=1e-5)
    assert math.isclose(float(out["MET_L1V"]), 235.2, rel_tol=1e-5)
    assert float(out["MET_IMPORT_WH"]) == 6543210
    assert float(out["MET_EXPORT_WH"]) == 1111110


def test_identity_reported_from_registers():
    out = poll_once()
    assert out["MAKE"] == "FoxESS"
    assert out["MODEL"] == MODEL
    assert out["SN"] == SERIAL


def test_meter_dropped_when_ct_read_fails():
    out = poll_once('host._modbus_read_fail_addresses[38814] = "timeout"')
    assert out["MET_EMITS"] == "0"
    assert out["PV_EMITS"] == "1"
    assert out["BAT_EMITS"] == "1"


def test_battery_dropped_when_power_block_fails():
    out = poll_once('host._modbus_read_fail_addresses[39219] = "timeout"')
    assert out["BAT_EMITS"] == "0"
    assert out["PV_EMITS"] == "1"


def test_soc_omitted_when_bms_is_silent():
    """A silent BMS register loses the field, never the power reading."""
    out = poll_once('host._modbus_read_fail_addresses[37612] = "timeout"')
    assert out["BAT_EMITS"] == "1"
    assert out["BAT_SOC"] == "nil"
    assert float(out["BAT_W"]) == 3727


def test_identity_retries_until_model_answers():
    out = run_lua(f'''
{fixture_registers()}
host._modbus_read_fail_addresses[30000] = "timeout"
dofile("{DRIVER}")
driver_init({{}})
pcall(driver_poll)
print("MODEL_FIRST " .. tostring(host._model))
host._modbus_read_fail_addresses[30000] = nil
pcall(driver_poll)
print("MODEL_SECOND " .. tostring(host._model))
''')
    assert out["MODEL_FIRST"] == "nil"
    assert out["MODEL_SECOND"] == MODEL
