"""Growatt: a read that failed is left out, never sent as 0.

docs/WRITING-A-DRIVER.md, "Never fabricate": a field that did not answer is
left out, and a stream whose defining reading did not answer is not emitted.
Up to 2.2.1 this driver started every PV, battery and meter value at 0, so a
failed read became 0 W, 0 V or 0 % SoC. A 0 W meter looks like a site in
balance; a 0 % SoC like an empty pack.

The battery follows "A hybrid inverter may have no battery": each field
comes only from a read that answered, and the stream goes out when what
answered shows a battery. Its power needs both 1009 (discharge) and 1011
(charge).

This is the never-fabricate half of srcfl/device-drivers#263. Which
registers the meter should read is srcfl/device-drivers#271; the addresses
here are the driver's current ones. The values are synthetic, not a capture.
"""

import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"
HARNESS = ROOT / "drivers" / "tests" / "lua_harness"
DRIVER = ROOT / "drivers" / "lua" / "growatt.lua"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")

REGISTERS = {
    1: [0, 41000],        # PV power 4100 W
    3: [3500, 62],        # MPPT1 350.0 V, 6.2 A
    7: [3400, 55],        # MPPT2 340.0 V, 5.5 A
    37: [5001],           # 50.01 Hz
    38: [2310], 39: [52],  # L1 231.0 V, 5.2 A
    42: [2290], 43: [41],  # L2 229.0 V, 4.1 A
    46: [2300], 47: [33],  # L3 230.0 V, 3.3 A
    91: [0, 123456],      # PV lifetime 12345.6 kWh
    93: [387],            # inverter 38.7 C
    1009: [0, 0],         # Pdischarge1 0 W
    1011: [0, 15000],     # Pcharge1 1500 W
    1013: [520],          # 52.0 V
    1014: [64],           # 64 %
    1015: [0, 4500],      # meter 450 W import
    1021: [0, 51000],     # import counter
    1029: [0, 22000],     # export counter
    1040: [212],          # battery 21.2 C
    1114: [230, 198],     # cells 23.0 / 19.8 C
}

STREAMS = {
    "pv": ["w", "mppt1_v", "mppt1_a", "mppt2_v", "mppt2_a", "lifetime_wh"],
    "battery": ["w", "v", "soc", "temp_c"],
    "meter": ["w", "l1_v", "l2_v", "l3_v", "l1_a", "l2_a", "l3_a", "hz",
              "import_wh", "export_wh"],
}
METRICS = ["pv_mppt1_v", "pv_mppt2_v", "pv_mppt2_a", "grid_hz", "battery_dc_v",
           "meter_l1_v", "meter_l2_v", "meter_l2_a", "meter_l3_a"]


def _lua_list(values) -> str:
    return "{" + ", ".join(str(v) for v in values) + "}"


def poll(fail: tuple[int, ...] = (), regs: dict | None = None) -> dict[str, str]:
    regs = REGISTERS if regs is None else regs
    setup = "\n".join(
        f"host._modbus_registers.input[{addr}] = {_lua_list(vals)}"
        for addr, vals in regs.items())
    setup += "\n" + "\n".join(
        f'host._modbus_read_fail_addresses[{addr}] = "Illegal Data Address"'
        for addr in fail)
    body = ""
    for stream, fields in STREAMS.items():
        body += "do\n" + (
            f'local s = host._emitted.{stream} and host._emitted.{stream}[1]\n'
            f'print("{stream} " .. tostring(s ~= nil))\n')
        for field in fields:
            body += f'print("{stream}.{field} " .. tostring(s and s.{field}))\n'
        body += "end\n"
    for name in METRICS:
        body += (f'do local m = host._metrics["{name}"] '
                 f'print("metric.{name} " .. tostring(m and m.value)) end\n')
    script = f'''
package.path = "{HARNESS}/?.lua;" .. package.path
require("host_mock")
host.reset()
{setup}
dofile("{DRIVER}")
driver_init({{}})
local ok, err = pcall(driver_poll)
if not ok then print("POLL_ERROR " .. tostring(err)) os.exit(1) end
{body}
'''
    result = subprocess.run([str(LUA), "-e", script],
                            capture_output=True, text=True, cwd=ROOT)
    assert result.returncode == 0, result.stdout + result.stderr
    return dict(line.split(" ", 1)
                for line in result.stdout.strip().splitlines() if " " in line)


