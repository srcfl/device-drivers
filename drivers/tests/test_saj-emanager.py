"""SAJ eManager C1 Pro: aggregate Modbus TCP telemetry, no fabricated zeros.

The register sheet is the community workbook on
stanus74/home-assistant-saj-h2-modbus discussion 182. Nothing here was read
off a live controller. The numbers below are the sheet's own scales applied
to a fixture, including the two sign assumptions (battery discharge-positive,
grid import-positive) and high-word-first int32.
"""

from __future__ import annotations

import math
import re
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"
HARNESS = ROOT / "drivers" / "tests" / "lua_harness"
DRIVER = ROOT / "drivers" / "lua" / "saj-emanager.lua"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")

REG_DEVICE_NUM = 0x4A00
REG_SLOT0 = 0x4A01
REG_SUMMARY = 0x848A
REG_PHASES = 0x849E
REG_ENERGY = 0x8500
REG_CONTROL = 0x8400

SERIALS = (
    "CHS2TEST0000000001",
    "CHS2TEST0000000002",
    "CHS2TEST0000000003",
)

# Sheet scales, raw register units. Signs are the vendor's, not the site's.
PV_W = 123456                 # uint32 magnitude, high word first
BAT_W_VENDOR = -6000          # discharge-positive: negative means charging
GRID_W_VENDOR = -2500         # import-positive: negative means export
INV_W_VENDOR = 42000
LOAD_W_VENDOR = 9000
SOC_RAW = 7325                # 0.01 % → 73.25 %
RATED_W = 150000
CAP_RAW = 200                 # unit on the sheet is "K", not Wh
USER_RAW = 146
PV_ENERGY_RAW = 123456        # 0.01 kWh
BAT_CHARGE_RAW = 50000
BAT_DISCHARGE_RAW = 40000
FEED_IN_RAW = 111
SELL_RAW = 222
DEVICE_COUNT = 3

# One phase, already on the sheet's scale. Must NOT be divided by 3.
L1_V_RAW = 2304               # 230.4 V
L1_A_RAW = 105                # 10.5 A
L2_A_RAW = -15                # -1.5 A
L1_HZ_RAW = 5002              # 50.02 Hz
L1_W = -800
L2_W = -700
L3_W = -1000


def _ascii_regs(text: str, width: int) -> list[int]:
    padded = text.encode("ascii").ljust(width * 2, b"\x00")
    return [padded[i] << 8 | padded[i + 1] for i in range(0, width * 2, 2)]


def _u32_regs(value: int) -> list[int]:
    return [(value >> 16) & 0xFFFF, value & 0xFFFF]


def _i32_regs(value: int) -> list[int]:
    raw = value & 0xFFFFFFFF
    return [(raw >> 16) & 0xFFFF, raw & 0xFFFF]


def _i16(value: int) -> int:
    return value & 0xFFFF


def _lua_list(values) -> str:
    return "{" + ", ".join(str(int(v)) for v in values) + "}"


def _put_pair(buf: list[int], pair: int, value: int) -> None:
    hi, lo = _u32_regs(value)
    buf[pair * 2] = hi
    buf[pair * 2 + 1] = lo


