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


# --------------------------------------------------------------------------
# Startup traffic, and the line it must not cross
#
# configure_power_limits reads three battery registers at startup -- charge
# power, discharge power, and the SoC ceiling and floor -- and raises the
# first two when the unit shipped capped. A model that named itself a string
# inverter answers none of them, so an SG12RT paid three failed reads on every
# restart to learn nothing.
#
# These run once rather than on every poll, so they are not the SG12RT outage.
# The reason to gate them is that they are free to gate: each write is already
# conditional on its read having answered, and none of them clears a forced
# state.
#
# That last clause is the whole boundary, and the last test here holds it. An
# earlier draft of this change gated set_self_consumption on the same family
# test. A device classified "string" is not proof there is nothing to release:
# an inverter can arrive already holding EMS mode 2 -- a container that died
# mid-force, an installer app, a version that wrote it before restarting -- and
# a Sungrow hybrid shipped under a device-type code classify_device_type has
# not been taught lands in that branch as well. set_self_consumption is the
# only thing that writes mode 0 back. Gating it left such a device forced with
# nothing able to release it.
# --------------------------------------------------------------------------

BATTERY_LIMIT_BLOCK = [13057, 33046, 33047]


def fail_battery_limit_block() -> str:
    addresses = ", ".join(str(a) for a in BATTERY_LIMIT_BLOCK)
    return f'''
for _, addr in ipairs({{{addresses}}}) do
    host._modbus_read_fail_addresses[addr] = "Illegal Data Address"
end
'''


# The SG12RT as it really answers at startup: no hybrid block, and no battery
# limit registers either.
SG_AT_STARTUP = STRING_INVERTER + fail_battery_limit_block()


def startup_reads(device: str) -> str:
    return device + f'''
dofile("{DRIVER}")
driver_init({{}})
local failed, limit_reads, off_ems = 0, 0, 0
for _, call in ipairs(host._calls) do
    if call.func == "modbus_read" then
        local addr = call.args[1]
        if host._modbus_read_fail_addresses[addr] then
            failed = failed + 1
            if addr ~= 13049 then off_ems = off_ems + 1 end
        end
        for _, limit in ipairs({{13057, 33046, 33047}}) do
            if addr == limit then limit_reads = limit_reads + 1 end
        end
    end
end
print("FAILED_READS " .. tostring(failed))
print("FAILED_OFF_EMS " .. tostring(off_ems))
print("LIMIT_READS " .. tostring(limit_reads))
print("WRITES " .. tostring(host._modbus_write_attempts))
'''


def test_string_inverter_startup_reads_no_battery_limit_it_cannot_have() -> None:
    out = run_lua(startup_reads(SG_AT_STARTUP))

    assert out["LIMIT_READS"] == "0", (
        f"startup read the battery limit block {out['LIMIT_READS']} times on "
        f"a model that named itself a string inverter. 33046, 33047 and 13057 "
        f"are battery registers; this family has no battery.")
    assert out["FAILED_OFF_EMS"] == "0", (
        f"startup failed {out['FAILED_OFF_EMS']} reads outside the EMS "
        f"registers. Those are the ones nothing needs.")

    # Two failed reads remain, both at 13049, and both are meant to. One is
    # set_self_consumption's readback, which must run on every family --
    # see test_the_release_is_still_reachable_on_a_string_inverter.
    # The other is the startup EMS-state log, which is exactly where a device
    # misclassified as "string" while holding mode 2 would show up. Gating
    # either to make this number nicer would cost more than it saves.
    assert out["FAILED_READS"] == "2", (
        f"startup cost {out['FAILED_READS']} failed reads, not the 2 expected "
        f"at 13049. Read the comment above before changing this number.")


def test_hybrid_still_gets_its_power_limits_raised() -> None:
    """The regression risk of gating: some units ship capped at 100 W."""
    body = HEALTHY_HYBRID + '''
host._modbus_registers.holding[33046] = {10}
host._modbus_registers.holding[33047] = {10}
''' + startup_reads("")
    out = run_lua(body)

    assert int(out["LIMIT_READS"]) >= 3, (
        "a hybrid must still be asked about its charge and discharge caps")
    raised = int(out["WRITES"])
    assert raised >= 2, (
        f"the hybrid shipped capped at 0.1 kW and startup made {raised} "
        f"writes. Some Sungrow units ship with discharge capped at 100 W, and "
        f"raising it is what this function is for.")


