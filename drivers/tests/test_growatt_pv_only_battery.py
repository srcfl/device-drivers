"""A PV-only Growatt must not emit a phantom Battery stream.

A Growatt with no battery connected still answers the battery Modbus
registers with 0. The driver used to emit a `battery` stream on every poll
regardless, which made FTW render a "Battery Growatt" node on Overview even
though no battery exists (srcfl/ftw#1669). The driver now only emits battery
telemetry when a battery is actually present.

CI builds ./lua55 (see tools/build_luac.sh) and runs this through the host
mock, so the guard holds in the pipeline. pytest skips it locally when the
interpreter is absent.
"""

import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"
HARNESS = ROOT / "drivers" / "tests" / "lua_harness"
GROWATT = ROOT / "drivers" / "lua" / "growatt.lua"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")


def _run(body: str) -> dict[str, str]:
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


def _poll(registers: dict[str, int]) -> dict[str, str]:
    setup = "\n".join(
        f"host._modbus_registers.input[{addr}] = {val}"
        for addr, val in registers.items()
    )
    return _run(f'''
{setup}
dofile("{GROWATT}")
driver_init({{host = '127.0.0.1', port = 502, unit_id = 1}})
local ok, err = pcall(driver_poll)
if not ok then print("POLL_ERROR " .. tostring(err)) os.exit(1) end
local bat = host._emitted.battery
if bat and #bat > 0 then
    print("BATTERY_EMITTED 1")
    print("BAT_V " .. tostring(bat[1].v))
    print("BAT_SOC " .. tostring(bat[1].soc))
    print("BAT_W " .. tostring(bat[1].w))
else
    print("BATTERY_EMITTED 0")
end
''')


def test_pv_only_install_emits_no_battery_node():
    """A Growatt answering all-zero battery registers must not emit battery."""
    out = _poll({})  # every register unmapped -> the mock returns 0
    assert out["BATTERY_EMITTED"] == "0", (
        "PV-only Growatt emitted a battery stream; Overview would show a "
        "phantom Battery node (srcfl/ftw#1669)."
    )


def test_hybrid_install_with_battery_emits_battery():
    """A real battery (voltage + SoC + charge power) must still be reported."""
    out = _poll({
        1009: 0, 1010: 100,   # charge power 10 W
        1011: 0, 1012: 0,     # discharge power 0 W
        1013: 480,            # terminal voltage 48.0 V
        1014: 50,             # SoC 50 %
    })
    assert out["BATTERY_EMITTED"] == "1", (
        "Hybrid Growatt with a battery present did not emit battery telemetry."
    )
    assert float(out["BAT_V"]) == 48.0
    assert float(out["BAT_SOC"]) == 0.5
    assert float(out["BAT_W"]) == 10.0  # charge - discharge


def test_battery_at_rest_with_zero_soc_still_emits():
    """A present battery reads a terminal voltage even at 0 % SoC.

    Guards against an over-strict gate that would drop a real battery just
    because its SoC register reads 0.
    """
    out = _poll({
        1009: 0, 1010: 0,
        1011: 0, 1012: 0,
        1013: 520,            # 52.0 V present
        1014: 0,             # SoC 0 %
    })
    assert out["BATTERY_EMITTED"] == "1", (
        "A battery at 0 % SoC but with terminal voltage was dropped; the gate "
        "must key off voltage/power, not SoC alone."
    )
    assert float(out["BAT_V"]) == 52.0
