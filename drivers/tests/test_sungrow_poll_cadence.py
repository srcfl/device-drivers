"""Sungrow reads what the live view needs every second, and the rest every five.

FTW sends live frames once a second. A site meter read every five seconds
makes the figures on a phone jump every five seconds. The driver now returns
1000 ms and splits its reads: power, SoC, per-phase values and the EMS
readback on every poll; counters, nameplate, temperature, frequency and fault
bits on a full poll every five seconds.

Between full polls the blobs carry the slow values, because FTW stores each
emit whole and its energy ledger re-baselines whenever a counter disappears.
They ride only on a poll whose own power read succeeded.

A host that ignores the returned interval polls every five seconds; then every
poll is a full read, exactly as before.
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

# What the live view and Core's control need on every poll.
FAST_READS = {
    "input:13000", "input:13019", "holding:13049",
    "input:5016", "input:5010",
    "input:5600", "input:5602", "input:5740", "input:5743",
}

# Read on a full poll as well.
SLOW_READS = {
    "input:12999", "input:13002", "input:5000", "input:5007", "input:5241",
    "input:13049", "input:13040", "input:13026", "input:13036", "input:13045",
}

HEALTHY_HYBRID = '''
host._modbus_registers.input[4990]  = {0x4131, 0x4232, 0x4333, 0x4434, 0x4535,
                                       0x4636, 0x4737, 0x4838, 0x4939, 0x4A30}
host._modbus_registers.input[4999]  = {0x0E0E}
host._modbus_registers.input[5000]  = {100}
host._modbus_registers.input[5007]  = {412}
host._modbus_registers.input[5016]  = {4000, 0}
host._modbus_registers.input[5241]  = {4998}
host._modbus_registers.input[12999] = {0x0000}
host._modbus_registers.input[13000] = {0x0004}   -- bit 2 set: discharging
host._modbus_registers.input[13002] = {5000, 0}
host._modbus_registers.input[13019] = {4800, 120, 900, 550}
host._modbus_registers.input[13026] = {1000, 0}
host._modbus_registers.input[13036] = {2000, 0}
host._modbus_registers.input[13040] = {3000, 0}
host._modbus_registers.input[13045] = {4000, 0}
host._modbus_registers.input[5600]  = {1500, 0}
host._modbus_registers.input[5743]  = {210, 62, 34}
'''

# Polls n_polls times, `step_ms` apart on the host clock, and prints what each
# poll read, returned and emitted.
POLL_REPORT = '''
dofile("{driver}")
driver_init({{}})
for poll = 1, {n_polls} do
    host._millis_counter = host._millis_counter + {step_ms} - host._millis_step
    {before_poll}
    local before = #host._calls
    local m_before = #(host._emitted["meter"] or {{}})
    local b_before = #(host._emitted["battery"] or {{}})
    local p_before = #(host._emitted["pv"] or {{}})
    local ok, ret = pcall(driver_poll)
    if not ok then print("POLL_ERROR " .. tostring(ret)) os.exit(1) end
    local reads = {{}}
    for i = before + 1, #host._calls do
        local call = host._calls[i]
        if call.func == "modbus_read" then
            reads[#reads + 1] = call.args[3] .. ":" .. tostring(call.args[1])
        end
    end
    table.sort(reads)
    print("READS" .. poll .. " " .. table.concat(reads, ","))
    print("RETURN" .. poll .. " " .. tostring(ret))
    local m = (host._emitted["meter"] or {{}})[m_before + 1] or {{}}
    local b = (host._emitted["battery"] or {{}})[b_before + 1] or {{}}
    local p = (host._emitted["pv"] or {{}})[p_before + 1] or {{}}
    print("METER" .. poll .. " " .. tostring(m.w) .. " " .. tostring(m.import_wh)
        .. " " .. tostring(m.export_wh) .. " " .. tostring(m.hz)
        .. " " .. tostring(m.l1_a))
    print("BATTERY" .. poll .. " " .. tostring(b.w) .. " " .. tostring(b.soc)
        .. " " .. tostring(b.charge_wh) .. " " .. tostring(b.discharge_wh))
    print("PV" .. poll .. " " .. tostring(p.w) .. " " .. tostring(p.lifetime_wh)
        .. " " .. tostring(p.temp_c) .. " " .. tostring(p.rated_w))
end
'''


def run_polls(n_polls: int, step_ms: int, setup: str = "", before_poll: str = "") -> dict[str, str]:
    script = f'''
package.path = "{HARNESS}/?.lua;" .. package.path
require("host_mock")
host.reset()
{HEALTHY_HYBRID}
{setup}
''' + POLL_REPORT.format(driver=DRIVER, n_polls=n_polls, step_ms=step_ms,
                         before_poll=before_poll)
    result = subprocess.run([str(LUA), "-e", script],
                            capture_output=True, text=True, cwd=ROOT)
    assert result.returncode == 0, result.stdout + result.stderr
    return dict(line.split(" ", 1)
                for line in result.stdout.strip().splitlines() if " " in line)


def reads(out: dict[str, str], poll: int) -> set[str]:
    return set(out[f"READS{poll}"].split(","))


def test_driver_asks_for_one_second() -> None:
    out = run_polls(2, 1000)
    assert out["RETURN1"] == "1000"
    assert out["RETURN2"] == "1000"


def test_reads_split_into_every_second_and_every_five() -> None:
    # Polls at 1, 2, ... 11 s. The first is full; then one full read about
    # every five seconds, never more than one apart from the next.
    out = run_polls(11, 1000)
    full = [poll for poll in range(1, 12) if SLOW_READS <= reads(out, poll)]
    assert full == [1, 6, 11], f"full reads on polls {full}"
    for poll in range(2, 6):
        assert reads(out, poll) == FAST_READS, (
            f"poll {poll} read {sorted(reads(out, poll))}, not just what the "
            f"live view needs")


def test_a_five_second_host_reads_everything_every_poll() -> None:
    """Core before srcfl/ftw honoured driver_poll's return polls every 5 s."""
    out = run_polls(4, 5000)
    for poll in range(1, 5):
        assert SLOW_READS | FAST_READS <= reads(out, poll), (
            f"poll {poll} at five seconds skipped {sorted(SLOW_READS - reads(out, poll))}")


