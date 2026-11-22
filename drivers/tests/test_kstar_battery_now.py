"""KSTAR reports its battery and inverter temperatures, and leaves out what it cannot read.

KSTAR's hybrid Modbus map (V2.9.1, as read by ha-solarman) holds the inverter
radiator temperature in input register 3055 and the battery temperature in
3067, both I16 x 0.1 °C. The driver reads 3055..3067 in one go. A failed read
or a value outside -40..100 °C is left out, never sent as zero. The map has
no live BMS limit, so no `available_*` field is sent.
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
        f"host._modbus_registers.input[{addr}] = {value}"
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


def test_kstar_reports_battery_and_inverter_temperature():
    out = run({3055: 455, 3067: i16(-50)})
    assert num(out, "battery.temperature_C") == pytest.approx(-5.0, abs=1e-3)
    assert num(out, "metric.battery_temp_c") == pytest.approx(-5.0, abs=1e-3)
    assert num(out, "metric.inverter_temp_c") == pytest.approx(45.5, abs=1e-3)
    assert "battery.available_charge_W" not in out
    assert int(out["reads.input:3055"]) == 1


def test_kstar_failed_temperature_read_is_left_out():
    out = run({3055: 455, 3067: 250}, fail=(3055,))
    assert "battery.temperature_C" not in out
    assert "battery.temp_c" not in out
    assert "metric.battery_temp_c" not in out
    assert "metric.inverter_temp_c" not in out
    # The battery stream itself still goes out.
    assert "battery.W" in out


def test_kstar_out_of_range_temperature_is_dropped():
    out = run({3055: 455, 3067: 1500})
    assert "battery.temperature_C" not in out
    assert "metric.battery_temp_c" not in out
    assert num(out, "metric.inverter_temp_c") == pytest.approx(45.5, abs=1e-3)