def test_the_release_is_still_reachable_on_a_string_inverter() -> None:
    """The line the startup gate must not cross.

    "The device named itself a string inverter" is not proof there is nothing
    to release. An inverter can arrive already holding EMS mode 2 -- a
    container that died mid-force, an installer app, a version that wrote it
    before restarting -- and a Sungrow hybrid shipped under a device-type code
    classify_device_type has not been taught lands in that branch as well.

    So the device below starts at mode 2, which is the state driver_init's
    unconditional reset exists for. Gate set_self_consumption on the family and
    this fails: the device stays forced through init, through the watchdog and
    through cleanup, with nothing left that can clear it.
    """
    body = '''
-- Classified "string" by device type, and holding a forced state on arrival.
host._modbus_registers.input[4999] = {0x2434}
host._modbus_registers.input[5000] = {120}
host._modbus_registers.input[5016] = {4000, 0}
host._modbus_registers.holding[13049] = 2
host._modbus_registers.holding[13050] = 0xAA
host._modbus_registers.holding[13051] = 3000
''' + f'''
dofile("{DRIVER}")
print("ON_ARRIVAL " .. tostring(host._modbus_registers.holding[13049]))
driver_init({{}})
print("AFTER_INIT " .. tostring(host._modbus_registers.holding[13049]))
for poll = 1, 3 do pcall(driver_poll) end
host._modbus_registers.holding[13049] = 2 -- forced again, however it got there
driver_default_mode()
print("AFTER_WATCHDOG " .. tostring(host._modbus_registers.holding[13049]))
host._modbus_registers.holding[13049] = 2
driver_cleanup()
print("AFTER_CLEANUP " .. tostring(host._modbus_registers.holding[13049]))
'''
    out = run_lua(body)

    assert out["ON_ARRIVAL"] == "2", "the fixture must start forced"
    assert out["AFTER_INIT"] == "0", (
        f"init left EMS mode at {out['AFTER_INIT']}, not 0. A driver that has "
        f"just classified this device as a string inverter still has to clear "
        f"a forced state it found there -- that is what the reset is for.")
    assert out["AFTER_WATCHDOG"] == "0", (
        f"the watchdog left EMS mode at {out['AFTER_WATCHDOG']}, not 0. The "
        f"release is the only write that clears a forced state -- gating it on "
        f"the family strands the device.")
    assert out["AFTER_CLEANUP"] == "0", (
        f"cleanup left EMS mode at {out['AFTER_CLEANUP']}, not 0")


