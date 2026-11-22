"""AlphaESS reports its cell temperature range, and leaves out what it cannot read.

The battery block that starts at 0x0100 holds the lowest (0x010D) and the
highest (0x0110) cell temperature, I16 x 0.1 °C. They go to history as
battery_cell_temp_min_c and battery_cell_temp_max_c. The block has no pack
temperature, so `temperature_C` stays out of the battery stream, and the BMS
current registers 0x0111/0x0112 are not read: one integration's author saw
them stay at values that cannot be live limits.
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
dump("battery.", last(host._emitted["battery"]))
for name, m in pairs(host._metrics) do
  print("metric." .. name .. " " .. tostring(m.value))
end
local reads = {}
for _, c in ipairs(host._calls) do
  if c.func == "modbus_read" then
    local key = "reads." .. tostring(c.args[3]) .. ":" .. tostring(c.args[1])
    reads[key] = (reads[key] or 0) + 1
  end
end
for k, n in pairs(reads) do print(k .. " " .. n) end
'''


def i16(value: int) -> int:
    return value & 0xFFFF


def run(registers: dict[int, int], fail: tuple[int, ...] = ()) -> dict[str, str]:
    setup = "\n".join(
        f"host._modbus_registers.holding[{addr}] = {value}"
        for addr, value in registers.items())
    setup += "\n" + "\n".join(
        f'host._modbus_read_fail_addresses[{addr}] = "Illegal Data Address"'
        for addr in fail)
    script = (
        f'package.path = "{HARNESS}/?.lua;" .. package.path\n'
        'require("host_mock")\n'
        "host.reset()\n"
        f"{setup}\n"
        f'dofile("{DRIVER}")\n'
        "driver_init({})\n"
        "local ok, err = pcall(driver_poll)\n"
        'if not ok then print("POLL_ERROR " .. tostring(err)) os.exit(1) end\n'
        + REPORT)
    result = subprocess.run([str(LUA), "-e", script],
                            capture_output=True, text=True, cwd=ROOT)
    assert result.returncode == 0, result.stdout + result.stderr
    return dict(line.split(" ", 1)
                for line in result.stdout.strip().splitlines() if " " in line)


def num(out: dict[str, str], key: str) -> float:
    assert key in out, f"{key} missing from {sorted(out)}"
    return float(out[key])


def test_alphaess_reports_cell_temperature_range():
    out = run({269: i16(-50), 272: 312})
    assert num(out, "metric.battery_cell_temp_min_c") == pytest.approx(-5.0, abs=1e-3)
    assert num(out, "metric.battery_cell_temp_max_c") == pytest.approx(31.2, abs=1e-3)
    assert "battery.temperature_C" not in out
    assert "battery.temp_c" not in out
    assert "battery.available_charge_W" not in out
    assert "reads.holding:273" not in out
    assert "reads.holding:274" not in out


def test_alphaess_failed_cell_temperature_read_is_left_out():
    out = run({269: i16(-50), 272: 312}, fail=(269,))
    assert "metric.battery_cell_temp_min_c" not in out
    assert "metric.battery_cell_temp_max_c" not in out


def test_alphaess_out_of_range_cell_temperature_is_dropped():
    out = run({269: i16(-500), 272: 1500})
    assert "metric.battery_cell_temp_min_c" not in out
    assert "metric.battery_cell_temp_max_c" not in out
