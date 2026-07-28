"""A register the firmware does not carry must be probed once, not every poll.

The host counts every failed `host.modbus_read` toward the driver-poll error
tally, whether or not Lua caught the error with pcall. So a driver that keeps
re-reading an absent optional register sits at "1 of N reads failed" forever,
the stale-telemetry watchdog marks it offline, and telemetry stops reaching
the planner. Both cases below were found on customer hardware.

The Lua harness in lua_harness/ covers the same ground, but CI only runs
pytest, so the guard has to live here to hold.
"""

import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"
HARNESS = ROOT / "drivers" / "tests" / "lua_harness"

POLLS = 3

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")


def run_lua(body: str) -> dict[str, str]:
    script = f'''
package.path = "{HARNESS}/?.lua;" .. package.path
require("host_mock")
host.reset()

-- Fill every register with a plausible value so an unpatched read succeeds.
local holding = {{}}
for addr = 0, 65535 do holding[addr] = 100 end
host._modbus_registers.holding = holding
host._modbus_registers.input = holding

function count_reads(addr)
    local n = 0
    for _, call in ipairs(host._calls) do
        if call.func == "modbus_read" and call.args[1] == addr then n = n + 1 end
    end
    return n
end

{body}
'''
    result = subprocess.run([str(LUA), "-e", script],
                            capture_output=True, text=True, cwd=ROOT)
    assert result.returncode == 0, result.stdout + result.stderr
    return dict(line.split(" ", 1)
                for line in result.stdout.strip().splitlines() if " " in line)


def poll_with_absent(driver: str, absent: int, present: int,
                     config: str = "{}") -> dict[str, str]:
    return run_lua(f'''
host._modbus_read_fail_addresses[{absent}] = "Illegal Data Address"
dofile("{ROOT}/drivers/lua/{driver}.lua")
driver_init({config})
for poll = 1, {POLLS} do
    local ok, err = pcall(driver_poll)
    if not ok then print("POLL_ERROR " .. tostring(err)) os.exit(1) end
end
print("ABSENT_READS " .. count_reads({absent}))
print("PRESENT_READS " .. count_reads({present}))
local streams = 0
for _, kind in ipairs({{"pv", "battery", "meter"}}) do
    local emitted = host._emitted[kind]
    if emitted and #emitted > 0 then streams = streams + 1 end
end
print("STREAMS " .. streams)
''')


def test_pixii_probes_absent_scale_factor_once():
    """40288 meter_energy_sf is absent on PowerShaper firmware below CPU 2.0.23."""
    out = poll_with_absent("pixii", absent=40288, present=40256,
                           config="{host = '127.0.0.1', port = 502, unit_id = 1}")

    assert int(out["ABSENT_READS"]) <= 1, (
        f"pixii read absent 40288 {out['ABSENT_READS']} times over {POLLS} polls; "
        "every failed read counts against the poll and takes the driver offline"
    )
    # Caching absence must not freeze a scale factor the firmware does carry.
    assert int(out["PRESENT_READS"]) >= POLLS, (
        "pixii stopped re-reading meter power SF 40256, which is present"
    )
    assert int(out["STREAMS"]) >= 2, "pixii stopped telemetry when 40288 is absent"


def test_solaredge_legacy_probes_absent_mppt_block_once():
    """K-series firmware does not populate the proprietary MPPT block at 40123."""
    out = run_lua(f'''
-- The driver refuses a device that does not answer the SunSpec magic.
host._modbus_registers.holding[40000] = 0x5375
host._modbus_registers.holding[40001] = 0x6e53
host._modbus_read_fail_addresses[40123] = "Illegal Data Address"
dofile("{ROOT}/drivers/lua/solaredge_legacy.lua")
driver_init({{host = '127.0.0.1', port = 502, unit_id = 1, nominal_w = 17000}})
for poll = 1, {POLLS} do
    local ok, err = pcall(driver_poll)
    if not ok then print("POLL_ERROR " .. tostring(err)) os.exit(1) end
end
print("ABSENT_READS " .. count_reads(40123))
print("PRESENT_READS " .. count_reads(40069))
print("PV " .. ((host._emitted.pv and #host._emitted.pv) or 0))
''')

    assert int(out["ABSENT_READS"]) <= 1, (
        f"solaredge_legacy read absent 40123 {out['ABSENT_READS']} times over "
        f"{POLLS} polls; every failed read counts against the poll"
    )
    # Model 103 carries AC power and must keep flowing.
    assert int(out["PRESENT_READS"]) >= POLLS, (
        "solaredge_legacy stopped reading the Model 103 block"
    )
    assert int(out["PV"]) >= POLLS, (
        "solaredge_legacy stopped PV telemetry when the MPPT block is absent"
    )