# --------------------------------------------------------------------------
# Zero watts, before the first poll
#
# srcfl/ftw#704 stalled here. FTW's TestSungrowZeroBatteryCommandForcesIdle
# loads the driver, sends {"action":"battery","power_w":0} with no poll first,
# and expects the forced-idle writes. The guard above refuses it: before the
# first poll nothing has named a family and no battery register has answered.
#
# 1.5.4 settled it by exempting zero from the guard. 1.5.6 takes that back.
# The refusal stands, and these tests carry the reason so it is not re-argued
# a third time.
#
# The case for waving zero through was that it is not a dispatch but the
# safety operation that hands a device back to itself, arriving from the
# lifecycle rather than the planner, so refusing it can strand an inverter in
# a forced state. Neither half survives contact with this driver on this host:
#
#   * Zero does not hand the inverter back. driver_command("battery", 0)
#     writes EMS mode 2 -- forced -- and pins the battery at 0 W under FTW's
#     control. The write that returns an inverter to its own self-consumption
#     is mode 0, and it lives in driver_default_mode.
#   * Zero does not arrive from the lifecycle either. On FTW the only producer
#     of a battery command is the dispatch loop in go/cmd/ftw/main.go. The
#     release is a separate entrypoint and it is not gated: Registry.SendDefault
#     reaches driver_default_mode on shutdown, lease expiry, the telemetry
#     watchdog and the stale-site-meter standdown, never through
#     driver_command. driver_init writes self-consumption too, before the run
#     loop can accept any command -- so the window where a battery command is
#     refused is a window where the inverter is already back on its own. On
#     the control v2 path FTW does not even rely on that: it calls
#     driver_default_mode_v2 itself once driver_init returns.
#
# Refusing therefore withholds nothing that is not reachable by a route which
# cannot refuse. Accepting would put mode 2 and a setpoint back on an SG
# inverter that implements neither, and report success, because the read-back
# that would catch it fails on that device too. That is the SG12RT bug again,
# arriving through the one action nobody thought to guard.
#
# The third argument for the exemption was that such a write fails at the
# Modbus layer anyway, so it costs nothing. The incident says otherwise:
# first_write_error returns false if any of the three writes errors, so had the
# SG12RT rejected them the driver would have stopped there. It did not -- it
# went on to the read-back and reported success. Some firmware takes a write to
# a register it does not implement.
#
# The residue is honest and small: if the init write fails on a real hybrid,
# battery commands are refused until the first poll confirms the battery --
# at most one poll interval, with driver_default_mode available throughout.
#
# The two copies agree on the guard, and the tests below hold both to it. They
# do NOT agree on what zero writes: the catalog driver forces idle (mode 2),
# the v2 target hands the inverter back (mode 0, device_state "default", which
# clears FTW's lease). The v2 target uses a different register map throughout
# -- 13050 and 13051 as per-direction limits rather than force command and
# setpoint -- so this is one question inside a larger one. It belongs to the
# register-map review packages/v1/sungrow/PILOT.md already requires before
# that target ships; its verification_status is "experimental" and the signed
# package builds from targets/ftw-observe.lua, so nothing here reaches
# hardware today. Written down because untested drift between these two files
# is how Pixii's 40288 came back.
# --------------------------------------------------------------------------

NOTHING_ANSWERED_YET = '''
-- No registers configured, so every read answers 0 -- both the mock's default
-- and Sungrow's documented "not present" code at 4999. No family named, no
-- battery register answered: the state a driver sits in between driver_init
-- and its first poll, and the state FTW's Go test leaves it in.
'''


def ems_mode_written() -> str:
    """Report the last value written to the EMS mode register, 13049.

    2 is forced control, 0 hands the inverter back to self-consumption. One
    line tells apart a command that takes the device over from one that
    releases it.
    """
    return '''
local mode = "none"
for _, call in ipairs(host._calls) do
    if call.func == "modbus_write" and call.args[1] == 13049 then
        mode = tostring(call.args[2])
    end
end
print("EMS_MODE_WRITTEN " .. mode)
local writes = {}
for _, call in ipairs(host._calls) do
    if call.func == "modbus_write" then
        writes[#writes + 1] = tostring(call.args[1]) .. "=" .. tostring(call.args[2])
    end
end
print("WRITE_LOG " .. table.concat(writes, ","))
'''


@pytest.mark.parametrize("driver", BOTH_DRIVERS)
def test_zero_watts_is_still_a_battery_command(driver: Path) -> None:
    """A setpoint of zero is a setpoint. It proves nothing about the battery.

    polls=0 is the order FTW can actually produce, and the earliest a command
    can reach a driver there: Registry.Add runs driver_init and then starts the
    run loop, whose select serves the command channel before the first poll
    timer fires -- and that timer is a full poll interval out, longer with
    host.set_warmup_s.

    Nothing here says this device has a battery: no family named, no battery
    register answered. A guard that trusts the number rather than the evidence
    is not a guard -- an SG string inverter takes a zero as readily as it
    takes a thousand, and answers success to both.
    """
    out = run_lua(NOTHING_ANSWERED_YET
                  + battery_command_on(driver, power_w=0, polls=0))

    assert out["ACCEPTED"] == "false", (
        f"{driver.name} accepted a zero-watt battery command on a device that "
        f"has confirmed nothing. Zero is not exempt: it writes the same three "
        f"registers to the same models, and reports the same false success.")
    assert out["WRITES"] == "0", (
        f"{driver.name} refused and still wrote {out['WRITES']} registers")
    assert out["CODE"] == "no_battery", (
        f"{driver.name} refused with code {out['CODE']!r}, not 'no_battery'")


