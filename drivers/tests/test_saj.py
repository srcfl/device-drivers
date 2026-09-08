"""SAJ H2/HS2 driver: H2-Protocol holding map, no fabricated zeros.

The previous stub read untested input registers around 0x10xx, defaulted
every field to zero, and emitted a battery on AS2 string inverters that
have no pack. This suite holds the rewrite to the H2 holding map used by
evcc saj-h2 and stanus74/home-assistant-saj-h2-modbus, and to the rule
that a missing register is silence, not a zero.
"""

from __future__ import annotations

import math
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"
HARNESS = ROOT / "drivers" / "tests" / "lua_harness"
DRIVER = ROOT / "drivers" / "lua" / "saj.lua"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")


def _ascii_regs(text: str, width: int) -> list[int]:
    padded = text.encode("ascii").ljust(width * 2, b"\x00")
    return [padded[i] << 8 | padded[i + 1] for i in range(0, width * 2, 2)]


def _i16(value: int) -> int:
    return value & 0xFFFF


def _u32_regs(value: int) -> tuple[int, int]:
    return (value >> 16) & 0xFFFF, value & 0xFFFF


def _lua_list(values) -> str:
    return "{" + ", ".join(str(v) for v in values) + "}"


SERIAL = "H2TESTSN0001"

# Vendor signs, raw register units.
PV_W_VENDOR = 3200          # generation magnitude
BAT_W_VENDOR = -1800        # discharge-positive: negative = charging
GRID_W_VENDOR = 400         # import-positive
SOC_RAW = 8500              # 0.01 % → 85.00 %
BAT_V_RAW = 512             # 0.1 V → 51.2 V
BAT_A_VENDOR = -3500        # 0.01 A, discharge-positive → charging 35 A
BAT_TEMP_RAW = 254          # 0.1 °C → 25.4 °C
PV_ENERGY_RAW = 123456      # 0.01 kWh
BAT_CHARGE_RAW = 50000
BAT_DISCHARGE_RAW = 40000


def fixture_registers(*, pack: bool = True) -> str:
    """Load a three-phase H2 hybrid. `pack=False` is an AS2 / PV-only H2."""
    info = [0] * 29
    info[0] = 0x0200  # devtype, not a sentinel
    info[1] = 0x0001
    sn = _ascii_regs(SERIAL, 10)
    for i, word in enumerate(sn):
        info[3 + i] = word

    power = [0] * 9
    power[0] = _i16(PV_W_VENDOR)
    power[1] = _i16(BAT_W_VENDOR)
    power[8] = _i16(GRID_W_VENDOR)

    strings = [0] * 15
    strings[0] = _i16(BAT_TEMP_RAW)
    strings[3] = 2752   # pv1 V 275.2
    strings[4] = 1130   # pv1 A 11.30
    strings[5] = 1800   # pv1 W
    strings[6] = 3043   # pv2 V 304.3
    strings[7] = 1140   # pv2 A 11.40
    strings[8] = 1400   # pv2 W

    # 7 registers per phase: V, A, Hz, DCI, W, VA, PF
    phases = [0] * 21
    for phase in range(3):
        base = phase * 7
        phases[base] = 2350 + phase     # 235.0 / 235.1 / 235.2 V
        phases[base + 1] = _i16(500)    # 5.00 A
        phases[base + 2] = 5001         # 50.01 Hz
        phases[base + 4] = _i16(200 - phase * 50)

    bms = [0] * 18
    if pack:
        bms[0] = 1          # BatNum
        bms[1] = 100        # BatCapcity (Ah, unit not claimed as Wh)
        bms[11] = 1         # BatOnline
        bms[12] = SOC_RAW
        bms[13] = 9800      # SOH 98.00 %
        bms[14] = BAT_V_RAW
        bms[15] = _i16(BAT_A_VENDOR)
        bms[16] = _i16(BAT_TEMP_RAW)
        bms[17] = 42
    # else: BatNum=0, BatOnline=0 — present, but no pack.

    pv_e_hi, pv_e_lo = _u32_regs(PV_ENERGY_RAW)
    chg_hi, chg_lo = _u32_regs(BAT_CHARGE_RAW)
    dis_hi, dis_lo = _u32_regs(BAT_DISCHARGE_RAW)

    return "\n".join([
        "host._modbus_registers.holding[36608] = " + _lua_list(info),
        "host._modbus_registers.holding[16549] = " + _lua_list(power),
        "host._modbus_registers.holding[16494] = " + _lua_list(strings),
        "host._modbus_registers.holding[16433] = " + _lua_list(phases),
        "host._modbus_registers.holding[40960] = " + _lua_list(bms),
        "host._modbus_registers.holding[16581] = " + _lua_list([pv_e_hi, pv_e_lo]),
        "host._modbus_registers.holding[16589] = " + _lua_list([chg_hi, chg_lo]),
        "host._modbus_registers.holding[16597] = " + _lua_list([dis_hi, dis_lo]),
    ])


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
    print("PV_W " .. tostring(pv.W))
    print("PV_MPPT1_V " .. tostring(pv.mppt1_v))
    print("PV_MPPT2_W " .. tostring(pv.mppt2_w))
    print("PV_GEN_WH " .. tostring(pv.lifetime_wh))
