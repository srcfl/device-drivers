"""An inverter that drops off the network is not an inverter without registers.

FTW's random site rig takes the Sungrow offline for 20 to 90 s and brings it
back (srcfl/ftw nightly, 27 October 2026). Every read and write fails while it
is gone, and none of those failures came from the device. Before 1.6.1 the
driver counted them as if they had:

- reads: 12999, 13000 and the PV registers were dropped for the session. 13000
  signs the battery, so FTW read a discharge as a charge for the rest of the
  run (seed 207539: 105 samples).
- writes: three failed EMS writes marked the block absent, so the release was
  reported as held without being written, while the inverter kept the last
  forced discharge (seed 207534: 5000 W for up to five minutes).

Only a Modbus exception, the device's own refusal, proves a register absent.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"
HARNESS = ROOT / "drivers" / "tests" / "lua_harness"
DRIVER = ROOT / "drivers" / "lua" / "sungrow.lua"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")

HEALTHY_HYBRID = '''
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

# What FTW's host hands the driver while the device is gone. The first is the
# dial error the rig logged; the last two are what a Modbus gateway answers
# when it cannot reach the device behind it.
LINK_ERRORS = [
    "dial tcp 127.0.0.1:502: connect: connection refused",
    "read after reconnect: modbus reconnect backoff active for 1.243s "
    "(original: EOF)",
    "modbus transport failure: i/o timeout",
    "modbus exception function=0x03 code=0x0b",
    "modbus exception function=0x06 code=0x0a",
]

REFUSAL = "modbus exception function=0x06 code=0x02"


def run_lua(body: str) -> dict[str, str]:
    script = f'''
package.path = "{HARNESS}/?.lua;" .. package.path
require("host_mock")
host.reset()
host._millis_step = 1000  -- one poll a second, a full read every five
{HEALTHY_HYBRID}
dofile("{DRIVER}")
driver_init({{}})
for _ = 1, 3 do driver_poll() end
{body}
'''
    result = subprocess.run([str(LUA), "-e", script],
                            capture_output=True, text=True, cwd=ROOT)
    assert result.returncode == 0, result.stdout + result.stderr
    return dict(line.split(" ", 1)
                for line in result.stdout.strip().splitlines() if " " in line)


def offline(err: str, polls: int = 5, defaults: int = 5) -> str:
    return f'''
host._modbus_read_error = "{err}"
host._modbus_write_error = "{err}"
for _ = 1, {polls} do driver_poll() end
for _ = 1, {defaults} do driver_default_mode() end
host._modbus_read_error = nil
host._modbus_write_error = nil
'''


def reads_on_next_poll() -> str:
    return '''
local before = #host._calls
driver_poll()
local read = {}
for i = before + 1, #host._calls do
    local call = host._calls[i]
    if call.func == "modbus_read" then read[call.args[1]] = true end
end
for _, addr in ipairs({12999, 13000, 5016, 5010}) do
    print("READ_" .. addr .. " " .. tostring(read[addr] == true))
end
local emits = host._emitted.battery
print("BATTERY_W " .. tostring(emits[#emits].w))
'''


@pytest.mark.parametrize("err", LINK_ERRORS)
def test_an_outage_does_not_drop_registers(err: str) -> None:
    """The device comes back; so must 13000 and the PV registers."""
    # Five polls: one full read lands every five, so 12999 is read too.
    out = run_lua(offline(err, polls=12, defaults=0)
                  + "for _ = 1, 4 do driver_poll() end\n"
                  + reads_on_next_poll())

    for addr in (13000, 5016, 5010):
        assert out[f"READ_{addr}"] == "true", (
            f"register {addr} was not read after the device came back: the "
            f"outage ({err!r}) was counted as proof it is absent. {out}")
    assert out["BATTERY_W"] == "-900", (
        f"the battery discharges at 900 W but reads {out['BATTERY_W']}: "
        f"13000, which signs it, was dropped during the outage")


def test_an_outage_does_not_drop_the_running_state() -> None:
    """12999 is read on full polls only, so check it across five."""
    out = run_lua(offline(LINK_ERRORS[0], polls=20, defaults=0) + '''
local before = #host._calls
for _ = 1, 6 do driver_poll() end
local seen = false
for i = before + 1, #host._calls do
    local call = host._calls[i]
    if call.func == "modbus_read" and call.args[1] == 12999 then seen = true end
end
print("READ_12999 " .. tostring(seen))
''')
    assert out["READ_12999"] == "true", out


def test_a_refused_register_is_still_given_up_while_others_answer() -> None:
    """The bound still works: an exception is the device saying no."""
    out = run_lua('''
host._modbus_read_fail_addresses[5743] = "Illegal Data Address"
for _ = 1, 4 do driver_poll() end
''' + '''
local before = #host._calls
driver_poll()
local read = false
for i = before + 1, #host._calls do
    if host._calls[i].func == "modbus_read" and host._calls[i].args[1] == 5743 then
        read = true
    end
end
print("READ_5743 " .. tostring(read))
''')
    assert out["READ_5743"] == "false", "a refused register was read forever"


def test_a_timeout_on_one_register_counts_while_the_rest_answer() -> None:
    """A transport-shaped failure still counts when the link is plainly up."""
    out = run_lua('''
host._modbus_read_fail_addresses[5743] = "i/o timeout"
for _ = 1, 4 do driver_poll() end
local before = #host._calls
driver_poll()
local read = false
for i = before + 1, #host._calls do
    if host._calls[i].func == "modbus_read" and host._calls[i].args[1] == 5743 then
        read = true
    end
end
print("READ_5743 " .. tostring(read))
''')
    assert out["READ_5743"] == "false", (
        "a register that times out while every other read answers was read "
        "forever")


def test_a_reconnect_starts_the_read_count_over() -> None:
    """Two refusals, an outage, then one more refusal: not yet three."""
    out = run_lua('''
host._modbus_read_fail_addresses[5743] = "Illegal Data Address"
driver_poll()
driver_poll()
host._modbus_read_error = "dial tcp 127.0.0.1:502: connect: connection refused"
driver_poll()
host._modbus_read_error = nil
driver_poll()
local before = #host._calls
driver_poll()
local read = false
for i = before + 1, #host._calls do
    if host._calls[i].func == "modbus_read" and host._calls[i].args[1] == 5743 then
        read = true
    end
end
print("READ_5743 " .. tostring(read))
''')
    assert out["READ_5743"] == "true", (
        "misses counted before an outage carried over the reconnect")


def forced_then(body: str) -> str:
    return '''
print("FORCED " .. tostring(driver_command("battery", -3000, {}) == true))
''' + body + '''
host._modbus_write_attempts = 0
local held = driver_default_mode()
print("RELEASE_WRITES " .. tostring(host._modbus_write_attempts))
print("RELEASED " .. tostring(held == true))
print("MODE " .. tostring(host._modbus_registers.holding[13049]))
'''


@pytest.mark.parametrize("err", LINK_ERRORS)
def test_the_release_is_written_when_the_device_returns(err: str) -> None:
    """Seeds 207533-207539: a forced discharge outlived the outage."""
    out = run_lua(forced_then(offline(err)))

    assert out["FORCED"] == "true"
    assert int(out["RELEASE_WRITES"]) >= 3, (
        f"the inverter came back holding forced discharge and the watchdog's "
        f"release wrote {out['RELEASE_WRITES']} registers. The outage "
        f"({err!r}) was counted as the device refusing the EMS block.")
    assert out["MODE"] == "0", f"EMS mode left at {out['MODE']}, not 0"
    assert out["RELEASED"] == "true"


def test_the_release_is_never_reported_held_while_forced_mode_may_be_latched() -> None:
    """Even three real refusals do not excuse it once forced mode landed."""
    out = run_lua(forced_then(f'''
host._modbus_write_error = "{REFUSAL}"
local answers = {{}}
for _ = 1, 5 do answers[#answers + 1] = tostring(driver_default_mode()) end
print("DURING " .. table.concat(answers, ","))
host._modbus_write_error = nil
'''))

    assert "true" not in out["DURING"].split(","), (
        f"driver_default_mode reported the default held without writing it: "
        f"{out['DURING']}. This driver put the inverter in forced mode, so "
        f"the inverter may still be holding it.")
    assert int(out["RELEASE_WRITES"]) >= 3
    assert out["MODE"] == "0"


def test_failures_during_an_outage_report_the_release_as_failed() -> None:
    """While nothing reaches the device, the honest answer is false."""
    out = run_lua(forced_then('''
host._modbus_read_error = "dial tcp 127.0.0.1:502: connect: connection refused"
host._modbus_write_error = host._modbus_read_error
local answers = {}
for _ = 1, 5 do answers[#answers + 1] = tostring(driver_default_mode()) end
print("DURING " .. table.concat(answers, ","))
host._modbus_read_error = nil
host._modbus_write_error = nil
'''))
    assert out["DURING"] == ",".join(["false"] * 5), out["DURING"]


def test_a_reconnect_starts_the_write_count_over() -> None:
    """Two refusals, an outage, then two more: not yet three in a row."""
    out = run_lua(f'''
host._modbus_write_error = "{REFUSAL}"
driver_default_mode()
driver_default_mode()
host._modbus_write_error = nil
host._modbus_read_error = "dial tcp 127.0.0.1:502: connect: connection refused"
driver_poll()
host._modbus_read_error = nil
driver_poll()
host._modbus_write_error = "{REFUSAL}"
driver_default_mode()
driver_default_mode()
host._modbus_write_attempts = 0
driver_default_mode()
print("WRITES " .. tostring(host._modbus_write_attempts))
''')
    assert int(out["WRITES"]) >= 3, (
        "refusals counted before an outage carried over the reconnect")


def test_a_device_that_refuses_the_block_still_settles() -> None:
    """The SG12RT rule from 1.5.7 holds: never forced, three refusals, stop."""
    out = run_lua(f'''
host._modbus_write_error = "{REFUSAL}"
local writes = {{}}
for _ = 1, 6 do
    host._modbus_write_attempts = 0
    driver_default_mode()
    writes[#writes + 1] = host._modbus_write_attempts
end
print("WRITES " .. table.concat(writes, ","))
''')
    assert out["WRITES"].split(",")[-3:] == ["0", "0", "0"], out["WRITES"]
