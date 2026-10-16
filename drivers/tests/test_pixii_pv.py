"""Pixii's PV feed stays valid when the measured total falls below zero."""

import json
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"
pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make test-driver ID=pixii_pv")


def run_lua(body: str) -> None:
    script = '''
package.path = "drivers/tests/lua_harness/?.lua;" .. package.path
require("host_mock")
host.reset()
dofile("drivers/lua/pixii_pv.lua")
driver_init({})

local function poll(payload)
    host._mqtt_buffer = {{
        topic = "pixii/status/test-pixii/meter_ext6",
        payload = payload,
    }}
    assert(driver_poll() == 1000)
end
''' + body
    result = subprocess.run(
        [str(LUA), "-e", script], cwd=ROOT, text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.parametrize(
    ("phases", "expected"),
    [
        ((1500, 1000, 500), -3000),
        ((0, 0, 0), 0),
        ((-1, -2, -3), 0),
        ((50, -3, -2), -45),
        ((-50, 3, 2), 0),
        ((5, -3, -2), 0),
    ],
)
def test_pixii_pv_reports_net_generation(phases, expected) -> None:
    payload = json.dumps(dict(
        meter_source="PV", meter_w1=phases[0], meter_w2=phases[1],
        meter_w3=phases[2], meter_kwh_imp=12.5))
    run_lua(f'''
poll({json.dumps(payload)})
local pv = host._emitted.pv
assert(pv and #pv == 1, "expected one PV reading")
assert(pv[1].w == {expected}, "PV W = " .. tostring(pv[1].w))
assert(pv[1].w <= 0, "FTW rejects positive PV power")
assert(pv[1].generation_wh == 12500, "generation counter changed")
assert(host._metrics.pv_w_total.value == {expected}, "total metric differs")
assert(host._metrics.pv_l1_w.value == {-phases[0]}, "phase 1 changed")
assert(host._metrics.pv_l2_w.value == {-phases[1]}, "phase 2 changed")
assert(host._metrics.pv_l3_w.value == {-phases[2]}, "phase 3 changed")
''')


@pytest.mark.parametrize("phase", ("meter_w1", "meter_w2", "meter_w3"))
@pytest.mark.parametrize("bad_value", (None, "invalid", "1e400", "-1e400"))
def test_pixii_pv_does_not_turn_invalid_power_into_zero(phase, bad_value) -> None:
    payload = dict(meter_source="PV", meter_w1=-1, meter_w2=-2, meter_w3=-3)
    if bad_value is None:
        del payload[phase]
    else:
        payload[phase] = bad_value
    encoded = json.dumps(json.dumps(payload))
    run_lua(f'''
poll({encoded})
assert(not host._emitted.pv, "invalid phase power emitted as PV")
assert(not host._metrics.pv_w_total, "invalid phase power emitted as total")
''')


def test_pixii_pv_sunset_idle_and_morning() -> None:
    run_lua('''
poll('{"meter_source":"PV","meter_w1":100,"meter_w2":100,"meter_w3":100}')
for _ = 1, 5 do
    poll('{"meter_source":"PV","meter_w1":-1,"meter_w2":-2,"meter_w3":-3}')
end
assert(#host._emitted.pv == 6, "night readings stopped")
for i = 2, 6 do
    assert(host._emitted.pv[i].w == 0, "night reading must show no generation")
end
host._emitted = {}
driver_poll()
assert(not host._emitted.pv, "idle poll replayed old PV data")

host._mqtt_buffer = {{
    topic = "pixii/status/test-pixii/meter",
    payload = '{"meter_w":-750}',
}}
driver_poll()
assert(host._emitted.meter[1].w == -750, "grid export sign changed")
assert(not host._emitted.pv, "grid-only message refreshed PV")
poll('{"meter_source":"PV","meter_w1":"1000","meter_w2":"2000","meter_w3":"3000"}')
assert(host._emitted.pv[1].w == -6000, "morning production did not return")
''')
