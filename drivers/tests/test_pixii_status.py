"""Missing SunSpec status cannot prove that battery calibration finished."""

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
host._modbus_registers.holding[40132] = 50
host._modbus_registers.holding[40138] = 0
host._modbus_registers.holding[40143] = 3
dofile("drivers/lua/pixii.lua")
driver_init({})
local function poll(code)
    host._modbus_registers.holding[40137] = code
    host._metrics = {}
    driver_poll()
    return host._emitted.battery[#host._emitted.battery]
end
''' + body
    result = subprocess.run([str(LUA), "-e", script], cwd=ROOT, text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr


def test_pixii_unsupported_status_is_unknown_and_warns_once() -> None:
    run_lua('''
host._modbus_registers.holding[40138] = 0xffff
host._modbus_registers.holding[40143] = 0xffff
host._modbus_registers.holding[40144] = 0xffff
for i = 1, 10 do
    local battery = poll(0xffff)
    assert(battery.charge_status == "unknown", battery.charge_status)
    assert(battery.control_mode == "unknown", battery.control_mode)
    assert(battery.battery_state == "unknown", battery.battery_state)
    assert(battery.battery_vendor_state == nil)
    for _, name in ipairs({"battery_charge_status_code", "battery_control_mode_code",
                          "battery_state_code", "battery_vendor_state_code"}) do
        assert(host._metrics[name] == nil, name .. " emitted an unsupported value")
    end
    assert(not host._faulted, "unknown status invented a calibration fault")
end
local warnings = 0
for _, message in ipairs(host._logs) do
    if message:find("calibration state is unknown", 1, true) then warnings = warnings + 1 end
end
assert(warnings == 1, "expected one unknown-status warning, got " .. warnings)
assert(#host._emitted.meter == 10, "unknown status stopped meter telemetry")
''')


@pytest.mark.parametrize("unknown", ["0xffff", "99", "0"])
def test_pixii_unknown_status_does_not_clear_calibration(unknown: str) -> None:
    run_lua(f'''
poll(7)
assert(host._faulted, "TESTING did not block dispatch")
poll({unknown})
assert(host._faulted, "unknown status cleared calibration")
assert(host._fault_reason:find("calibrating", 1, true))
poll(4)
assert(not host._faulted, "valid charge status did not clear calibration")
''')


def test_pixii_failed_status_read_does_not_clear_calibration() -> None:
    run_lua('''
poll(7)
host._modbus_read_fail_addresses[40137] = "timeout"
local battery = poll(4)
assert(host._faulted, "failed status read cleared calibration")
assert(battery.charge_status == "unknown")
host._modbus_read_fail_addresses[40137] = nil
poll(3)
assert(not host._faulted, "valid status did not recover after a transient read failure")
''')


@pytest.mark.parametrize("status", [1, 2, 3, 4, 5, 6])
def test_pixii_known_status_can_clear_calibration(status: int) -> None:
    run_lua(f'''
poll(7)
poll({status})
assert(not host._faulted)
assert(host._metrics.battery_charge_status_code.value == {status})
assert(host._metrics.battery_control_mode_code.value == 0, "remote control code 0 is valid")
''')