def test_fast_polls_carry_the_last_full_values() -> None:
    """A counter that comes and goes makes FTW's energy ledger re-baseline."""
    change_power = '''
if poll == 2 then
    host._modbus_registers.input[5600]  = {2500, 0}
    host._modbus_registers.input[13019] = {4800, 120, 1200, 551}
    host._modbus_registers.input[5016]  = {5000, 0}
    host._modbus_registers.input[13036] = {9999, 0}
    host._modbus_registers.input[13040] = {9999, 0}
    host._modbus_registers.input[13002] = {9999, 0}
end'''
    out = run_polls(2, 1000, before_poll=change_power)
    # Power and SoC move on the fast poll.
    assert out["METER2"].split()[0] == "2500"
    assert out["BATTERY2"].split()[:2] == ["-1200", "0.551"]
    assert out["PV2"].split()[0] == "-5000"
    # Counters, frequency, temperature and phase current stay as last read.
    assert out["METER2"].split()[1:] == out["METER1"].split()[1:], out
    assert out["BATTERY2"].split()[2:] == out["BATTERY1"].split()[2:], out
    assert out["PV2"].split()[1:] == out["PV1"].split()[1:], out


def test_carried_values_need_this_polls_power_read() -> None:
    """If the meter stops answering, its counters stop too."""
    drop_meter = '''
if poll == 2 then
    host._modbus_read_fail_addresses[5600] = "Illegal Data Address"
end'''
    out = run_polls(2, 1000, before_poll=drop_meter)
    meter = out["METER2"].split()
    assert meter[1:3] == ["nil", "nil"], f"meter counters outlived the meter: {meter}"


def test_reconnect_backoff_does_not_count_as_a_missing_register() -> None:
    """FTW refuses a read without sending it while it waits to reconnect.

    A two-second wait spans two polls at one per second. Counted as misses,
    one dropped packet would mark the meter absent for the rest of the session.
    """
    backoff = '''
if poll >= 2 and poll <= 5 then
    host._modbus_read_fail_addresses[5600] = "modbus reconnect backoff active for 2s"
else
    host._modbus_read_fail_addresses[5600] = nil
end'''
    out = run_polls(6, 1000, before_poll=backoff)
    assert "input:5600" in reads(out, 6), "the meter was given up after a reconnect wait"
    assert out["METER6"].split()[0] == "1500"


def test_a_refused_register_is_still_given_up() -> None:
    refused = 'host._modbus_read_fail_addresses[5743] = "Illegal Data Address"'
    out = run_polls(5, 1000, setup=refused)
    assert "input:5743" in reads(out, 3)
    assert "input:5743" not in reads(out, 4), "a refused register was read forever"