def fixture_registers(*, pack: str = "yes", summed: bool = False,
                      count: int = DEVICE_COUNT) -> str:
    """Three CHS2s behind one eManager, unless count says otherwise.

    pack: "yes" (capacity + SoC + power), "no" (all zero), "power" (only
    battery watts), "soc_sentinel" (capacity, SoC word 0xFFFF).
    summed: phase volts and hertz are DeviceNum times a normal phase, which
    is the Eniris observation the sheet itself does not document.
    """
    slots: list[int] = []
    n_slots = count if 1 <= count <= 21 else 0
    for i in range(n_slots):
        slots.extend(_ascii_regs(SERIALS[i], 10))
        slots.append(i + 1)  # inverter Modbus id
        slots.append(0)      # reserved

    summary = [0] * 20
    summary[0] = 2  # MPVMode grid-connected
    summary[1:3] = _u32_regs(RATED_W)
    summary[3:5] = _i32_regs(INV_W_VENDOR)
    summary[5:7] = _u32_regs(PV_W)
    summary[9:11] = _i32_regs(LOAD_W_VENDOR)
    summary[12:14] = _i32_regs(GRID_W_VENDOR)
    # generator stays 0: no metric
    if pack == "no":
        summary[7:9] = _i32_regs(0)
        summary[11] = 0
        summary[16:18] = _u32_regs(0)
        summary[18:20] = _u32_regs(0)
    elif pack == "power":
        summary[7:9] = _i32_regs(BAT_W_VENDOR)
        summary[11] = 0
        summary[16:18] = _u32_regs(0)
        summary[18:20] = _u32_regs(0)
    elif pack == "soc_sentinel":
        summary[7:9] = _i32_regs(BAT_W_VENDOR)
        summary[11] = 0xFFFF
        summary[16:18] = _u32_regs(CAP_RAW)
        summary[18:20] = _u32_regs(USER_RAW)
    else:
        summary[7:9] = _i32_regs(BAT_W_VENDOR)
        summary[11] = SOC_RAW
        summary[16:18] = _u32_regs(CAP_RAW)
        summary[18:20] = _u32_regs(USER_RAW)

    hz_raw = L1_HZ_RAW * count if summed and count > 1 else L1_HZ_RAW
    phases: list[int] = []
    for phase, watts in enumerate((L1_W, L2_W, L3_W)):
        amps = (L1_A_RAW, L2_A_RAW, 200)[phase]
        # Each phase's own voltage, summed across inverters when `summed`.
        volts = L1_V_RAW + phase
        if summed and count > 1:
            volts *= count
        phases.extend([
            volts,
            _i16(amps),
            hz_raw,
            *_i32_regs(watts),
            0, 0,          # apparent power, unused
            1000,          # power factor × 0.001, unused
        ])

    energy = [0] * 80
    _put_pair(energy, 3, PV_ENERGY_RAW)       # 0x8506 total PV
    _put_pair(energy, 7, BAT_CHARGE_RAW)      # 0x850E
    _put_pair(energy, 11, BAT_DISCHARGE_RAW)  # 0x8516
    _put_pair(energy, 23, FEED_IN_RAW)        # 0x852E
    _put_pair(energy, 27, SELL_RAW)           # 0x8536

    lines = [
        f"host._modbus_registers.holding[{REG_DEVICE_NUM}] = {{{count}}}",
        f"host._modbus_registers.holding[{REG_SUMMARY}] = {_lua_list(summary)}",
        f"host._modbus_registers.holding[{REG_PHASES}] = {_lua_list(phases)}",
        f"host._modbus_registers.holding[{REG_ENERGY}] = {_lua_list(energy)}",
    ]
    if slots:
        lines.append(
            f"host._modbus_registers.holding[{REG_SLOT0}] = {_lua_list(slots)}")
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


REPORT = f'''
local function last(t) return t and t[#t] or nil end
local function field(obj, key)
    if obj == nil or obj[key] == nil then return "nil" end
    return tostring(obj[key])
end
local function metric(name)
    local m = host._metrics[name]
    if m == nil or m.value == nil then return "nil" end
    return tostring(m.value)
end
local pv = last(host._emitted["pv"])
local bat = last(host._emitted["battery"])
local met = last(host._emitted["meter"])
print("PV_EMITS " .. tostring(host._emitted["pv"] and #host._emitted["pv"] or 0))
print("BAT_EMITS " .. tostring(host._emitted["battery"] and #host._emitted["battery"] or 0))
print("MET_EMITS " .. tostring(host._emitted["meter"] and #host._emitted["meter"] or 0))
print("PV_W " .. field(pv, "W"))
print("PV_WH " .. field(pv, "lifetime_wh"))
print("BAT_W " .. field(bat, "W"))
print("BAT_SOC " .. field(bat, "SoC_nom_fract"))
print("BAT_CHG " .. field(bat, "total_charge_Wh"))
print("BAT_DIS " .. field(bat, "total_discharge_Wh"))
print("MET_W " .. field(met, "W"))
print("MET_HZ " .. field(met, "Hz"))
print("MET_L1V " .. field(met, "L1_V"))
print("MET_L1A " .. field(met, "L1_A"))
print("MET_L1W " .. field(met, "L1_W"))
print("MET_L2A " .. field(met, "L2_A"))
print("MET_L2W " .. field(met, "L2_W"))
print("MET_L3V " .. field(met, "L3_V"))
print("MET_L3W " .. field(met, "L3_W"))
print("MET_IMPORT " .. field(met, "total_import_Wh"))
print("MET_EXPORT " .. field(met, "total_export_Wh"))
print("MAKE " .. tostring(host._make))
print("MODEL " .. tostring(host._model))
print("SN " .. tostring(host._sn))
print("RATED " .. tostring(host._rated_w))
print("FAULT " .. tostring(host._faulted))
print("COUNT " .. metric("saj_emanager_device_count"))
print("DIVISOR " .. metric("saj_emanager_phase_scale_divisor"))
print("LOAD " .. metric("saj_emanager_load_w"))
print("INV " .. metric("saj_emanager_inv_w"))
print("GEN " .. metric("saj_emanager_gen_w"))
print("CAP " .. metric("saj_emanager_battery_capacity_raw"))
print("FEED " .. metric("saj_emanager_vendor_feed_in_wh"))
print("SELL " .. metric("saj_emanager_vendor_sell_wh"))
local slot_reads, slot_count, control_reads, bad_kind = 0, 0, 0, 0
for _, call in ipairs(host._calls) do
    if call.func == "modbus_read" then
        if call.args[1] == {REG_SLOT0} then
            slot_reads = slot_reads + 1
            slot_count = call.args[2]
        end
        if call.args[1] == {REG_CONTROL} then
            control_reads = control_reads + 1
        end
        if call.args[3] ~= "holding" then bad_kind = bad_kind + 1 end
    end
end
print("SLOT_READS " .. tostring(slot_reads))
print("SLOT_COUNT " .. tostring(slot_count))
print("CONTROL_READS " .. tostring(control_reads))
print("BAD_KIND " .. tostring(bad_kind))
print("WRITES " .. tostring(host._modbus_write_attempts))
'''