def test_zero_watts_takes_the_inverter_over_rather_than_handing_it_back() -> None:
    """The claim that decides it.

    If zero released the device, refusing it would withhold a safety action.
    It does not: it writes mode 2 and holds the battery at 0 W under FTW's
    control. An inverter is more controlled after this command than before.
    """
    body = HEALTHY_HYBRID + f'''
dofile("{DRIVER}")
driver_init({{}})
for poll = 1, 3 do pcall(driver_poll) end
host._calls = {{}}
local accepted = driver_command("battery", 0, {{}})
print("ACCEPTED " .. tostring(accepted == true))
''' + ems_mode_written()
    out = run_lua(body)

    assert out["ACCEPTED"] == "true", (
        "a confirmed hybrid must still take a zero-watt setpoint")
    assert out["WRITE_LOG"] == "13049=2,13050=204,13051=0", (
        f"zero wrote {out['WRITE_LOG']}. FTW's Go test expects these three "
        f"and no others, so the two repositories agree on what zero does.")
    assert out["EMS_MODE_WRITTEN"] == "2", (
        f"zero left EMS mode at {out['EMS_MODE_WRITTEN']}. Mode 2 is forced "
        f"control; mode 0 is the release. Calling this a safety operation "
        f"reads it backwards.")


def release_before_any_poll(driver: Path) -> str:
    """Init, then the release, with no poll in between."""
    if driver == FTW_V2:
        call = '''
local result = driver_default_mode_v2({reason = "host_shutdown"})
print("RELEASED " .. tostring(result.status ~= "rejected"))
'''
    else:
        call = '''
print("RELEASED " .. tostring(driver_default_mode() == true))
'''
    return f'''
dofile("{driver}")
driver_init({{}})
host._calls = {{}}
{call}
''' + ems_mode_written()


@pytest.mark.parametrize("driver", BOTH_DRIVERS)
def test_the_release_is_never_gated(driver: Path) -> None:
    """Why refusing a battery command is safe, and the thing that must not move.

    Refusing costs nothing only while handing the inverter back stays
    reachable without evidence of a battery. Gate driver_default_mode the way
    driver_command is gated and the whole argument collapses: a device would
    then be able to hold a forced state that nothing is allowed to clear.
    """
    out = run_lua(NOTHING_ANSWERED_YET + release_before_any_poll(driver))

    assert out["RELEASED"] == "true", (
        f"{driver.name} refused to hand the inverter back on a device that "
        f"has confirmed nothing. Shutdown, lease expiry, the watchdog and the "
        f"stale-meter standdown all arrive here, and none of them can wait "
        f"for a poll.")
    assert out["EMS_MODE_WRITTEN"] == "0", (
        f"the release left EMS mode at {out['EMS_MODE_WRITTEN']}, not 0. "
        f"Anything else keeps the inverter under FTW's control.")


def test_init_hands_the_inverter_back_before_a_command_can_arrive() -> None:
    """The other reason refusing costs nothing.

    A container that dies mid-force leaves the inverter holding the last
    command. driver_init clears it -- and it runs before FTW's run loop exists
    to accept a command at all. So there is no window where a battery command
    is refused and the inverter is stranded in a forced state.
    """
    body = NOTHING_ANSWERED_YET + f'''
dofile("{DRIVER}")
driver_init({{}})
''' + ems_mode_written()
    out = run_lua(body)

    assert out["EMS_MODE_WRITTEN"] == "0", (
        f"driver_init left EMS mode at {out['EMS_MODE_WRITTEN']}. It has to "
        f"reach self-consumption unconditionally: the family is often still "
        f"unknown here, and an inverter still holding yesterday's forced "
        f"charge is the case this write exists for.")
