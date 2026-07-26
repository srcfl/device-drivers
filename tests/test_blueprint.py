"""The blueprint has to be a working driver, not a plausible-looking one.

blueprint/BLUEPRINT.lua is what a person or an agent copies to start a new
driver. A blueprint that compiles but would fail on hardware teaches the
mistake it demonstrates. So it is held to every rule a shipped driver is held
to, and run against the harness like one.
"""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
BLUEPRINT = ROOT / "blueprint" / "BLUEPRINT.lua"
LUA = ROOT / "lua55"
LUAC = ROOT / "luac55"


def test_blueprint_exists() -> None:
    assert BLUEPRINT.exists(), (
        "blueprint/BLUEPRINT.lua is the entry point for anyone writing a "
        "driver; it must not disappear.")


@pytest.mark.skipif(not LUAC.exists(), reason="run make check to build ./luac55")
def test_blueprint_compiles() -> None:
    result = subprocess.run([str(LUAC), "-p", str(BLUEPRINT)],
                            capture_output=True, text=True)
    assert result.returncode == 0, result.stderr


def test_blueprint_passes_the_sandbox() -> None:
    result = subprocess.run(
        ["bash", str(ROOT / "tools" / "check_sandbox.sh"), str(BLUEPRINT)],
        capture_output=True, text=True, cwd=ROOT)
    assert result.returncode == 0, result.stdout + result.stderr


def test_blueprint_calls_only_functions_a_host_provides() -> None:
    """The same rule tools/host_api_check.py applies to every shipped driver."""
    profile = json.loads(
        (ROOT / "spec" / "host-api-profile.json").read_text(encoding="utf-8"))
    allowed: set[str] = set()
    for entry in profile["profiles"].values():
        for group in entry["functions"].values():
            allowed.update(group)
    dialect = profile["deprecated"]["ftw_to_blixt"]
    allowed.update(dialect)
    allowed.update(dialect.values())

    called = set(re.findall(r"\bhost\.(\w+)\s*\(",
                            BLUEPRINT.read_text(encoding="utf-8")))
    unknown = called - allowed
    assert not unknown, (
        f"the blueprint calls {sorted(unknown)}, which no host provides. It is "
        f"the file people copy, so it must not demonstrate a call that fails.")


@pytest.mark.skipif(not LUA.exists(), reason="run make check to build ./lua55")
def test_blueprint_polls_a_device_and_emits_what_it_read() -> None:
    """Run it against the harness: a device with PV and a meter, no battery."""
    script = f'''
package.path = "{ROOT}/drivers/tests/lua_harness/?.lua;" .. package.path
require("host_mock")
host.reset()

-- A string inverter: answers the device type as a non-hybrid family, has PV
-- and a meter, and does not answer the battery block at all.
host._modbus_registers.input[4999] = {{0x2434}}
host._modbus_registers.input[5016] = {{3000, 0}}  -- LE: low word first
host._modbus_registers.input[5600] = {{1500, 0}}  -- LE: low word first
for _, addr in ipairs({{13020, 13022}}) do
    host._modbus_read_fail_addresses[addr] = "Illegal Data Address"
end

dofile("{BLUEPRINT}")
driver_init({{}})

local failed_reads = {{}}
for poll = 1, 6 do
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
    failed_reads[#failed_reads + 1] = failed
end

local pv = host._emitted["pv"]
local meter = host._emitted["meter"]
print("PV_COUNT " .. tostring(pv and #pv or 0))
print("PV_W " .. tostring(pv and pv[1] and pv[1].w))
print("METER_W " .. tostring(meter and meter[1] and meter[1].w))
print("BATTERY_COUNT " .. tostring(host._emitted["battery"] and #host._emitted["battery"] or 0))
print("FAILED_PER_POLL " .. table.concat(failed_reads, ","))
'''
    result = subprocess.run([str(LUA), "-e", script],
                            capture_output=True, text=True, cwd=ROOT)
    assert result.returncode == 0, result.stdout + result.stderr
    out = dict(line.split(" ", 1) for line in result.stdout.strip().splitlines()
               if " " in line)

    assert int(out["PV_COUNT"]) == 6, "every poll should emit PV"
    # Generation is negative: it reduces what the site imports.
    assert float(out["PV_W"]) == -3000.0, out
    # This device already reports import positive, so it passes through.
    assert float(out["METER_W"]) == 1500.0, out
    # No battery answered, so no battery stream. Not a zeroed one.
    assert int(out["BATTERY_COUNT"]) == 0, (
        "a battery that did not answer must not be emitted as zero")


@pytest.mark.skipif(not LUA.exists(), reason="run make check to build ./lua55")
def test_blueprint_stops_reading_registers_that_never_answer() -> None:
    """The outage this repository exists to prevent, demonstrated.

    A device without a battery must stop costing failed reads. If the count
    does not fall to zero, every poll fails and the site reports nothing.
    """
    script = f'''
package.path = "{ROOT}/drivers/tests/lua_harness/?.lua;" .. package.path
require("host_mock")
host.reset()
host._modbus_registers.input[5016] = {{3000, 0}}  -- LE: low word first
-- Nothing else answers: no device type, no serial, no battery.
for _, addr in ipairs({{4989, 4999, 5600, 13020, 13022}}) do
    host._modbus_read_fail_addresses[addr] = "Illegal Data Address"
end

dofile("{BLUEPRINT}")
driver_init({{}})

local counts = {{}}
for poll = 1, 10 do
    local before = #host._calls
    pcall(driver_poll)
    local failed = 0
    for i = before + 1, #host._calls do
        local call = host._calls[i]
        if call.func == "modbus_read"
           and host._modbus_read_fail_addresses[call.args[1]] then
            failed = failed + 1
        end
    end
    counts[#counts + 1] = failed
end
print("COUNTS " .. table.concat(counts, ","))
'''
    result = subprocess.run([str(LUA), "-e", script],
                            capture_output=True, text=True, cwd=ROOT)
    assert result.returncode == 0, result.stdout + result.stderr

    counts = [int(n) for n in
              result.stdout.strip().split("COUNTS ")[1].split(",")]
    assert counts[-1] == 0, (
        f"failed reads per poll settled at {counts[-1]}, not 0: {counts}. "
        f"A register that never answers must be given up on, or the host "
        f"fails every poll and the site goes offline.")
    assert counts[-3:] == [0, 0, 0], f"should stay settled: {counts}"