def poll_once(extra: str = "", **fixture) -> dict[str, str]:
    return run_lua(f'''
{fixture_registers(**fixture)}
{extra}
dofile("{DRIVER}")
driver_init({{}})
local interval = driver_poll()
print("INTERVAL " .. tostring(interval))
{REPORT}
''')


def test_three_inverter_plant_in_site_convention():
    out = poll_once()

    assert out["INTERVAL"] == "5000"
    assert out["MAKE"] == "SAJ"
    assert out["MODEL"] == "eManager C1 Pro"
    assert out["SN"] == SERIALS[0]
    assert out["COUNT"] == "3"
    assert out["RATED"] == str(RATED_W)
    assert out["FAULT"] == "false"
    assert out["BAD_KIND"] == "0"
    assert out["CONTROL_READS"] == "0"
    assert out["WRITES"] == "0"
    # One read of the three slots, not a scan of all 21.
    assert out["SLOT_READS"] == "1"
    assert out["SLOT_COUNT"] == str(DEVICE_COUNT * 12)

    assert out["PV_EMITS"] == "1"
    assert float(out["PV_W"]) == -PV_W
    assert float(out["PV_WH"]) == PV_ENERGY_RAW * 10

    # Vendor discharge-positive charging (-6000) flips to site +6000.
    assert out["BAT_EMITS"] == "1"
    assert float(out["BAT_W"]) == -BAT_W_VENDOR
    assert math.isclose(float(out["BAT_SOC"]), SOC_RAW / 10000, rel_tol=1e-6)
    assert float(out["BAT_CHG"]) == BAT_CHARGE_RAW * 10
    assert float(out["BAT_DIS"]) == BAT_DISCHARGE_RAW * 10
    assert out["CAP"] == str(CAP_RAW)

    # Vendor import-positive export stays negative. Not divided by 3.
    assert out["MET_EMITS"] == "1"
    assert float(out["MET_W"]) == GRID_W_VENDOR
    assert math.isclose(float(out["MET_HZ"]), L1_HZ_RAW / 100, rel_tol=1e-6)
    assert math.isclose(float(out["MET_L1V"]), L1_V_RAW / 10, rel_tol=1e-6)
    assert math.isclose(float(out["MET_L1A"]), L1_A_RAW / 10, rel_tol=1e-6)
    assert math.isclose(float(out["MET_L2A"]), L2_A_RAW / 10, rel_tol=1e-6)
    assert float(out["MET_L1W"]) == L1_W
    assert float(out["MET_L2W"]) == L2_W
    assert float(out["MET_L3W"]) == L3_W
    assert math.isclose(float(out["MET_L3V"]), (L1_V_RAW + 2) / 10, rel_tol=1e-6)
    # Sheet scale was already one phase, so the divisor stays 1.
    assert out["DIVISOR"] == "1"
    # FeedIn / Sell stay vendor metrics. They are not import and export.
    assert out["MET_IMPORT"] == "nil"
    assert out["MET_EXPORT"] == "nil"
    assert float(out["FEED"]) == FEED_IN_RAW * 10
    assert float(out["SELL"]) == SELL_RAW * 10
    assert float(out["LOAD"]) == LOAD_W_VENDOR
    assert float(out["INV"]) == INV_W_VENDOR
    assert out["GEN"] == "nil"


