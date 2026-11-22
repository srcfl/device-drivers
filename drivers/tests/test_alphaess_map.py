"""AlphaESS reads the registers its own Modbus map gives, with the site's signs.

AlphaESS's "Parameter address table" (protocol history up to V1.39) puts:

- the grid meter's current of A phase at 0x0017 (S16 x 0.1 A), frequency at
  0x001A (U16 x 0.01 Hz) and total active power at 0x0021 (S32, 1 W),
  positive when drawing from the grid (Alpha2MQTT, evcc, senalse);
- battery voltage at 0x0100 (x 0.1 V), SoC at 0x0102 (x 0.1 %) and battery
  power at 0x0126 (S16, 1 W, "-: Charge, +: Discharge");
- PV string voltage, current and power (U32) for strings 1 to 6 at
  0x041D-0x0434, four registers apart.

Earlier releases read 0x0010-0x0028 as PV, battery and meter. In the
vendor's map those are grid meter energy counters, voltages and powers.
Each stream is sent only when its read answered, never as zeros.

AlphaESS's protocol V1.17 (2020) had the meter at 0x0000-0x0019 and only
three PV strings. V1.19 changed the meter table and V1.20 added the System
info block (0x0740-0x074E). The driver uses the current meter and strings
4 to 6 only when 0x074E (Protocol Version) answers. Its value is not used:
it read 0 on a real system (Alpha2MQTT's register dump).
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"
HARNESS = ROOT / "drivers" / "tests" / "lua_harness"
DRIVER = ROOT / "drivers" / "lua" / "alphaess.lua"

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


def u16(value: int) -> int:
    return value & 0xFFFF


def i32(value: int) -> tuple[int, int]:
    raw = value & 0xFFFFFFFF
    return raw >> 16, raw & 0xFFFF


def run(registers: dict[int, int], fail: tuple[int, ...] = (),
        short: dict[int, int] | None = None, polls: int = 1) -> dict[str, str]:
    lines = [f"host._modbus_registers.holding[{a}] = {v}" for a, v in registers.items()]
    lines += [f'host._modbus_read_fail_addresses[{a}] = "Illegal Data Address"' for a in fail]
    lines += [f"host._modbus_read_short_counts[{a}] = {n}" for a, n in (short or {}).items()]
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


def meter_regs(total_w: int) -> dict[int, int]:
    hi, lo = i32(total_w)
    return {0x0017: u16(52), 0x001A: 5001, 0x0021: hi, 0x0022: lo}


@pytest.mark.parametrize("raw_w", [2300, -1500])
def test_meter_power_is_total_active_power_at_0x0021(raw_w):
    # Positive is drawing from the grid, the site convention: passed through.
    out = run(meter_regs(raw_w))
    assert num(out, "meter.W") == raw_w
    assert num(out, "meter.L1_A") == pytest.approx(5.2)
    assert num(out, "meter.Hz") == pytest.approx(50.01)
    # The sources disagree on the phase voltage's scale, so it is left out.
    assert "meter.L1_V" not in out
    assert out["read.holding:23"] == "12"


def test_meter_left_out_when_its_read_fails():
    out = run(meter_regs(2300), fail=(0x0017,))
    assert not any(k.startswith("meter.") for k in out)


@pytest.mark.parametrize("raw, site_w", [(-2000, 2000), (1500, -1500)])
def test_battery_power_at_0x0126_with_site_sign(raw, site_w):
    # AlphaESS: "-: Charge, +: Discharge". Site: charging is positive.
    out = run({0x0100: 5120, 0x0102: 875, 0x0126: u16(raw)})
    assert num(out, "battery.W") == site_w
    assert num(out, "battery.V") == pytest.approx(512.0)
    assert num(out, "battery.SoC_nom_fract") == pytest.approx(0.875)
    assert out["read.holding:256"] == "39"


def test_battery_soc_out_of_range_is_left_out():
    out = run({0x0100: 5120, 0x0102: 1001, 0x0126: 0})
    assert "battery.SoC_nom_fract" not in out
    assert num(out, "battery.W") == 0


def test_battery_left_out_when_its_read_fails():
    out = run({0x0100: 5120, 0x0102: 875, 0x0126: u16(-2000)}, fail=(0x0100,))
    assert not any(k.startswith("battery.") for k in out)


def test_battery_short_reply_is_a_failed_read():
    out = run({0x0100: 5120, 0x0102: 875, 0x0126: u16(-2000)}, short={0x0100: 10})
    assert not any(k.startswith("battery.") for k in out)


def test_pv_power_is_the_sum_of_the_string_powers():
    regs = {
        0x041D: 3500, 0x041E: 82,        # PV1 350.0 V, 8.2 A
        0x041F: 0, 0x0420: 2870,         # PV1 2870 W
        0x0423: 0, 0x0424: 1200,         # PV2 1200 W
        0x042B: 1, 0x042C: 0,            # PV4 65536 W: the high word counts
    }
    out = run(regs)
    assert num(out, "pv.W") == -(2870 + 1200 + 65536)
    assert num(out, "pv.mppt1_v") == pytest.approx(350.0)
    assert num(out, "pv.mppt1_a") == pytest.approx(8.2)
    assert out["read.holding:1053"] == "24"


def test_pv_left_out_when_its_read_fails():
    out = run({0x041D: 3500, 0x041F: 0, 0x0420: 2870}, fail=(0x041D,))
    assert not any(k.startswith("pv.") for k in out)


def test_nothing_is_sent_when_every_read_fails():
    out = run({}, fail=(0x0017, 0x0100, 0x041D))
    assert not any(k.split(".")[0] in ("pv", "battery", "meter") for k in out)


def test_old_map_registers_are_not_read():
    out = run({})
    for addr in (16, 18, 32, 33, 34, 36, 38, 39, 40):
        assert f"read.holding:{addr}" not in out, addr


def test_no_battery_sends_no_battery_stream():
    # Voltage and SoC both 0: no pack on the DC bus, not an empty one.
    out = run({0x0100: 0, 0x0102: 0, 0x0126: 0, 0x010D: 0, 0x0110: 0})
    assert not any(k.startswith("battery.") for k in out)
    assert "metric.battery_cell_temp_min_c" not in out
    assert "metric.battery_cell_temp_max_c" not in out
    assert "pv.W" in out


def test_empty_pack_with_a_voltage_is_still_sent():
    out = run({0x0100: 4600, 0x0102: 0, 0x0126: 0})
    assert num(out, "battery.SoC_nom_fract") == 0
    assert num(out, "battery.V") == pytest.approx(460.0)


def test_current_map_is_confirmed_once_by_the_protocol_version_register():
    out = run(meter_regs(2300), polls=3)
    assert out["calls.holding:1870"] == "1"     # 0x074E
    assert out["calls.holding:23"] == "3"
    assert num(out, "meter.W") == 2300


def test_old_firmware_without_system_info_gets_no_meter_and_three_strings():
    regs = meter_regs(2300)
    regs.update({0x041D: 3500, 0x041E: 82, 0x041F: 0, 0x0420: 2870,
                 0x0429: 250, 0x042B: 1, 0x042C: 0,
                 0x0100: 5120, 0x0102: 875, 0x0126: 0})
    out = run(regs, fail=(0x074E,), polls=5)
    assert not any(k.startswith("meter.") for k in out)
    assert "read.holding:23" not in out
    # PV1-PV3 sit where they always have; 0x0429 was the inverter
    # temperature in V1.17, so strings 4 to 6 are not read.
    assert out["read.holding:1053"] == "12"
    assert num(out, "pv.W") == -2870
    assert "battery.W" in out
    # The probe is bounded: three tries, then left alone.
    assert out["calls.holding:1870"] == "3"
