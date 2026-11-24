"""Sigenergy reports what its battery can do now, and nothing it did not read.

Plant registers from "Sigenergy Modbus Protocol" V2.9, table 5-1 (slave 247,
FC04): 30047/30049 [ESS] available max charging/discharging power (U32,
gain 1000 on kW, so the raw value is watts) and 30286 [ESS] average cell
temperature (S16, gain 10, °C). A failed read or a value outside -40..100 °C
or 0..100 kW is left out of the emit and of the metrics, and a plant whose
ESS does not answer is not asked (docs/WRITING-A-DRIVER.md, "What a battery
can do now").
"""

import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"
HARNESS = ROOT / "drivers" / "tests" / "lua_harness"
DRIVER = ROOT / "drivers" / "lua" / "sigenergy.lua"
KIND = "input"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")


def _poll(registers: dict, fail: tuple = ()) -> dict[str, str]:
    setup = "\n".join(
        f"host._modbus_registers.{KIND}[{addr}] = "
        + ("{" + ", ".join(str(v) for v in val) + "}"
           if isinstance(val, list) else str(val))
        for addr, val in registers.items())
    failing = "\n".join(
        f'host._modbus_read_fail_addresses[{addr}] = "Illegal Data Address"'
        for addr in fail)
    script = f'''
package.path = "{HARNESS}/?.lua;" .. package.path
require("host_mock")
host.reset()
{setup}
{failing}
dofile("{DRIVER}")
driver_init({{}})
local ok, err = pcall(driver_poll)
if not ok then print("POLL_ERROR " .. tostring(err)) os.exit(1) end
for _, der in ipairs({{"battery", "pv"}}) do
    local list = host._emitted[der]
    if list and #list > 0 then
        for k, v in pairs(list[#list]) do print(der .. "." .. k .. " " .. tostring(v)) end
    end
end
for name, m in pairs(host._metrics) do print("metric." .. name .. " " .. tostring(m.value)) end
for _, call in ipairs(host._calls) do
    if call.func == "modbus_read" then print("read." .. tostring(call.args[1]) .. " 1") end
end
'''
    result = subprocess.run([str(LUA), "-e", script],
                            capture_output=True, text=True, cwd=ROOT)
    assert result.returncode == 0, result.stdout + result.stderr
    return dict(line.split(" ", 1)
                for line in result.stdout.strip().splitlines() if " " in line)


# An ESS that answers: 1000 W charging at 50 % SoC.
ESS = {30037: [0, 1000], 30014: 500}

BATTERY_KEYS = ("battery.temperature_C", "battery.available_charge_W",
                "battery.available_discharge_W", "metric.battery_temp_c",
                "metric.battery_available_charge_w",
                "metric.battery_available_discharge_w")


def test_sigenergy_reports_temperature_and_limits_with_their_scale():
    out = _poll({**ESS,
                 30047: [0, 5000, 0x0001, 0x0000],   # 5000 W / 65536 W
                 30286: 0xFFCE})                     # -5.0 °C
    assert float(out["battery.available_charge_W"]) == 5000
    assert float(out["battery.available_discharge_W"]) == 65536
    assert float(out["battery.temperature_C"]) == pytest.approx(-5.0)
    assert float(out["metric.battery_available_charge_w"]) == 5000
    assert float(out["metric.battery_available_discharge_w"]) == 65536
    assert float(out["metric.battery_temp_c"]) == pytest.approx(-5.0)


def test_sigenergy_zero_limit_is_kept():
    """0 W means the plant allows nothing now; it is a reading, not a gap."""
    out = _poll({**ESS, 30047: [0, 0, 0, 3000]})
    assert float(out["battery.available_charge_W"]) == 0
    assert float(out["battery.available_discharge_W"]) == 3000


def test_sigenergy_leaves_out_what_did_not_answer():
    out = _poll(ESS, fail=(30047, 30286))
    for key in BATTERY_KEYS:
        assert key not in out, f"{key} was sent although its read failed"
    assert "battery.w" in out  # the rest of the battery still reports


def test_sigenergy_drops_values_outside_the_window():
    out = _poll({**ESS,
                 30047: [0x0002, 0x0000, 0xFFFF, 0xFFFF],  # 131072 W, 4294967295 W
                 30286: 1500})                             # 150.0 °C
    for key in BATTERY_KEYS:
        assert key not in out, f"{key} passed although it is out of range"


def test_sigenergy_pv_only_plant_is_not_asked_for_battery_limits():
    out = _poll({30047: [0, 5000, 0, 6000], 30286: 235}, fail=(30037, 30014))
    assert "battery.w" not in out
    assert "read.30047" not in out and "read.30286" not in out
    for key in BATTERY_KEYS:
        assert key not in out


@pytest.mark.parametrize("raw, kept", [
    (0xFE70, -40.0), (1000, 100.0),      # the edges stay in
    (0xFE6F, None), (1001, None),        # one tenth past them does not
])
def test_sigenergy_temperature_edges(raw, kept):
    out = _poll({**ESS, 30286: raw})
    if kept is None:
        assert "battery.temperature_C" not in out
    else:
        assert float(out["battery.temperature_C"]) == pytest.approx(kept)