def test_summed_voltage_and_frequency_are_divided_power_is_not():
    """Eniris: 3 inverters can report 3×230 V and 3×50 Hz. Watts stay summed."""
    out = poll_once(summed=True)

    assert math.isclose(float(out["MET_L1V"]), L1_V_RAW / 10, rel_tol=1e-6)
    assert math.isclose(float(out["MET_HZ"]), L1_HZ_RAW / 100, rel_tol=1e-6)
    assert math.isclose(float(out["MET_L3V"]), (L1_V_RAW + 2) / 10, rel_tol=1e-6)
    assert out["DIVISOR"] == "3"
    # Current and power are not part of that correction.
    assert math.isclose(float(out["MET_L1A"]), L1_A_RAW / 10, rel_tol=1e-6)
    assert float(out["MET_L1W"]) == L1_W
    assert float(out["PV_W"]) == -PV_W
    assert float(out["MET_W"]) == GRID_W_VENDOR


def test_implausible_voltage_that_does_not_divide_cleanly_is_left_alone():
    """400 V / 3 is not a phase voltage, so the sheet scale is published."""
    out = poll_once(
        f"host._modbus_registers.holding[{REG_PHASES}][1] = 4000")
    assert math.isclose(float(out["MET_L1V"]), 400.0, rel_tol=1e-6)
    assert out["DIVISOR"] == "1"


def test_sum_is_not_guessed_when_device_count_did_not_answer():
    out = poll_once(
        f'host._modbus_read_fail_addresses[{REG_DEVICE_NUM}] = "timeout"\n'
        f"host._modbus_registers.holding[{REG_PHASES}][3] = 15000")
    assert out["COUNT"] == "nil"
    assert out["DIVISOR"] == "nil"
    assert out["SN"] == "nil"
    assert out["SLOT_READS"] == "0"
    # 150.00 Hz stays 150.00 Hz. Inventing a divisor of 3 would hide that.
    assert math.isclose(float(out["MET_HZ"]), 150.0, rel_tol=1e-6)
    assert out["PV_EMITS"] == "1"


def test_no_battery_when_capacity_soc_and_power_are_zero():
    out = poll_once(pack="no")
    assert out["BAT_EMITS"] == "0"
    assert out["CAP"] == "nil"
    assert out["PV_EMITS"] == "1"
    assert out["MET_EMITS"] == "1"
    assert float(out["PV_W"]) == -PV_W


def test_battery_from_power_alone():
    """A non-zero battery watt is a pack, even when SoC and capacity read 0."""
    out = poll_once(pack="power")
    assert out["BAT_EMITS"] == "1"
    assert float(out["BAT_W"]) == -BAT_W_VENDOR
    assert float(out["BAT_SOC"]) == 0.0


def test_soc_sentinel_is_omitted():
    out = poll_once(pack="soc_sentinel")
    assert out["BAT_EMITS"] == "1"
    assert out["BAT_SOC"] == "nil"
    assert float(out["BAT_W"]) == -BAT_W_VENDOR


def test_device_zero_is_emitted_a_failed_read_is_not():
    """Night-time 0 W is the device. A missed summary is silence, not 0 W."""
    zeros = poll_once(
        f"host._modbus_registers.holding[{REG_SUMMARY}][6] = 0\n"
        f"host._modbus_registers.holding[{REG_SUMMARY}][7] = 0\n"
        f"host._modbus_registers.holding[{REG_SUMMARY}][13] = 0\n"
        f"host._modbus_registers.holding[{REG_SUMMARY}][14] = 0")
    assert zeros["PV_EMITS"] == "1"
    assert float(zeros["PV_W"]) == 0
    assert zeros["MET_EMITS"] == "1"
    assert float(zeros["MET_W"]) == 0
    assert zeros["BAT_EMITS"] == "1"

    failed = poll_once(
        f'host._modbus_read_fail_addresses[{REG_SUMMARY}] = "timeout"')
    assert failed["PV_EMITS"] == "0"
    assert failed["MET_EMITS"] == "0"
    assert failed["BAT_EMITS"] == "0"
    assert failed["PV_W"] == "nil"
    assert failed["MET_W"] == "nil"


def test_short_summary_emits_nothing():
    out = poll_once(
        f"host._modbus_read_short_counts[{REG_SUMMARY}] = 10")
    assert out["PV_EMITS"] == "0"
    assert out["MET_EMITS"] == "0"
    assert out["BAT_EMITS"] == "0"
    assert out["PV_W"] == "nil"
    assert out["RATED"] == "nil"


def test_short_phase_block_does_not_zero_fill():
    out = poll_once(
        f"host._modbus_read_short_counts[{REG_PHASES}] = 8")
    assert out["MET_EMITS"] == "1"
    assert float(out["MET_W"]) == GRID_W_VENDOR
    assert out["MET_L1V"] == "nil"
    assert out["MET_L1W"] == "nil"
    assert out["MET_HZ"] == "nil"
    assert out["DIVISOR"] == "nil"


