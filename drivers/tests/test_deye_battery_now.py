"""Deye reports what its battery can do now, and leaves out what it cannot read.

Core marks a battery "not following" when it gives less than ordered. Most
such notices on a real site were the BMS or the inverter holding the battery
back, not lost control. So the driver reports the BMS's own charge and
discharge current limits (registers 212-213) as watts at the battery voltage
read in the same poll, and the BMS temperature (217).

The open Deye maps document those registers for the three-phase hybrids
only, and the limits mean something only while register 111 says the battery
runs on its BMS. Elsewhere the driver does not read them. Register 111 is
asked again every 60 polls after three misses, so timeouts at start-up do
not turn the limits off until restart. A read that fails
is left out, never sent as zero: a battery at 0 °C looks cold, and a limit of
0 W tells Core the battery may not charge.

Deye stores temperatures as (°C * 10) + 1000. Releases before 2.2.0 read the
heatsink without that offset and so reported it 100 °C too high.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"
HARNESS = ROOT / "drivers" / "tests" / "lua_harness"
DRIVER = ROOT / "drivers" / "lua" / "deye.lua"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")

LV_THREE_PHASE = 0x0005
HV_THREE_PHASE = 0x0006
SINGLE_PHASE = 0x0003

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


def run(registers: dict[int, int], fail: tuple[int, ...] = (),
        polls: int = 1, then: str = "", more_polls: int = 0) -> dict[str, str]:
    """Poll `polls` times, run the Lua in `then`, poll `more_polls` more."""
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
        'driver_init({host = "127.0.0.1", port = 502, unit_id = 1})\n'
        "local function poll(n)\n"
        "  for i = 1, n do\n"
        "    local ok, err = pcall(driver_poll)\n"
        '    if not ok then print("POLL_ERROR " .. tostring(err)) os.exit(1) end\n'
        "  end\n"
        "end\n"
        f"poll({polls})\n"
        f"{then}\n"
        f"poll({more_polls})\n"
        + REPORT)
    result = subprocess.run([str(LUA), "-e", script],
                            capture_output=True, text=True, cwd=ROOT)
    assert result.returncode == 0, result.stdout + result.stderr
    return dict(line.split(" ", 1)
                for line in result.stdout.strip().splitlines() if " " in line)


def num(out: dict[str, str], key: str) -> float:
    assert key in out, f"{key} missing from {sorted(out)}"
    return float(out[key])


def lv_site() -> dict[int, int]:
    return {
        0: LV_THREE_PHASE,
        111: 1,          # battery runs on its BMS
        212: 100,        # BMS charge limit, A
        213: 80,         # BMS discharge limit, A
        217: 1250,       # BMS temperature 25.0 C
        541: 1350,       # heatsink 35.0 C
        587: 5200,       # 52.00 V (LV: x 0.01)
        588: 60,
    }


def test_deye_three_phase_lv_reports_bms_limits_and_temperatures():
    out = run(lv_site())
    assert num(out, "battery.available_charge_W") == pytest.approx(5200, rel=1e-4)
    assert num(out, "battery.available_discharge_W") == pytest.approx(4160, rel=1e-4)
    assert num(out, "battery.temp_c") == pytest.approx(25.0, abs=1e-3)
    assert num(out, "pv.temp_c") == pytest.approx(35.0, abs=1e-3)
    assert num(out, "metric.battery_temp_c") == pytest.approx(25.0, abs=1e-3)
    assert num(out, "metric.inverter_temp_c") == pytest.approx(35.0, abs=1e-3)
    assert num(out, "metric.battery_charge_limit_a") == 100
    assert num(out, "metric.battery_discharge_limit_a") == 80
    assert num(out, "metric.battery_available_charge_w") == pytest.approx(5200, rel=1e-4)
    assert num(out, "metric.battery_available_discharge_w") == pytest.approx(4160, rel=1e-4)


def test_deye_hv_limit_uses_the_hv_voltage_scale():
    # HV: register 587 is in 0.1 V, so 4000 is 400.0 V.
    out = run(lv_site() | {0: HV_THREE_PHASE, 587: 4000, 212: 25, 213: 30})
    assert num(out, "battery.available_charge_W") == pytest.approx(10000, rel=1e-4)
    assert num(out, "battery.available_discharge_W") == pytest.approx(12000, rel=1e-4)


def test_deye_zero_limit_from_the_bms_is_reported():
    # A BMS that refuses charge (full, or too cold) says 0 A: that is a
    # reading, and it reaches Core as 0 W.
    out = run(lv_site() | {212: 0})
    assert num(out, "battery.available_charge_W") == 0
    assert num(out, "metric.battery_charge_limit_a") == 0


def test_deye_limits_left_out_when_their_read_fails():
    out = run(lv_site(), fail=(212,))
    for key in ("battery.available_charge_W", "battery.available_discharge_W",
                "metric.battery_charge_limit_a",
                "metric.battery_discharge_limit_a",
                "metric.battery_available_charge_w",
                "metric.battery_available_discharge_w"):
        assert key not in out, key
    assert num(out, "battery.temp_c") == pytest.approx(25.0, abs=1e-3)


def test_deye_watts_left_out_without_a_fresh_voltage():
    out = run(lv_site(), fail=(587,))
    assert "battery.available_charge_W" not in out
    assert "battery.available_discharge_W" not in out
    assert "metric.battery_available_charge_w" not in out
    # The amps are the device's own reading and still go to history.
    assert num(out, "metric.battery_charge_limit_a") == 100
    assert num(out, "metric.battery_discharge_limit_a") == 80


def test_deye_battery_without_bms_reads_no_bms_registers():
    # 111 = 0: charging by voltage, lead-acid style. No BMS stands behind
    # 212-219, so they are not read and nothing is reported from them.
    out = run(lv_site() | {111: 0})
    assert "reads.212" not in out
    assert "reads.217" not in out
    assert "battery.available_charge_W" not in out
    assert "battery.temp_c" not in out
    assert "metric.battery_temp_c" not in out


def test_deye_single_phase_never_reads_the_three_phase_bms_block():
    out = run(lv_site() | {0: SINGLE_PHASE})
    assert "reads.111" not in out
    assert "reads.212" not in out
    assert "battery.available_charge_W" not in out
    # 217 is read as before.
    assert num(out, "battery.temp_c") == pytest.approx(25.0, abs=1e-3)


def test_deye_failed_temperature_reads_are_left_out():
    out = run(lv_site(), fail=(217, 541))
    assert "battery.temp_c" not in out
    assert "pv.temp_c" not in out
    assert "metric.battery_temp_c" not in out
    assert "metric.inverter_temp_c" not in out
    # The battery stream itself still goes out.
    assert num(out, "battery.soc") == pytest.approx(0.6, abs=1e-4)


def test_deye_out_of_range_values_are_dropped():
    out = run(lv_site() | {0: HV_THREE_PHASE, 587: 4000,
               217: 0,       # -100 C: no BMS answer, not a temperature
               541: 2200,    # 120 C
               212: 5000,    # 5000 A is no home battery's limit
               213: 900})    # 900 A * 400 V = 360 kW
    assert "battery.temp_c" not in out
    assert "pv.temp_c" not in out
    assert "metric.inverter_temp_c" not in out
    assert "metric.battery_charge_limit_a" not in out
    assert "battery.available_charge_W" not in out
    assert "battery.available_discharge_W" not in out
    assert num(out, "metric.battery_discharge_limit_a") == 900


def test_deye_absent_battery_mode_register_settles():
    # A three-phase unit that never answers 111 is asked on three polls in a
    # row, then left alone for 60 polls; the limit block is never read.
    out = run(lv_site(), fail=(111,), polls=60)
    assert int(out["reads.111"]) == 3
    assert "reads.212" not in out


def test_deye_battery_mode_is_read_once_a_minute():
    out = run(lv_site(), polls=24)
    assert int(out["reads.111"]) == 2
    assert int(out["reads.212"]) == 24


def test_deye_battery_mode_that_answers_late_turns_the_limits_on():
    # Three timeouts at start-up must not turn the limits off until restart.
    # After three misses register 111 is asked again 60 polls later.
    answer = 'host._modbus_read_fail_addresses[111] = nil'
    early = run(lv_site(), fail=(111,), polls=3, then=answer, more_polls=59)
    assert "battery.available_charge_W" not in early
    assert int(early["reads.111"]) == 3
    late = run(lv_site(), fail=(111,), polls=3, then=answer, more_polls=60)
    assert int(late["reads.111"]) == 4
    assert num(late, "battery.available_charge_W") == pytest.approx(5200, rel=1e-4)
    assert num(late, "metric.battery_charge_limit_a") == 100


def test_deye_battery_mode_retries_stay_rare_on_a_unit_without_it():
    out = run(lv_site(), fail=(111,), polls=123)
    # Polls 1-3, then 63 and 123.
    assert int(out["reads.111"]) == 5
    assert "reads.212" not in out
