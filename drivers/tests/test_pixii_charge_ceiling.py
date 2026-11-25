"""Pixii reports the highest charge level it will accept.

On one site the Pixii SoC register held at 90 while charge orders went
undelivered, and the Pixii app showed 100 % (srcfl/device-drivers#175). Pixii's
Modbus mapping names its upper SoC limits on the same scale as the SoC, SunSpec
SoCMax (40128) and SoCRsvMax (40130). The driver passes the lower valid one to
Core as max_soc_fract and leaves the SoC as read. The gross safety limits
(39915-39917) are on an undocumented scale and go to history only.
"""

from pathlib import Path
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"
pytestmark = pytest.mark.skipif(not LUA.exists(), reason="run make test-driver ID=pixii")


def run_lua(body: str) -> None:
    script = '''
package.path = "drivers/tests/lua_harness/?.lua;" .. package.path
require("host_mock")
host.reset()
host._modbus_registers.holding[40000] = {0x5375, 0x6e53}
host._modbus_registers.holding[40132] = 90
host._modbus_registers.holding[40137] = 4
host._modbus_registers.holding[40138] = 0
host._modbus_registers.holding[40143] = 3
dofile("drivers/lua/pixii.lua")
driver_init({})
local function poll()
    host._metrics = {}
    driver_poll()
    return host._emitted.battery[#host._emitted.battery]
end
local function near(a, b)
    return a ~= nil and math.abs(a - b) < 1e-9
end
''' + body
    result = subprocess.run([str(LUA), "-e", script], cwd=ROOT, text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr


def test_reserved_maximum_is_the_ceiling_and_soc_is_not_remapped() -> None:
    run_lua('''
host._modbus_registers.holding[40128] = {100, 5, 90, 10}
local battery = poll()
assert(near(battery.max_soc_fract, 0.90), "ceiling " .. tostring(battery.max_soc_fract))
assert(near(battery.soc, 0.90), "SoC was remapped: " .. tostring(battery.soc))
assert(host._metrics.battery_soc_max_pct.value == 100)
assert(host._metrics.battery_soc_min_pct.value == 5)
assert(host._metrics.battery_soc_reserve_max_pct.value == 90)
assert(host._metrics.battery_soc_reserve_min_pct.value == 10)
local logged = false
for _, message in ipairs(host._logs) do
    if message:find("charge ceiling 90", 1, true)
        and message:find("battery_soc_reserve_max_pct", 1, true) then
        logged = true
    end
end
assert(logged, "the ceiling and its source were not logged")
''')


def test_lower_of_soc_max_and_reserved_maximum_wins() -> None:
    run_lua('''
host._modbus_registers.holding[40128] = {92, 5, 95, 10}
local battery = poll()
assert(near(battery.max_soc_fract, 0.92), "ceiling " .. tostring(battery.max_soc_fract))
''')


def test_gross_safety_limits_are_history_only() -> None:
    run_lua('''
host._modbus_registers.holding[40128] = {100, 5, 95, 10}
host._modbus_registers.holding[39915] = {899, 50, 900}
local battery = poll()
assert(near(battery.max_soc_fract, 0.95), "a gross safety limit set the ceiling: "
    .. tostring(battery.max_soc_fract))
assert(near(host._metrics.battery_soc_gross_pct.value, 89.9))
assert(near(host._metrics.battery_soc_safety_min_pct.value, 5))
assert(near(host._metrics.battery_soc_safety_max_pct.value, 90))
''')


def test_soc_scale_factor_applies_to_the_limits() -> None:
    run_lua('''
host._modbus_registers.holding[40177] = 0xffff -- SoC_SF = -1
host._modbus_registers.holding[40132] = 900
host._modbus_registers.holding[40128] = {1000, 50, 900, 100}
local battery = poll()
assert(near(battery.soc, 0.90), "SoC " .. tostring(battery.soc))
assert(near(battery.max_soc_fract, 0.90), "ceiling " .. tostring(battery.max_soc_fract))
''')


def test_unimplemented_scale_factor_does_not_zero_the_soc() -> None:
    run_lua('''
host._modbus_registers.holding[40177] = 0x8000 -- SunSpec: not implemented
host._modbus_registers.holding[40128] = {100, 5, 90, 10}
local battery = poll()
assert(near(battery.soc, 0.90), "SoC " .. tostring(battery.soc))
assert(near(battery.max_soc_fract, 0.90), "ceiling " .. tostring(battery.max_soc_fract))
''')


@pytest.mark.parametrize("raw", ["0", "0xffff", "1010", "49"])
def test_zero_unsupported_implausible_or_impossible_limits_are_not_a_ceiling(raw: str) -> None:
    run_lua(f'''
host._modbus_registers.holding[40128] = {{{raw}, 0, {raw}, 0}}
host._modbus_registers.holding[39915] = {{0, 0, 900}}
local battery = poll()
assert(battery.max_soc_fract == nil, "invented ceiling " .. tostring(battery.max_soc_fract))
assert(near(battery.soc, 0.90), "SoC changed without a ceiling")
''')


def test_failed_limit_reads_leave_the_ceiling_out() -> None:
    run_lua('''
host._modbus_registers.holding[40128] = {100, 5, 90, 10}
assert(near(poll().max_soc_fract, 0.90))
host._modbus_read_fail_addresses[40128] = "timeout"
host._modbus_read_fail_addresses[39915] = "timeout"
local battery = poll()
assert(battery.max_soc_fract == nil, "a failed read kept or invented a ceiling")
for _, name in ipairs({"battery_soc_max_pct", "battery_soc_reserve_max_pct",
                       "battery_soc_safety_max_pct", "battery_soc_gross_pct"}) do
    assert(host._metrics[name] == nil, name .. " emitted without a read")
end
assert(near(battery.soc, 0.90), "a failed limit read lost the SoC")
assert(#host._emitted.meter == 2, "a failed limit read stopped meter telemetry")
''')
