"""An unreachable Pixii must not retire every register.

Each register used to keep its own failure count and stop after three misses,
for the life of the process. That is the right behaviour for register 40288,
which old PowerShaper firmware never answers while the rest of the device is
up. It is the wrong behaviour when the whole device is down: three polls at
five seconds, about fifteen seconds, and every register is retired. A Pixii
that boots slower than FTW then answers into a driver that has stopped
asking, and telemetry stays dark until a restart.

Misses count only when some other read in that poll succeeded. A poll of
nothing but failures leaves the counts alone. After that stretch, the next
poll that gets an answer clears them. A register that stays silent while the
device is up is still left alone, and is tried again five minutes later.
"""

from pathlib import Path
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"
pytestmark = pytest.mark.skipif(not LUA.exists(), reason="run make test-driver ID=pixii")

RETRY_MS = 5 * 60 * 1000


def run_lua(body: str) -> None:
    script = '''
package.path = "drivers/tests/lua_harness/?.lua;" .. package.path
require("host_mock")
host.reset()

local function reads_of(addr, from_index)
    local n = 0
    for i = from_index or 1, #host._calls do
        local call = host._calls[i]
        if call.func == "modbus_read" and call.args[1] == addr then
            n = n + 1
        end
    end
    return n
end

local function last(kind)
    local emitted = host._emitted[kind]
    assert(emitted and #emitted > 0, "no " .. kind .. " telemetry")
    return emitted[#emitted]
end

local function at(ms)
    host._millis_counter = ms
    return driver_poll()
end

dofile("drivers/lua/pixii.lua")
''' + body
    result = subprocess.run(
        [str(LUA), "-e", script], cwd=ROOT, text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr


def test_pixii_recovers_when_the_device_boots_after_the_driver() -> None:
    """The device is unreachable from init through more than three polls, then answers."""
    run_lua('''
host._modbus_registers.holding[40168] = 2500
host._modbus_registers.holding[40132] = 80
host._modbus_registers.holding[40252] = 4200
host._modbus_read_error = "connection refused"
driver_init({host = "127.0.0.1", port = 502, unit_id = 1})

local from = #host._calls + 1
for _ = 1, 6 do
    local interval = driver_poll()
    assert(interval == 5000, "poll interval " .. tostring(interval))
end
assert(reads_of(40168, from) == 6,
    "stopped reading battery power while the device was down, reads=" .. reads_of(40168, from))
assert(reads_of(40252, from) == 6,
    "stopped reading meter power while the device was down, reads=" .. reads_of(40252, from))

host._modbus_read_error = nil
from = #host._calls + 1
local interval = driver_poll()
assert(interval == 5000, "poll interval " .. tostring(interval))
assert(reads_of(40168, from) == 1, "battery power was not read once the device was up")
assert(reads_of(40252, from) == 1, "meter power was not read once the device was up")
local battery = last("battery")
local meter = last("meter")
assert(battery.w == 2500, "battery.w " .. tostring(battery.w))
assert(battery.soc == 0.8, "battery.soc " .. tostring(battery.soc))
assert(meter.w == 4200, "meter.w " .. tostring(meter.w))
''')


def test_pixii_outage_does_not_add_to_an_existing_failure_count() -> None:
    """Two real misses, then a stretch where nothing answers, must not retire the register."""
    run_lua('''
host._modbus_registers.holding[40168] = 2500
host._modbus_read_fail_addresses[40168] = "timeout"
driver_init({host = "127.0.0.1", port = 502, unit_id = 1})
driver_poll()
driver_poll()
assert(reads_of(40168) == 2, "battery power reads before the outage " .. reads_of(40168))

host._modbus_read_fail_addresses[40168] = nil
host._modbus_read_error = "connection refused"
local from = #host._calls + 1
for _ = 1, 4 do driver_poll() end
assert(reads_of(40168, from) == 4,
    "outage retired battery power, reads during the outage=" .. reads_of(40168, from))

host._modbus_read_error = nil
from = #host._calls + 1
driver_poll()
assert(reads_of(40168, from) == 1, "battery power was not read after the outage")
local battery = last("battery")
assert(battery.w == 2500, "battery.w " .. tostring(battery.w))
''')


def test_pixii_retries_an_absent_register_after_five_minutes() -> None:
    """40288 stays quiet while the device is up, then gets one probe at five minutes."""
    run_lua(f'''
host._millis_step = 0
host._modbus_read_fail_addresses[40288] = "Illegal Data Address"
driver_init({{host = "127.0.0.1", port = 502, unit_id = 1}})
at(1000)
at(2000)
at(3000)
assert(reads_of(40288) == 3, "40288 reads before give-up " .. reads_of(40288))

local from = #host._calls + 1
at(3000 + {RETRY_MS} - 1)
assert(reads_of(40288, from) == 0, "40288 was read before five minutes")

from = #host._calls + 1
at(3000 + {RETRY_MS})
assert(reads_of(40288, from) == 1, "40288 was not probed at five minutes")

from = #host._calls + 1
at(3000 + {RETRY_MS})
assert(reads_of(40288, from) == 0, "a failed retry was read again on the next poll")
assert(reads_of(40256, from) == 1, "a present scale factor stopped being read")
assert(last("battery") ~= nil)
assert(last("meter") ~= nil)
''')


def test_pixii_outage_clears_give_up_without_waiting_five_minutes() -> None:
    """A register retired while the device was up is probed again after an unreachable stretch."""
    run_lua('''
host._millis_step = 0
host._modbus_registers.holding[40252] = 4200
host._modbus_read_fail_addresses[40288] = "Illegal Data Address"
driver_init({host = "127.0.0.1", port = 502, unit_id = 1})
at(1000)
at(2000)
at(3000)
assert(reads_of(40288) == 3, "40288 reads before give-up " .. reads_of(40288))

local from = #host._calls + 1
at(8000)
assert(reads_of(40288, from) == 0, "40288 was read after it was given up")

host._modbus_read_error = "connection refused"
at(10000)
at(15000)
host._modbus_read_error = nil

from = #host._calls + 1
for i = 1, 5 do at(20000 + i * 5000) end
local n = reads_of(40288, from)
assert(n == 3, "40288 reads after the outage " .. n)
assert(last("meter").w == 4200, "meter.w " .. tostring(last("meter").w))
''')
