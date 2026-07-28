"""Sungrow must not read, or drive, a battery that is not there.

Sungrow ships two families behind one driver. SH hybrids answer the 13xxx
block; SG string inverters have no battery and answer none of it. The host
fails a whole poll when any single read fails, so reading the hybrid block on a
string inverter does not return less telemetry -- it returns none. A customer's
SG12RT lost all telemetry for weeks this way, with 12 of 19 reads failing on
every poll.

These tests exist so that cannot come back. The first one is the incident.

The last few hold the write path to the same fact. The read path learned the
two families apart in 1.4.0; `driver_command` did not, and went on writing an
EMS setpoint to a model the driver itself had already classified as having no
battery -- and reporting success.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"
HARNESS = ROOT / "drivers" / "tests" / "lua_harness"
DRIVER = ROOT / "drivers" / "lua" / "sungrow.lua"

# Every address in the hybrid block this driver touches.
HYBRID_BLOCK = [12999, 13000, 13002, 13019, 13026, 13036, 13040, 13045, 13049]

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")


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


def poll_loop(polls: int = 8) -> str:
    """Poll and report how many reads failed on each one."""
    return f'''
dofile("{DRIVER}")
driver_init({{}})
local per_poll = {{}}
for poll = 1, {polls} do
    local before = #host._calls
    local ok, err = pcall(driver_poll)
    if not ok then print("POLL_ERROR " .. tostring(err)) os.exit(1) end
    local failed = 0
    for i = before + 1, #host._calls do
        local call = host._calls[i]
        if call.func == "modbus_read"
           and host._modbus_read_fail_addresses[call.args[1]] then
            failed = failed + 1
        end
    end
    per_poll[#per_poll + 1] = failed
end
print("FAILED_PER_POLL " .. table.concat(per_poll, ","))
print("BATTERY_EMITS " .. tostring(host._emitted["battery"] and #host._emitted["battery"] or 0))
'''


def fail_hybrid_block() -> str:
    addresses = ", ".join(str(a) for a in HYBRID_BLOCK)
    return f'''
for _, addr in ipairs({{{addresses}}}) do
    host._modbus_read_fail_addresses[addr] = "Illegal Data Address"
end
'''


STRING_INVERTER = '''
-- An SG12RT: answers the device type with a non-hybrid family code, has PV
-- and a grid meter, and answers nothing in the 13xxx block.
host._modbus_registers.input[4999] = {0x2434}
host._modbus_registers.input[5000] = {120}
host._modbus_registers.input[5016] = {4000, 0}
host._modbus_registers.input[5600] = {1500, 0}
''' + fail_hybrid_block()


def test_string_inverter_never_touches_the_hybrid_block() -> None:
    """The incident. Not one failed read, not even on the first poll."""
    out = run_lua(STRING_INVERTER + poll_loop())
    failed = [int(n) for n in out["FAILED_PER_POLL"].split(",")]

    assert failed == [0] * len(failed), (
        f"an SG string inverter cost {failed} failed reads per poll. The host "
        f"fails the whole poll on any failure, so anything but zero takes the "
        f"site offline. This is the SG12RT outage.")


def test_string_inverter_does_not_invent_a_battery() -> None:
    out = run_lua(STRING_INVERTER + poll_loop())
    assert int(out["BATTERY_EMITS"]) == 0, (
        "a string inverter has no battery; emitting one fabricates telemetry")


def test_unreadable_device_type_settles_instead_of_retrying_forever() -> None:
    """Giving up is the point.

    A register retried on every poll forever costs a failed read on every poll
    forever, which is the same outage arriving more slowly.
    """
    body = '''
host._modbus_read_fail_addresses[4999] = "Illegal Data Address"
host._modbus_read_fail_addresses[4990] = "Illegal Data Address"
host._modbus_registers.input[5016] = {4000, 0}
''' + fail_hybrid_block() + poll_loop(polls=10)

    out = run_lua(body)
    failed = [int(n) for n in out["FAILED_PER_POLL"].split(",")]
    assert failed[-1] == 0, (
        f"failed reads settled at {failed[-1]}, not 0: {failed}. Detection and "
        f"the serial read must both give up, or the site stays offline.")
    assert failed[-3:] == [0, 0, 0], f"should stay settled: {failed}"


HEALTHY_HYBRID = '''
-- A healthy SH10RT that answers everything.
host._modbus_registers.input[4999]  = {0x0E0E}
host._modbus_registers.input[5000]  = {100}
host._modbus_registers.input[5016]  = {4000, 0}
host._modbus_registers.input[12999] = {0x0000}
host._modbus_registers.input[13000] = {0x0004}   -- bit 2 set: discharging
host._modbus_registers.input[13002] = {5000, 0}
host._modbus_registers.input[13019] = {4800, 120, 900, 550}
host._modbus_registers.input[13026] = {1000, 0}
host._modbus_registers.input[13036] = {2000, 0}
host._modbus_registers.input[13040] = {3000, 0}
host._modbus_registers.input[13045] = {4000, 0}
host._modbus_registers.input[5600]  = {1500, 0}
'''


def test_hybrid_still_reports_its_battery() -> None:
    """The regression risk of gating: a real hybrid must lose nothing."""
    body = HEALTHY_HYBRID + f'''
dofile("{DRIVER}")
driver_init({{}})
for poll = 1, 3 do
    local ok, err = pcall(driver_poll)
    if not ok then print("POLL_ERROR " .. tostring(err)) os.exit(1) end
end
local b = host._emitted["battery"][1]
print("BATTERY_W " .. tostring(b.w))
print("BATTERY_SOC " .. tostring(b.soc))
print("BATTERY_CHARGE_WH " .. tostring(b.charge_wh))
print("BATTERY_DISCHARGE_WH " .. tostring(b.discharge_wh))
print("METER_IMPORT_WH " .. tostring(host._emitted["meter"][1].import_wh))
'''
    out = run_lua(body)
    # Sungrow reports magnitude unsigned with direction in the status register.
    # Bit 2 is set, so it is discharging, and our convention makes that negative.
    assert float(out["BATTERY_W"]) == -900.0, out
    assert abs(float(out["BATTERY_SOC"]) - 0.55) < 1e-9, out
    assert float(out["BATTERY_CHARGE_WH"]) == 300000.0, out
    assert float(out["BATTERY_DISCHARGE_WH"]) == 100000.0, out
    assert float(out["METER_IMPORT_WH"]) == 200000.0, out


def test_fault_clears_on_a_running_state_of_zero() -> None:
    """0x0000 is Running, not "no answer".

    The previous version cleared the fault only on a non-zero value, so an
    inverter that recovered into 0x0000 stayed reported as faulted.
    """
    body = HEALTHY_HYBRID + f'''
dofile("{DRIVER}")
driver_init({{}})
local states = {{}}
local function poll_with(state)
    host._modbus_registers.input[12999] = {{state}}
    pcall(driver_poll)
    states[#states + 1] = host._faulted and "1" or "0"
end
poll_with(0x0000)
poll_with(0x5500)
poll_with(0x0000)
poll_with(0x0100)
poll_with(0x0040)
print("FAULTS " .. table.concat(states, ","))
'''
    out = run_lua(body)
    assert out["FAULTS"] == "0,1,0,1,0", (
        f"fault channel went {out['FAULTS']}, expected 0,1,0,1,0. Both 0x0000 "
        f"and 0x0040 are documented Running states and must clear a fault.")


def test_string_inverter_neither_raises_nor_clears_a_fault() -> None:
    """It never reads the running state, so it has nothing to say about faults."""
    body = STRING_INVERTER + f'''
dofile("{DRIVER}")
driver_init({{}})
for poll = 1, 4 do pcall(driver_poll) end
local saw_fault_call = false
for _, call in ipairs(host._calls) do
    if call.func == "set_device_fault" then saw_fault_call = true end
end
print("FAULT_CALLED " .. tostring(saw_fault_call))
print("FAULTED " .. tostring(host._faulted))
'''
    out = run_lua(body)
    assert out["FAULT_CALLED"] == "false", (
        "a string inverter does not read the running state, so it must not "
        "claim anything about the device's fault status")
    assert out["FAULTED"] == "false", out


def send_command(action: str, power_w: int = 1000) -> str:
    """Let the driver settle on a family, then send it one command.

    The write counter is zeroed after init and the polls, so what it reports
    is what this one command wrote and nothing else.
    """
    return f'''
dofile("{DRIVER}")
driver_init({{}})
for poll = 1, 3 do pcall(driver_poll) end
host._modbus_write_attempts = 0
local accepted, refusal = driver_command("{action}", {power_w}, {{}})
print("ACCEPTED " .. tostring(accepted))
print("WRITES " .. tostring(host._modbus_write_attempts))
print("CODE " .. tostring(type(refusal) == "table" and refusal.code or "none"))
print("STATE " .. tostring(type(refusal) == "table" and refusal.device_state or "none"))
local reason = "none"
for _, line in ipairs(host._logs) do
    if string.find(line, "no battery registers", 1, true) then reason = "logged" end
end
print("REASON " .. reason)
'''


def test_string_inverter_refuses_a_battery_command() -> None:
    """The write half of the SG12RT fix.

    Accepting was worse than a no-op. The driver wrote forced mode, a force
    command and a setpoint into a block an SG string inverter does not
    implement, then answered success: the read-back that would have caught it
    fails on such a device, and a failed read-back is assumed transient and
    treated as good.
    """
    out = run_lua(STRING_INVERTER + send_command("battery"))

    assert out["ACCEPTED"] == "false", (
        "the driver reported a battery setpoint applied on an inverter it had "
        "already classified as having no battery. The host renews the lease on "
        "that answer, so the planner goes on dispatching a battery that is not "
        "there and nothing in the system contradicts it.")
    assert out["WRITES"] == "0", (
        f"the refusal still wrote {out['WRITES']} registers. 13049, 13050 and "
        f"13051 are not implemented on an SG string inverter, so these are "
        f"unexpected writes to live hardware, not a harmless no-op.")


def test_battery_refusal_says_why() -> None:
    """A bare false says the command failed. It does not say it never could."""
    out = run_lua(STRING_INVERTER + send_command("battery"))

    assert out["CODE"] == "no_battery", (
        f"the refusal carried code {out['CODE']!r}. It must be 'no_battery', "
        f"the same code packages/v1/sungrow/targets/ftw.lua already returns, "
        f"so both control paths refuse in one vocabulary.")
    assert out["STATE"] == "unchanged", (
        "a refused command touched nothing, and the host needs to be told so "
        "before it decides whether the device still needs default mode")
    assert out["REASON"] == "logged", (
        "an operator reading the logs gets no reason. Curtail already names "
        "its own when rated power is missing; so must this.")


def test_hybrid_still_takes_a_battery_command() -> None:
    """The regression risk of refusing: a real hybrid must lose control."""
    out = run_lua(HEALTHY_HYBRID + send_command("battery"))

    assert out["ACCEPTED"] == "true", (
        "an SH hybrid has a battery and the driver classified it as one. "
        "Refusing here would take battery control off every hybrid on the "
        "fleet, which is a larger outage than the one being fixed.")
    assert int(out["WRITES"]) > 0, "an accepted setpoint has to reach the device"


def test_string_inverter_still_takes_a_curtail_command() -> None:
    """Only the battery is missing. The PV cap is not.

    An SG string inverter answers the Active Power Limitation pair at
    13088/13089. Refusing that too would cost the fleet a control it has.
    """
    out = run_lua(STRING_INVERTER + send_command("curtail"))

    assert out["ACCEPTED"] == "true", (
        "curtail was refused on a model that supports it. The device has no "
        "battery; it does have PV.")
