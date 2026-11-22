"""FoxESS H3-Smart reports what its battery can take now.

Register 46018 (Pwr_limit_Bat_up) holds the most the battery accepts, BMS
limits included. On this unit it also reads 0 while an idle pack sleeps, and
the pack still charges when asked (see the driver's CHARGE header). So a
positive reading becomes `available_charge_W` and a 0 is left out: it does
not prove that charging is refused. The foxess_bms_charge_limit_w metric
keeps every reading, zeros included, as before.

The battery temperature (37611) and the cell temperature range (37617/37618)
are left out when a read fails or the value is outside -40..100 °C. The cell
temperatures are read on every sixth poll: this device answers an unknown
address with a timeout, not an exception.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"
HARNESS = ROOT / "drivers" / "tests" / "lua_harness"
DRIVER = ROOT / "drivers" / "lua" / "foxess_h3_smart.lua"

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
dump("pv.", last(host._emitted["pv"]))
for name, m in pairs(host._metrics) do
  print("metric." .. name .. " " .. tostring(m.value))
end
local reads = {}
for _, c in ipairs(host._calls) do
  if c.func == "modbus_read" then
    local key = "reads." .. tostring(c.args[1])
    reads[key] = (reads[key] or 0) + 1
  end
end
for k, n in pairs(reads) do print(k .. " " .. n) end
'''


def i32(value: int) -> tuple[int, int]:
    raw = value & 0xFFFFFFFF
    return raw >> 16, raw & 0xFFFF


def i16(value: int) -> int:
    return value & 0xFFFF


def site(charge_limit_w: int = 4500, **singles: int) -> dict[int, int]:
    hi, lo = i32(charge_limit_w)
    regs = {
        39070: 2752, 39071: 1130,     # PV string 1 V/A
        39141: 354,                   # inverter heatsink 35.4 C
        39227: 1839,                  # battery 183.9 V
        39237: i32(-3000)[0], 39238: i32(-3000)[1],  # charging 3 kW
        37611: 254,                   # battery 25.4 C
        37612: 60,
        37617: 312,                   # hottest cell 31.2 C
        37618: i16(-50),              # coldest cell -5.0 C
        46018: hi, 46019: lo,
    }
    regs.update({int(k): v for k, v in singles.items()})
    return regs


def run(registers: dict[int, int], fail: tuple[int, ...] = (),
        polls: int = 1) -> dict[str, str]:
    setup = "\n".join(
        f"host._modbus_registers.holding[{addr}] = {value}"
        for addr, value in registers.items())
    setup += "\n" + "\n".join(
        f'host._modbus_read_fail_addresses[{addr}] = "timeout"'
        for addr in fail)
    script = (
        f'package.path = "{HARNESS}/?.lua;" .. package.path\n'
        'require("host_mock")\n'
        "host.reset()\n"
        f"{setup}\n"
        f'dofile("{DRIVER}")\n'
        "driver_init({})\n"
        f"for i = 1, {polls} do\n"
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


def test_foxess_h3_smart_reports_charge_limit_and_temperatures():
    out = run(site())
    assert num(out, "battery.available_charge_W") == 4500
    assert "battery.available_discharge_W" not in out
    assert num(out, "battery.temperature_C") == pytest.approx(25.4, abs=1e-3)
    assert num(out, "metric.battery_temp_c") == pytest.approx(25.4, abs=1e-3)
    assert num(out, "metric.battery_available_charge_w") == 4500
    assert num(out, "metric.battery_cell_temp_max_c") == pytest.approx(31.2, abs=1e-3)
    assert num(out, "metric.battery_cell_temp_min_c") == pytest.approx(-5.0, abs=1e-3)
    assert num(out, "metric.inverter_temp_c") == pytest.approx(35.4, abs=1e-3)
    assert num(out, "pv.temp_c") == pytest.approx(35.4, abs=1e-3)
    assert num(out, "metric.foxess_bms_charge_limit_w") == 4500


def test_foxess_h3_smart_negative_limit_reads_as_its_magnitude():
    # The sign of 46018 varies by firmware; the magnitude is the limit.
    out = run(site(charge_limit_w=-4500))
    assert num(out, "battery.available_charge_W") == 4500


def test_foxess_h3_smart_zero_limit_is_left_out():
    out = run(site(charge_limit_w=0))
    assert "battery.available_charge_W" not in out
    assert "metric.battery_available_charge_w" not in out
    # The diagnostic metric still shows the sleeping register.
    assert num(out, "metric.foxess_bms_charge_limit_w") == 0


def test_foxess_h3_smart_failed_reads_are_left_out():
    out = run(site(), fail=(46018, 37611, 37617, 37618, 39063))
    for key in ("battery.available_charge_W", "battery.temperature_C",
                "metric.battery_temp_c", "metric.battery_available_charge_w",
                "metric.battery_cell_temp_max_c",
                "metric.battery_cell_temp_min_c",
                "metric.inverter_temp_c", "metric.foxess_bms_charge_limit_w"):
        assert key not in out, key
    # The battery stream itself still goes out.
    assert num(out, "battery.W") == 3000


def test_foxess_h3_smart_out_of_range_values_are_dropped():
    out = run(site(charge_limit_w=30000,  # above the driver's 20 kW bound
                   **{"37611": 1500,       # 150 C
                      "37617": 1200,       # 120 C
                      "37618": i16(-500),  # -50 C
                      "39141": 1100}))     # 110 C
    for key in ("battery.available_charge_W", "battery.temperature_C",
                "metric.battery_temp_c", "metric.battery_cell_temp_max_c",
                "metric.battery_cell_temp_min_c", "metric.inverter_temp_c",
                "pv.temp_c"):
        assert key not in out, key


def test_foxess_h3_smart_cell_temperatures_read_every_sixth_poll():
    out = run(site(), polls=12)
    assert int(out["reads.37617"]) == 2
    assert int(out["reads.37618"]) == 2
    assert int(out["reads.37611"]) == 12


def test_foxess_h3_smart_absent_cell_temperatures_settle():
    out = run(site(), fail=(37617, 37618), polls=60)
    assert int(out["reads.37617"]) <= 3
    assert int(out["reads.37618"]) <= 3
