"""Sungrow reports what its battery can do now, and only what the device said.

FTW Core marks a battery "not following" when it gives less than it was told.
On one SH-RT with an SBR096 pack, 30 days showed the short orders were device
limits, not lost control: forced discharge held flat at 21.6-23.1 A DC, and
14 times the running state went to standby (8) and then startup (32) for 2-9
minutes while an order stood, with the battery at 0 W.

The driver now reads, on full polls only (Sungrow's "Communication Protocol of
Residential Hybrid Inverter" V1.1.9, documented number / host address):

- 13025 / 13024 battery temperature, S16 x 0.1 C -> temperature_C
- 5635 / 5634 and 5636 / 5635, the BMS's max charge and discharge current in
  A, times this poll's battery voltage -> available_charge_W and
  available_discharge_W
- the running state it already read, 13000 / 12999 -> device_state
  "standby" or "starting" while the inverter says it is not running

The running-state codes come from Appendix 2 of that protocol, and the
owner's box confirms the low ones: in all 14 standby episodes the state went
0x0800 (forced mode) -> 0x0008 -> 0x0020 -> 0x0800, and 0x0010 showed in 3 of
them.

Between full polls the battery blob carries them like the other slow values,
and only while its own power read succeeds. A read that fails leaves the
field out until the next full poll that reads it.
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

# 208.0 V pack, 12.0 A, 900 W discharging, 55 % SoC. BMS allows 24 A charge
# and 22 A discharge; the pack reads 25.3 C.
HEALTHY_HYBRID = '''
host._modbus_registers.input[4999]  = {0x0E0E}
host._modbus_registers.input[5000]  = {80}
host._modbus_registers.input[5016]  = {4000, 0}
host._modbus_registers.input[12999] = {0x0040}   -- running
host._modbus_registers.input[13000] = {0x0004}   -- bit 2 set: discharging
host._modbus_registers.input[13002] = {5000, 0}
host._modbus_registers.input[13019] = {2080, 120, 900, 550}
host._modbus_registers.input[13024] = {253}
host._modbus_registers.input[5634]  = {24, 22}
host._modbus_registers.input[13026] = {1000, 0}
host._modbus_registers.input[13036] = {2000, 0}
host._modbus_registers.input[13040] = {3000, 0}
host._modbus_registers.input[13045] = {4000, 0}
host._modbus_registers.input[5600]  = {1500, 0}
'''

METRICS = [
    "battery_temp_c", "battery_charge_limit_a", "battery_discharge_limit_a",
    "battery_available_charge_w", "battery_available_discharge_w",
]

# Polls n_polls times, one second apart on the host clock, so polls 1, 6 and
# 11 are full. Prints each poll's reads, its battery blob and the metrics it
# emitted, "nil" for a missing value.
POLL_REPORT = '''
local function show(v)
    if v == nil then return "nil" end
    if type(v) == "number" then return string.format("%.1f", v) end
    return tostring(v)
end
dofile("{driver}")
driver_init({{}})
for poll = 1, {n_polls} do
    host._millis_counter = host._millis_counter + 1000 - host._millis_step
    {before_poll}
    local before = #host._calls
    local b_before = #(host._emitted["battery"] or {{}})
    local ok, err = pcall(driver_poll)
    if not ok then print("POLL_ERROR " .. tostring(err)) os.exit(1) end
    local reads, metrics = {{}}, {{}}
    for i = before + 1, #host._calls do
        local call = host._calls[i]
        if call.func == "modbus_read" then
            reads[#reads + 1] = call.args[3] .. ":" .. tostring(call.args[1])
        elseif call.func == "emit_metric" then
            metrics[call.args[1]] = call.args[2]
        end
    end
    print("READS" .. poll .. " " .. table.concat(reads, ","))
    local b = (host._emitted["battery"] or {{}})[b_before + 1]
    if b then
        print("BATTERY" .. poll .. " " .. show(b.w) .. " " .. show(b.temperature_C)
            .. " " .. show(b.available_charge_W) .. " " .. show(b.available_discharge_W)
            .. " " .. show(b.device_state))
    else
        print("BATTERY" .. poll .. " none")
    end
    local m = {{}}
    for _, name in ipairs({{{metric_names}}}) do m[#m + 1] = show(metrics[name]) end
    print("METRICS" .. poll .. " " .. table.concat(m, " "))
end
'''


def run_polls(n_polls: int, setup: str = "", before_poll: str = "") -> dict[str, str]:
    names = ", ".join(f'"{name}"' for name in METRICS)
    script = f'''
package.path = "{HARNESS}/?.lua;" .. package.path
require("host_mock")
host.reset()
{HEALTHY_HYBRID}
{setup}
''' + POLL_REPORT.format(driver=DRIVER, n_polls=n_polls,
                         before_poll=before_poll, metric_names=names)
    result = subprocess.run([str(LUA), "-e", script],
                            capture_output=True, text=True, cwd=ROOT)
    assert result.returncode == 0, result.stdout + result.stderr
    return dict(line.split(" ", 1)
                for line in result.stdout.strip().splitlines() if " " in line)


def battery(out: dict[str, str], poll: int) -> dict[str, str]:
    fields = out[f"BATTERY{poll}"].split()
    assert fields != ["none"], f"no battery blob on poll {poll}"
    return dict(zip(["w", "temp", "charge_w", "discharge_w", "state"], fields))


def metrics(out: dict[str, str], poll: int) -> dict[str, str]:
    return dict(zip(METRICS, out[f"METRICS{poll}"].split()))


def reads(out: dict[str, str], poll: int) -> set[str]:
    return set(out[f"READS{poll}"].split(","))


def test_fields_carry_the_right_scale_and_sign() -> None:
    out = run_polls(1)
    b = battery(out, 1)
    assert b["temp"] == "25.3"
    # 24 A and 22 A at 208.0 V, as positive watts whichever way the pack runs.
    assert b["charge_w"] == "4992.0"
    assert b["discharge_w"] == "4576.0"
    assert b["w"] == "-900.0"
    assert b["state"] == "nil", "a running inverter claimed a device_state"
    assert metrics(out, 1) == {
        "battery_temp_c": "25.3",
        "battery_charge_limit_a": "24.0",
        "battery_discharge_limit_a": "22.0",
        "battery_available_charge_w": "4992.0",
        "battery_available_discharge_w": "4576.0",
    }


def test_a_cold_pack_reads_below_zero() -> None:
    out = run_polls(1, setup="host._modbus_registers.input[13024] = {0xFFCE}")  # -5.0
    assert battery(out, 1)["temp"] == "-5.0"


def test_zero_amps_means_not_allowed_now() -> None:
    """0 W is what the BMS said, not a failed read, so it is sent."""
    out = run_polls(1, setup="host._modbus_registers.input[5634] = {0, 22}")
    b = battery(out, 1)
    assert b["charge_w"] == "0.0"
    assert b["discharge_w"] == "4576.0"


@pytest.mark.parametrize("address", [13024, 5634])
@pytest.mark.parametrize("error", [
    "modbus exception function=0x04 code=0x02",
    "modbus transport failure: i/o timeout",
])
def test_a_failed_read_leaves_its_fields_out(address: int, error: str) -> None:
    out = run_polls(1, setup=f'host._modbus_read_fail_addresses[{address}] = "{error}"')
    b, m = battery(out, 1), metrics(out, 1)
    assert b["w"] == "-900.0", "the battery itself must still report"
    if address == 13024:
        assert b["temp"] == "nil" and m["battery_temp_c"] == "nil"
        assert b["charge_w"] == "4992.0"
    else:
        assert b["charge_w"] == "nil" and b["discharge_w"] == "nil"
        assert m["battery_charge_limit_a"] == "nil"
        assert m["battery_discharge_limit_a"] == "nil"
        assert m["battery_available_charge_w"] == "nil"
        assert m["battery_available_discharge_w"] == "nil"
        assert b["temp"] == "25.3"


@pytest.mark.parametrize("raw", [0x7FFF, 1010, 0xFE66])  # not there, 101.0, -41.0
def test_a_temperature_out_of_range_is_dropped(raw: int) -> None:
    out = run_polls(1, setup=f"host._modbus_registers.input[13024] = {{{raw}}}")
    assert battery(out, 1)["temp"] == "nil"
    assert metrics(out, 1)["battery_temp_c"] == "nil"


@pytest.mark.parametrize("raw, expected", [
    (0xFE70, "-40.0"),   # -400 tenths: the edge is kept
    (1000, "100.0"),
    (0xFE6F, "nil"),     # -401 tenths: just outside
    (1001, "nil"),
])
def test_the_temperature_range_keeps_its_edges(raw: int, expected: str) -> None:
    out = run_polls(1, setup=f"host._modbus_registers.input[13024] = {{{raw}}}")
    assert battery(out, 1)["temp"] == expected
    assert metrics(out, 1)["battery_temp_c"] == expected


def test_the_not_available_value_is_dropped_for_amps() -> None:
    out = run_polls(1, setup="host._modbus_registers.input[5634] = {0xFFFF, 0xFFFF}")
    b, m = battery(out, 1), metrics(out, 1)
    assert b["charge_w"] == "nil" and b["discharge_w"] == "nil"
    assert m["battery_charge_limit_a"] == "nil"
    assert m["battery_discharge_limit_a"] == "nil"


def test_watts_above_100_kw_are_dropped() -> None:
    # 600 A at 208 V is 124.8 kW: the amps may be real, the watts are not sent.
    out = run_polls(1, setup="host._modbus_registers.input[5634] = {600, 22}")
    b, m = battery(out, 1), metrics(out, 1)
    assert b["charge_w"] == "nil"
    assert m["battery_available_charge_w"] == "nil"
    assert m["battery_charge_limit_a"] == "600.0"
    assert b["discharge_w"] == "4576.0"


@pytest.mark.parametrize("raw_v", [0, 0xFFFF])
def test_no_watts_without_a_real_voltage(raw_v: int) -> None:
    out = run_polls(1, setup=f"host._modbus_registers.input[13019] = {{{raw_v}, 120, 900, 550}}")
    b, m = battery(out, 1), metrics(out, 1)
    assert b["charge_w"] == "nil" and b["discharge_w"] == "nil"
    assert m["battery_available_charge_w"] == "nil"
    assert m["battery_charge_limit_a"] == "24.0"


@pytest.mark.parametrize("state, expected", [
    (0x0008, "standby"), (0x1400, "standby"),
    (0x0010, "standby"), (0x1200, "standby"),
    (0x0020, "starting"), (0x1600, "starting"),
    (0x0000, "nil"), (0x0040, "nil"), (0x0800, "nil"), (0x4000, "nil"),
    # Whole values, not bits: running with a generator, off-grid charging.
    (0x0014, "nil"), (0x0041, "nil"),
])
def test_device_state_follows_the_running_state(state: int, expected: str) -> None:
    out = run_polls(1, setup=f"host._modbus_registers.input[12999] = {{{state:#06x}}}")
    assert battery(out, 1)["state"] == expected


@pytest.mark.parametrize("running", [0x0800, 0x0040])
def test_device_state_clears_when_the_inverter_runs_again(running: int) -> None:
    """The episode the owner's box showed 14 times, one state per full poll.

    Full polls are 1, 6, 11 and 16: forced mode, standby, startup, then
    running again. device_state must leave on the poll that reads running.
    """
    episode = f'''
local states = {{[1] = 0x0800, [6] = 0x0008, [11] = 0x0020, [16] = {running:#06x}}}
if states[poll] then host._modbus_registers.input[12999] = {{states[poll]}} end'''
    out = run_polls(20, before_poll=episode)
    expected = {1: "nil", 6: "standby", 11: "starting", 16: "nil"}
    for poll in range(1, 21):
        want = expected[max(p for p in expected if p <= poll)]
        assert battery(out, poll)["state"] == want, (poll, out[f"BATTERY{poll}"])


def test_no_device_state_when_the_running_state_does_not_answer() -> None:
    out = run_polls(1, setup='''
host._modbus_registers.input[12999] = {0x0008}
host._modbus_read_fail_addresses[12999] = "modbus exception function=0x04 code=0x02"''')
    assert battery(out, 1)["state"] == "nil"


def test_fast_polls_carry_the_full_poll_values() -> None:
    """Standby every poll, not one in five, while the inverter is in standby."""
    out = run_polls(5, setup="host._modbus_registers.input[12999] = {0x0008}")
    for poll in range(2, 6):
        assert {"input:13024", "input:5634", "input:12999"}.isdisjoint(reads(out, poll))
        b = battery(out, poll)
        assert (b["temp"], b["state"]) == ("25.3", "standby"), (poll, b)
        # Metrics keep the full-read rate.
        assert set(metrics(out, poll).values()) == {"nil"}


def test_carried_watts_use_this_polls_voltage() -> None:
    change_voltage = '''
if poll == 2 then
    host._modbus_registers.input[13019] = {2000, 120, 900, 550}
end'''
    out = run_polls(2, before_poll=change_voltage)
    assert battery(out, 2)["charge_w"] == "4800.0"   # 24 A at 200.0 V
    assert battery(out, 2)["discharge_w"] == "4400.0"


def test_a_failed_full_read_stops_the_carried_values() -> None:
    """Poll 6 is the next full poll. Its reads fail, so 6 to 10 carry nothing."""
    fail_at_six = '''
if poll == 6 then
    host._modbus_read_fail_addresses[13024] = "modbus transport failure: i/o timeout"
    host._modbus_read_fail_addresses[5634] = "modbus transport failure: i/o timeout"
    host._modbus_read_fail_addresses[12999] = "modbus transport failure: i/o timeout"
elseif poll == 7 then
    host._modbus_read_fail_addresses = {}
end'''
    out = run_polls(10, setup="host._modbus_registers.input[12999] = {0x0020}",
                    before_poll=fail_at_six)
    assert battery(out, 5)["state"] == "starting"
    assert battery(out, 5)["temp"] == "25.3"
    for poll in range(6, 11):
        b = battery(out, poll)
        assert (b["temp"], b["charge_w"], b["discharge_w"], b["state"]) == \
            ("nil", "nil", "nil", "nil"), (poll, b)


def test_a_failed_battery_read_on_a_full_poll_clears_them_too() -> None:
    fail_battery_at_six = '''
if poll == 6 then
    host._modbus_read_fail_addresses[13019] = "modbus transport failure: i/o timeout"
elseif poll == 7 then
    host._modbus_read_fail_addresses = {}
end'''
    out = run_polls(7, before_poll=fail_battery_at_six)
    assert out["BATTERY6"] == "none"
    b = battery(out, 7)
    assert b["w"] == "-900.0"
    assert (b["temp"], b["charge_w"], b["discharge_w"]) == ("nil", "nil", "nil")


def test_a_refused_register_is_given_up() -> None:
    """Three refusals and the full poll stops asking, as for every register."""
    refused = 'host._modbus_read_fail_addresses[5634] = "modbus exception function=0x04 code=0x02"'
    out = run_polls(21, setup=refused)
    full_polls = [1, 6, 11, 16, 21]
    asked = [poll for poll in full_polls if "input:5634" in reads(out, poll)]
    assert asked == [1, 6, 11], f"asked for a refused register on polls {asked}"
    assert battery(out, 21)["temp"] == "25.3"


def test_a_string_inverter_never_asks() -> None:
    out = run_polls(6, setup='''
host._modbus_registers.input[4999] = {0x0102}   -- an SG string inverter''')
    for poll in range(1, 7):
        assert {"input:13024", "input:5634"}.isdisjoint(reads(out, poll))
        assert out[f"BATTERY{poll}"] == "none"
