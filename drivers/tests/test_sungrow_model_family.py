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
FTW_V2 = ROOT / "packages" / "v1" / "sungrow" / "targets" / "ftw.lua"

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


UNIDENTIFIED_STRING = '''
-- The same SG12RT, except register 4999 never answers either. Detection gives
-- up after three tries and settles on "unknown", so nothing ever names this
-- device a string inverter -- only the silence of the 13xxx block does.
host._modbus_read_fail_addresses[4999] = "Illegal Data Address"
host._modbus_registers.input[5000] = {120}
host._modbus_registers.input[5016] = {4000, 0}
host._modbus_registers.input[5600] = {1500, 0}
''' + fail_hybrid_block()


UNIDENTIFIED_HYBRID = '''
-- An SH10RT whose device-type register is unreadable. Detection settles on
-- "unknown", the driver probes, and the battery block answers on the first
-- poll -- so it reads and reports this battery every five seconds.
host._modbus_read_fail_addresses[4999] = "Illegal Data Address"
host._modbus_registers.input[5000]  = {100}
host._modbus_registers.input[5016]  = {4000, 0}
host._modbus_registers.input[12999] = {0x0000}
host._modbus_registers.input[13000] = {0x0004}
host._modbus_registers.input[13002] = {5000, 0}
host._modbus_registers.input[13019] = {4800, 120, 900, 550}
host._modbus_registers.input[13026] = {1000, 0}
host._modbus_registers.input[13036] = {2000, 0}
host._modbus_registers.input[13040] = {3000, 0}
host._modbus_registers.input[13045] = {4000, 0}
host._modbus_registers.input[5600]  = {1500, 0}
'''


def test_unidentified_string_inverter_also_refuses_a_battery_command() -> None:
    """Classified as a string is not the only way to have no battery.

    When register 4999 never answers, detection settles on "unknown" and no
    classification ever says "string". A guard that tests only for "string"
    falls straight through, and an SG inverter whose device-type register is
    unreadable gets the EMS writes anyway -- the exact behaviour this driver
    is supposed to have stopped.
    """
    out = run_lua(UNIDENTIFIED_STRING + send_command("battery"))

    assert out["ACCEPTED"] == "false", (
        "an unidentified device that has never answered a battery register "
        "got a battery setpoint. The device type is the fast way to know "
        "there is no battery; the silence of the 13xxx block is the only way "
        "left when 4999 does not answer.")
    assert out["WRITES"] == "0", f"the refusal still wrote {out['WRITES']} registers"
    assert out["CODE"] == "no_battery", out


def test_unidentified_hybrid_still_takes_a_battery_command() -> None:
    """Why the guard is not `model_family == "hybrid"`.

    An SH inverter whose device-type register is unreadable settles on
    "unknown" too, but its battery block answers, so the driver reads that
    battery and reports its SoC on every poll. Refusing to command a battery
    the driver is actively reading would be an outage of its own -- and
    detection giving up is common enough that DETECT_ATTEMPTS exists for it.
    Evidence decides, not the absence of a positive label.
    """
    out = run_lua(UNIDENTIFIED_HYBRID + send_command("battery"))

    assert out["ACCEPTED"] == "true", (
        "battery control was denied to an inverter whose battery registers "
        "answer every poll, because register 4999 happened to be unreadable. "
        "Tightening the guard to a positively identified hybrid costs more "
        "than it saves.")
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


# --------------------------------------------------------------------------
# Both copies of this driver, held to one rule
#
# The Sungrow driver exists twice: the catalog driver the signed channel
# publishes, and the FTW v2 control target, which is a separate file and not
# generated from it. They speak different command ABIs -- v1 returns a boolean,
# v2 returns a result table -- but the rule underneath is the same, so one test
# states it once. Pixii's 40288 came back because the package target had its
# own green test; the v2 target here had no pytest at all, only a Lua harness
# CI does not run.
# --------------------------------------------------------------------------

BOTH_DRIVERS = [pytest.param(DRIVER, id="catalog"), pytest.param(FTW_V2, id="ftw-v2")]


def battery_command_on(driver: Path, power_w: int = 1000,
                       polls: int = 4) -> str:
    """Send one battery setpoint through whichever ABI this file speaks."""
    if driver == FTW_V2:
        call = '''
local result = driver_command_v2({
    command = "battery.set_power",
    runtime_action = "battery",
    inputs = {power_w = POWER_W},
})
print("ACCEPTED " .. tostring(result.status ~= "rejected"))
print("CODE " .. tostring(result.code or "none"))
'''
    else:
        call = '''
local accepted, refusal = driver_command("battery", POWER_W, {})
print("ACCEPTED " .. tostring(accepted == true))
print("CODE " .. tostring(type(refusal) == "table" and refusal.code or "none"))
'''
    call = call.replace("POWER_W", str(power_w))
    return f'''
dofile("{driver}")
driver_init({{}})
for poll = 1, {polls} do pcall(driver_poll) end
host._modbus_write_attempts = 0
{call}
print("WRITES " .. tostring(host._modbus_write_attempts))
'''