end
if bat then
    print("BAT_W " .. tostring(bat.W))
    print("BAT_V " .. tostring(bat.V))
    print("BAT_A " .. tostring(bat.A))
    print("BAT_SOC " .. tostring(bat.SoC_nom_fract))
    print("BAT_TEMP " .. tostring(bat.temperature_C))
    print("BAT_CHG_WH " .. tostring(bat.total_charge_Wh))
    print("BAT_DIS_WH " .. tostring(bat.total_discharge_Wh))
end
if met then
    print("MET_W " .. tostring(met.W))
    print("MET_HZ " .. tostring(met.Hz))
    print("MET_L1V " .. tostring(met.L1_V))
    print("MET_L1W " .. tostring(met.L1_W))
    print("MET_L2W " .. tostring(met.L2_W))
end
print("MAKE " .. tostring(host._make))
print("SN " .. tostring(host._sn))
'''


def poll_once(extra: str = "", pack: bool = True) -> dict[str, str]:
    return run_lua(f'''
{fixture_registers(pack=pack)}
{extra}
dofile("{DRIVER}")
driver_init({{}})
local ok, err = pcall(driver_poll)
if not ok then print("POLL_ERROR " .. tostring(err)) os.exit(1) end
{REPORT}
''')


def test_hybrid_capture_in_site_convention():
    out = poll_once()

    assert out["PV_EMITS"] == "1"
    assert float(out["PV_W"]) == -PV_W_VENDOR
    assert math.isclose(float(out["PV_MPPT1_V"]), 275.2, rel_tol=1e-5)
    assert float(out["PV_MPPT2_W"]) == 1400
    assert float(out["PV_GEN_WH"]) == PV_ENERGY_RAW * 10

    # Vendor discharge-positive charging (-1800) flips to site +1800.
    assert out["BAT_EMITS"] == "1"
    assert float(out["BAT_W"]) == 1800
    assert math.isclose(float(out["BAT_V"]), 51.2, rel_tol=1e-5)
    assert math.isclose(float(out["BAT_A"]), 35.0, rel_tol=1e-5)
    assert math.isclose(float(out["BAT_SOC"]), 0.85, rel_tol=1e-5)
    assert math.isclose(float(out["BAT_TEMP"]), 25.4, rel_tol=1e-5)
    assert float(out["BAT_CHG_WH"]) == BAT_CHARGE_RAW * 10
    assert float(out["BAT_DIS_WH"]) == BAT_DISCHARGE_RAW * 10

    assert out["MET_EMITS"] == "1"
    assert float(out["MET_W"]) == GRID_W_VENDOR
    assert math.isclose(float(out["MET_HZ"]), 50.01, rel_tol=1e-5)
    assert math.isclose(float(out["MET_L1V"]), 235.0, rel_tol=1e-5)
    assert float(out["MET_L1W"]) == 200
    assert float(out["MET_L2W"]) == 150


def test_identity_from_inverter_info_block():
    out = poll_once()
    assert out["MAKE"] == "SAJ"
    assert out["SN"] == SERIAL


def test_no_battery_stream_when_pack_is_offline():
    """AS2 / PV-only H2: BMS answers, BatNum and BatOnline are zero."""
    out = poll_once(pack=False)
    assert out["BAT_EMITS"] == "0"
    assert out["PV_EMITS"] == "1"
    assert out["MET_EMITS"] == "1"


def test_no_battery_stream_when_bms_block_is_missing():
    out = poll_once('host._modbus_read_fail_addresses[40960] = "Illegal Data Address"')
    assert out["BAT_EMITS"] == "0"
    assert out["PV_EMITS"] == "1"
    assert out["MET_EMITS"] == "1"


def test_power_block_failure_emits_nothing():
    """A missed live-power read is silence, not a fabricated zero-watt site."""
    out = poll_once('host._modbus_read_fail_addresses[16549] = "timeout"')
    assert out["PV_EMITS"] == "0"
    assert out["MET_EMITS"] == "0"
    assert out["BAT_EMITS"] == "0"


def test_soc_omitted_when_bat1_soc_is_sentinel():
    out = poll_once(
        "host._modbus_registers.holding[40960][13] = 0xFFFF")
    assert out["BAT_EMITS"] == "1"
    assert out["BAT_SOC"] == "nil"
    assert float(out["BAT_W"]) == 1800


def test_command_refuses_battery_writes():
    out = run_lua(f'''
{fixture_registers()}
dofile("{DRIVER}")
driver_init({{}})
local ok, err = pcall(driver_command, "battery", 1000, {{}})
print("CMD_OK " .. tostring(ok))
print("CMD_RET " .. tostring(err == nil and "nil" or tostring(err)))
print("WRITES " .. tostring(host._modbus_write_attempts))
''')
    # pcall ok means the function ran; the return value is the first result.
    # driver_command returns false, so ok is true and we need the actual return.
    # pcall returns (true, false) on a successful call that returned false.
    assert out["WRITES"] == "0"


def test_command_return_is_false():
    out = run_lua(f'''
{fixture_registers()}
dofile("{DRIVER}")
driver_init({{}})
local ret = driver_command("battery", -500, {{}})
print("RET " .. tostring(ret))
local init_ret = driver_command("init", 0, {{}})
print("INIT " .. tostring(init_ret))
''')
    assert out["RET"] == "false"
    assert out["INIT"] == "true"


def test_bms_absence_settles_and_keeps_pv():
    """After three BMS failures the driver stops asking and still reports PV."""
    out = run_lua(f'''
{fixture_registers()}
host._modbus_read_fail_addresses[40960] = "Illegal Data Address"
dofile("{DRIVER}")
driver_init({{}})
for i = 1, 10 do
    host._emitted = {{}}
    pcall(driver_poll)
end
local reads = 0
for _, call in ipairs(host._calls) do
    if call.func == "modbus_read" and call.args[1] == 40960 then
        reads = reads + 1
    end
end
print("BMS_READS " .. tostring(reads))
print("PV_EMITS " .. tostring(host._emitted["pv"] and #host._emitted["pv"] or 0))
print("BAT_EMITS " .. tostring(host._emitted["battery"] and #host._emitted["battery"] or 0))
''')
    assert out["BMS_READS"] == "3"
    assert out["PV_EMITS"] == "1"
    assert out["BAT_EMITS"] == "0"