def test_phase_failure_keeps_the_totals():
    out = poll_once(
        f'host._modbus_read_fail_addresses[{REG_PHASES}] = "Illegal Data Address"')
    assert float(out["MET_W"]) == GRID_W_VENDOR
    assert out["MET_L1V"] == "nil"
    assert float(out["PV_W"]) == -PV_W


def test_energy_failure_omits_counters():
    out = poll_once(
        f'host._modbus_read_fail_addresses[{REG_ENERGY}] = "Illegal Data Address"')
    assert float(out["PV_W"]) == -PV_W
    assert out["PV_WH"] == "nil"
    assert float(out["BAT_W"]) == -BAT_W_VENDOR
    assert out["BAT_CHG"] == "nil"
    assert out["BAT_DIS"] == "nil"
    assert out["FEED"] == "nil"
    assert out["SELL"] == "nil"


def test_int32_sentinel_is_not_a_power():
    out = poll_once(
        f"host._modbus_registers.holding[{REG_SUMMARY}][13] = 0x7FFF\n"
        f"host._modbus_registers.holding[{REG_SUMMARY}][14] = 0xFFFF")
    assert out["MET_W"] == "nil"
    assert float(out["MET_L1W"]) == L1_W
    assert out["MET_EMITS"] == "1"


def test_zero_devices_does_not_scan_slots():
    out = poll_once(count=0)
    assert out["COUNT"] == "0"
    assert out["SLOT_READS"] == "0"
    assert out["SN"] == "nil"
    assert out["PV_EMITS"] == "1"


def test_sentinel_device_count_does_not_scan_slots():
    out = poll_once(count=0xFFFF)
    assert out["COUNT"] == "nil"
    assert out["SLOT_READS"] == "0"


def test_fault_mode_is_reported():
    out = poll_once(
        f"host._modbus_registers.holding[{REG_SUMMARY}][1] = 5")
    assert out["FAULT"] == "true"
    assert out["PV_EMITS"] == "1"


def test_phase_absence_settles_and_keeps_pv():
    out = run_lua(f'''
{fixture_registers()}
host._modbus_read_fail_addresses[{REG_PHASES}] = "Illegal Data Address"
dofile("{DRIVER}")
driver_init({{}})
for i = 1, 10 do
    host._emitted = {{}}
    pcall(driver_poll)
end
local reads = 0
for _, call in ipairs(host._calls) do
    if call.func == "modbus_read" and call.args[1] == {REG_PHASES} then
        reads = reads + 1
    end
end
print("PHASE_READS " .. tostring(reads))
print("PV_EMITS " .. tostring(host._emitted["pv"] and #host._emitted["pv"] or 0))
''')
    assert out["PHASE_READS"] == "3"
    assert out["PV_EMITS"] == "1"


def test_command_and_default_mode_do_not_write():
    out = run_lua(f'''
{fixture_registers()}
dofile("{DRIVER}")
driver_init({{}})
driver_poll()
local ret = driver_command("battery", 1000, {{}})
local init_ret = driver_command("init", 0, {{}})
local deinit_ret = driver_command("deinit", 0, {{}})
driver_default_mode()
print("RET " .. tostring(ret))
print("INIT " .. tostring(init_ret))
print("DEINIT " .. tostring(deinit_ret))
print("WRITES " .. tostring(host._modbus_write_attempts))
''')
    assert out["RET"] == "false"
    assert out["INIT"] == "true"
    assert out["DEINIT"] == "true"
    assert out["WRITES"] == "0"


def _code_without_comments() -> str:
    lines = []
    for line in DRIVER.read_text(encoding="utf-8").splitlines():
        lines.append(line.split("--", 1)[0])
    return "\n".join(lines)


def test_source_is_tcp_only_and_does_not_read_or_write_control():
    """The executable code never touches 0x8400. The comments do, on purpose."""
    text = DRIVER.read_text(encoding="utf-8")
    code = _code_without_comments()
    assert "RTU is not supported" in text
    assert re.search(r"port\s*=\s*502", text)
    # Mentioning the block in a string is the documentation. Reading or
    # writing it is the bug.
    assert not re.search(r"modbus_read\s*\([^)]*0x8400", code)
    assert "modbus_write" not in code
    assert "write_registers" not in code
    assert "host.write" not in code
    manifest = (ROOT / "manifests" / "saj-emanager.yaml").read_text(encoding="utf-8")
    assert 'tier: community' in manifest
    assert "control: false" in manifest
    assert "RTU" in manifest