@pytest.mark.parametrize("driver", BOTH_DRIVERS)
@pytest.mark.parametrize("device,label", [
    pytest.param(STRING_INVERTER,
                 "a model that names itself a string inverter",
                 id="named-string"),
    pytest.param(UNIDENTIFIED_STRING,
                 "a model that names nothing and answers no battery register",
                 id="unidentified-string"),
])
def test_neither_copy_writes_a_battery_it_cannot_confirm(
        driver: Path, device: str, label: str) -> None:
    out = run_lua(device + battery_command_on(driver))

    assert out["ACCEPTED"] == "false", (
        f"{driver.name} accepted a battery setpoint on {label}. Writing "
        f"13049/13050/13051 to an inverter that does not implement them is "
        f"unexpected traffic to live hardware, and answering success renews "
        f"the lease on a battery that is not there.")
    assert out["WRITES"] == "0", (
        f"{driver.name} refused and still wrote {out['WRITES']} registers")
    assert out["CODE"] == "no_battery", (
        f"{driver.name} refused with code {out['CODE']!r}. Both control paths "
        f"refuse in one vocabulary or they drift apart again.")


@pytest.mark.parametrize("driver", BOTH_DRIVERS)
@pytest.mark.parametrize("device,label", [
    pytest.param(HEALTHY_HYBRID,
                 "an inverter that names itself a hybrid",
                 id="named-hybrid"),
    pytest.param(UNIDENTIFIED_HYBRID,
                 "an inverter whose battery answers but whose type does not",
                 id="unidentified-hybrid"),
])
def test_neither_copy_refuses_a_battery_it_can_confirm(
        driver: Path, device: str, label: str) -> None:
    """The other half. Refusing too much is also an outage."""
    out = run_lua(device + battery_command_on(driver))

    assert out["ACCEPTED"] == "true", (
        f"{driver.name} refused a battery setpoint on {label}. A driver that "
        f"reads a battery every poll and will not command it has taken a "
        f"control off the fleet.")


# ---------------------------------------------------------------------------
# Zero is not a dispatch
# ---------------------------------------------------------------------------
#
# A zero-power battery command is the host handing the device back to itself:
# forced mode off, setpoint nought. It arrives from the lifecycle rather than
# the planner, so it can land before the first poll -- when nothing has been
# confirmed and the guard above would otherwise refuse it.
#
# Refusing to write "stop" is a different risk from refusing to write
# "charge". A device left in a forced state stays there, and the safe default
# is the one path that must never be gated on how much is known about the
# hardware. On a string inverter the write fails at the Modbus layer and costs
# nothing; the outage it prevents is a battery with no way to be told to stop.
#
# FTW's TestSungrowZeroBatteryCommandForcesIdle sends exactly this, straight
# after load. These cases are that test's rule, held here so the two cannot
# drift.

@pytest.mark.parametrize("driver", BOTH_DRIVERS)
@pytest.mark.parametrize("device,label", [
    pytest.param(STRING_INVERTER,
                 "a model that names itself a string inverter",
                 id="named-string"),
    pytest.param(UNIDENTIFIED_STRING,
                 "a model that names nothing and answers no battery register",
                 id="unidentified-string"),
    pytest.param(HEALTHY_HYBRID, "a hybrid", id="hybrid"),
])
def test_zero_is_never_refused(driver: Path, device: str, label: str) -> None:
    out = run_lua(device + battery_command_on(driver, power_w=0))

    # Not refused by the guard is the rule. Whether the write then succeeds is
    # a separate matter: on a device that does not implement 13049 the
    # read-back fails and the driver says so, which is the honest outcome. The
    # thing that must never happen is the command being turned away before it
    # is tried.
    assert out["CODE"] != "no_battery", (
        f"{driver.name} refused a zero-power battery command on {label}. Zero "
        f"is the safe default -- the host handing the device back to itself. "
        f"A driver that will not accept 'stop' can leave a battery in a "
        f"forced state with no way out.")


@pytest.mark.parametrize("driver", BOTH_DRIVERS)
def test_zero_lands_before_the_first_poll(driver: Path) -> None:
    """The ordering FTW's Go suite exercises: load, then command, no poll.

    Nothing has answered yet, so neither the model family nor the battery is
    confirmed. This is precisely when the guard must not fire.
    """
    out = run_lua(UNIDENTIFIED_STRING
                  + battery_command_on(driver, power_w=0, polls=0))

    assert out["CODE"] != "no_battery", (
        f"{driver.name} refused a zero-power command issued before the first "
        f"poll. Detection has had no chance to run at that point, and a "
        f"safety idle cannot wait for it.")
