"""KSTAR reads the input registers its own Modbus map gives, with the site's signs.

KSTAR's Hybrid Inverter Modbus V2.9.1 (table 3.1, function 04H) puts:

- PV1 voltage at 3000 (x 0.1 V), PV1 current at 3012 (S16 x 0.01 A), PV1 and
  PV2 power at 3024 and 3025 (S16, 1 W);
- the inverter model at 3045 (table 3.1.5: 0x00-0x1F single phase,
  0x20-0x2F three phase);
- battery voltage at 3063 (x 0.01 V), power at 3065 (S16, 1 W) and SoC at
  3066 (x 0.1 %);
- per phase grid voltage, frequency, meter current and meter power at
  3097-3100 (R), 3101-3104 (S) and 3105-3108 (T), S and T "only for three
  phase model".

KSTAR gives no signs. ha-solarman negates the meter power to make import
positive, and counts battery power as power into the DC bus (positive while
discharging). The driver turns both into site signs. Earlier releases read
holding registers 10-54, which no source has.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"
HARNESS = ROOT / "drivers" / "tests" / "lua_harness"
DRIVER = ROOT / "drivers" / "lua" / "kstar.lua"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")

REPORT = '''
local function dump(prefix, t)
  if not t then return end
  for k, v in pairs(t) do
    if type(v) ~= "table" then print(prefix .. k .. " " .. tostring(v)) end
  end
end
local function last(t) return t and t[#t] or nil end
for _, der in ipairs({"pv", "battery", "meter"}) do
  dump(der .. ".", last(host._emitted[der]))
end
for name, m in pairs(host._metrics) do
  print("metric." .. name .. " " .. tostring(m.value))
end
local calls = {}
for _, c in ipairs(host._calls) do
  if c.func == "modbus_read" then
    local key = tostring(c.args[3]) .. ":" .. tostring(c.args[1])
    print("read." .. key .. " " .. tostring(c.args[2]))
    calls[key] = (calls[key] or 0) + 1
  end
end
for key, n in pairs(calls) do print("calls." .. key .. " " .. n) end
'''

SINGLE = 0x04   # KSE-5K-048S
THREE = 0x21    # E8KT


def u16(value: int) -> int:
    return value & 0xFFFF


def run(registers: dict[int, int], fail: tuple[int, ...] = (),
        polls: int = 1) -> dict[str, str]:
    lines = [f"host._modbus_registers.input[{a}] = {v}" for a, v in registers.items()]
    lines += [f'host._modbus_read_fail_addresses[{a}] = "Illegal Data Address"' for a in fail]
    script = (
        f'package.path = "{HARNESS}/?.lua;" .. package.path\n'
        'require("host_mock")\n'
        "host.reset()\n"
        + "\n".join(lines) + "\n"
        f'dofile("{DRIVER}")\n'
        "driver_init({})\n"
        f"for _ = 1, {polls} do\n"
        "  local ok, err = pcall(driver_poll)\n"
        '  if not ok then print("POLL_ERROR " .. tostring(err)) os.exit(1) end\n'
        "end\n"
        + REPORT)
    result = subprocess.run([str(LUA), "-e", script],
                            capture_output=True, text=True, cwd=ROOT)
    assert result.returncode == 0, result.stdout + result.stderr
    return dict(line.split(" ", 1)
                for line in result.stdout.strip().splitlines() if " " in line)


def num(out: dict[str, str], key: str) -> float:
    assert key in out, f"{key} missing from {sorted(out)}"
    return float(out[key])


def meter_regs(model: int, r_w: int, s_w: int = 0, t_w: int = 0) -> dict[int, int]:
    return {
        3045: model,
        3097: 2304, 3098: 4998, 3099: u16(-5230), 3100: u16(r_w),
        3104: u16(s_w), 3108: u16(t_w),
    }


@pytest.mark.parametrize("raw, site_w", [(1800, -1800), (-950, 950)])
def test_single_phase_meter_power_with_site_sign(raw, site_w):
    # KSTAR's raw meter power is positive when exporting; site: import positive.
    out = run(meter_regs(SINGLE, raw, s_w=999, t_w=999))
    assert num(out, "meter.W") == site_w
    assert num(out, "meter.L1_V") == pytest.approx(230.4)
    assert num(out, "meter.Hz") == pytest.approx(49.98)
    assert num(out, "meter.L1_A") == pytest.approx(-5.23)
    # Single phase: only R is read; S and T are not summed in.
    assert out["read.input:3097"] == "4"


def test_three_phase_meter_sums_the_phases():
    out = run(meter_regs(THREE, -500, -600, -700))
    assert num(out, "meter.W") == 1800
    assert out["read.input:3097"] == "12"


@pytest.mark.parametrize("code", [10, 13, 16, 19, 31, 35, 47, 0x40])
def test_unlisted_model_sends_no_meter(code):
    # Table 3.1.5 marks 10, 13, 16, 19-31 and 35-47 "reserve".
    out = run(meter_regs(code, 1800))
    assert not any(k.startswith("meter.") for k in out)
    assert "read.input:3097" not in out


@pytest.mark.parametrize("code, count", [
    (0, "4"), (9, "4"), (11, "4"), (14, "4"), (18, "4"),
    (32, "12"), (33, "12"), (34, "12"),
])
def test_listed_models_read_their_phases(code, count):
    out = run(meter_regs(code, 1800))
    assert out["read.input:3097"] == count
    assert "meter.W" in out


def test_no_battery_sends_no_battery_stream():
    # Voltage and SoC both 0: no pack, not an empty one.
    out = run({3055: 455, 3063: 0, 3065: 0, 3066: 0, 3067: 0})
    assert not any(k.startswith("battery.") for k in out)
    assert "metric.battery_temp_c" not in out
    # The inverter's own temperature is not the battery's.
    assert num(out, "metric.inverter_temp_c") == pytest.approx(45.5)


def test_empty_pack_with_a_voltage_is_still_sent():
    out = run({3063: 4610, 3065: 0, 3066: 0})
    assert num(out, "battery.SoC_nom_fract") == 0
    assert num(out, "battery.V") == pytest.approx(46.10)


def test_model_read_failure_sends_no_meter_but_keeps_the_rest():
    regs = meter_regs(SINGLE, 1800)
    regs.update({3063: 5230, 3065: 0, 3066: 500, 3024: 100, 3025: 0})
    out = run(regs, fail=(3045,))
    assert not any(k.startswith("meter.") for k in out)
    assert "battery.W" in out
    assert "pv.W" in out


def test_model_is_read_once():
    out = run(meter_regs(SINGLE, 1800), polls=3)
    assert out["calls.input:3045"] == "1"
    assert out["calls.input:3097"] == "3"
    assert num(out, "meter.W") == -1800


def test_meter_left_out_when_its_read_fails():
    out = run(meter_regs(SINGLE, 1800), fail=(3097,))
    assert not any(k.startswith("meter.") for k in out)


@pytest.mark.parametrize("raw, site_w", [(-2500, 2500), (1200, -1200)])
def test_battery_power_at_3065_with_site_sign(raw, site_w):
    # Raw positive is power into the DC bus (discharging); site: charging positive.
    out = run({3063: 5230, 3065: u16(raw), 3066: 643, 3067: 215})
    assert num(out, "battery.W") == site_w
    assert num(out, "battery.V") == pytest.approx(52.30)
    assert num(out, "battery.SoC_nom_fract") == pytest.approx(0.643)
    assert num(out, "battery.temperature_C") == pytest.approx(21.5)
    assert out["read.input:3055"] == "13"


def test_battery_soc_out_of_range_is_left_out():
    out = run({3063: 5230, 3065: 0, 3066: 1001})
    assert "battery.SoC_nom_fract" not in out


def test_pv_reads_input_registers_from_3000():
    out = run({3000: 3805, 3012: 921, 3024: 2100, 3025: 1350})
    assert num(out, "pv.W") == -3450
    assert num(out, "pv.mppt1_v") == pytest.approx(380.5)
    assert num(out, "pv.mppt1_a") == pytest.approx(9.21)
    assert out["read.input:3000"] == "26"


def test_pv_left_out_when_its_read_fails():
    out = run({3000: 3805, 3024: 2100}, fail=(3000,))
    assert not any(k.startswith("pv.") for k in out)


def test_no_holding_registers_are_read():
    out = run(meter_regs(SINGLE, 1800))
    assert not any(k.startswith("read.holding:") for k in out)