def num(out: dict[str, str], key: str) -> float:
    assert out[key] != "nil", f"{key} left out"
    return float(out[key])


def test_growatt_all_answer():
    out = poll()
    assert num(out, "pv.w") == pytest.approx(-4100)
    assert num(out, "pv.mppt2_a") == pytest.approx(5.5)
    assert num(out, "battery.w") == pytest.approx(1500)
    assert num(out, "battery.soc") == pytest.approx(0.64)
    assert num(out, "meter.w") == pytest.approx(450)
    assert num(out, "meter.hz") == pytest.approx(50.01)
    assert num(out, "metric.meter_l2_v") == pytest.approx(229)


def test_growatt_no_pv_reading_without_pv_power():
    out = poll(fail=(1,))
    assert out["pv"] == "false"
    assert out["meter"] == "true"


def test_growatt_failed_mppt_read_is_left_out():
    out = poll(fail=(7,))
    assert num(out, "pv.w") == pytest.approx(-4100)
    assert num(out, "pv.mppt1_v") == pytest.approx(350)
    assert out["pv.mppt2_v"] == "nil"
    assert out["pv.mppt2_a"] == "nil"
    assert out["metric.pv_mppt2_v"] == "nil"
    assert out["metric.pv_mppt2_a"] == "nil"


def test_growatt_failed_lifetime_read_is_left_out():
    out = poll(fail=(91,))
    assert num(out, "pv.w") == pytest.approx(-4100)
    assert out["pv.lifetime_wh"] == "nil"


def test_growatt_no_meter_reading_without_meter_power():
    # 0 W from a failed read looks like a site in balance.
    out = poll(fail=(1015,))
    assert out["meter"] == "false"
    assert out["pv"] == "true"


def test_growatt_failed_phase_and_frequency_reads_are_left_out():
    out = poll(fail=(42, 43, 37))
    assert num(out, "meter.w") == pytest.approx(450)
    assert num(out, "meter.l1_v") == pytest.approx(231)
    assert out["meter.l2_v"] == "nil"
    assert out["meter.l2_a"] == "nil"
    assert out["meter.hz"] == "nil"
    assert out["metric.meter_l2_v"] == "nil"
    assert out["metric.meter_l2_a"] == "nil"
    assert out["metric.grid_hz"] == "nil"
    assert num(out, "metric.meter_l3_a") == pytest.approx(3.3)


def test_growatt_failed_energy_counters_are_left_out():
    out = poll(fail=(1021, 1029))
    assert out["meter.import_wh"] == "nil"
    assert out["meter.export_wh"] == "nil"


def test_growatt_failed_soc_read_is_left_out():
    # 0 % SoC from a failed read looks like an empty pack.
    out = poll(fail=(1014,))
    assert out["battery"] == "true"
    assert out["battery.soc"] == "nil"
    assert num(out, "battery.v") == pytest.approx(52.0)


def test_growatt_failed_voltage_read_is_left_out():
    out = poll(fail=(1013,))
    assert out["battery"] == "true"
    assert out["battery.v"] == "nil"
    assert out["metric.battery_dc_v"] == "nil"
    assert num(out, "battery.soc") == pytest.approx(0.64)


def test_growatt_battery_power_needs_both_registers():
    # Charge alone is not the net power: discharge did not answer.
    out = poll(fail=(1009,))
    assert out["battery"] == "true"
    assert out["battery.w"] == "nil"
    out = poll(fail=(1011,))
    assert out["battery.w"] == "nil"


def test_growatt_nothing_answers_sends_nothing():
    out = poll(fail=tuple(REGISTERS))
    assert out["pv"] == "false"
    assert out["battery"] == "false"
    assert out["meter"] == "false"
    for name in METRICS:
        assert out[f"metric.{name}"] == "nil", name
