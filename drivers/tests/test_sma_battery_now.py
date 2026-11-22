"""SMA sends a battery and inverter temperature only when it read one.

30849 is "Battery temperature" and 30953 "Internal temperature", both S32 in
SMA's TEMP format (one decimal place). Earlier releases sent 0 °C when either
read failed. A failed read, SMA's S32 NaN (0x80000000), or a value outside
-40..100 °C is now left out of the emit and of the metrics
(docs/WRITING-A-DRIVER.md, "What a battery can do now"). SMA documents no
live charge or discharge limit, so none is sent.
"""

import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"
HARNESS = ROOT / "drivers" / "tests" / "lua_harness"
DRIVER = ROOT / "drivers" / "lua" / "sma.lua"
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
'''
    result = subprocess.run([str(LUA), "-e", script],
                            capture_output=True, text=True, cwd=ROOT)
    assert result.returncode == 0, result.stdout + result.stderr
    return dict(line.split(" ", 1)
                for line in result.stdout.strip().splitlines() if " " in line)


TEMPERATURE_KEYS = ("battery.temp_c", "pv.temp_c",
                    "metric.battery_temp_c", "metric.inverter_temp_c")


def test_sma_reports_temperatures_with_their_scale():
    out = _poll({30849: [0xFFFF, 0xFFCE],   # -5.0 °C
                 30953: [0, 412]})          # 41.2 °C
    assert float(out["battery.temp_c"]) == pytest.approx(-5.0)
    assert float(out["metric.battery_temp_c"]) == pytest.approx(-5.0)
    assert float(out["pv.temp_c"]) == pytest.approx(41.2)
    assert float(out["metric.inverter_temp_c"]) == pytest.approx(41.2)


def test_sma_leaves_out_temperatures_that_did_not_answer():
    out = _poll({}, fail=(30849, 30953))
    for key in TEMPERATURE_KEYS:
        assert key not in out, f"{key} was sent although its read failed"
    assert "battery.w" in out  # the rest of the battery still reports


def test_sma_leaves_out_nan():
    out = _poll({30849: [0x8000, 0], 30953: [0x8000, 0]})
    for key in TEMPERATURE_KEYS:
        assert key not in out, f"{key} was sent for SMA's NaN"


def test_sma_drops_temperatures_outside_the_window():
    out = _poll({30849: [0, 1500],          # 150.0 °C
                 30953: [0, 2982]})         # 298.2, a unit set to K
    for key in TEMPERATURE_KEYS:
        assert key not in out, f"{key} passed although it is out of range"


def test_sma_sends_no_available_power():
    out = _poll({30849: [0, 235]})
    assert not any(k.startswith("battery.available_") for k in out)


@pytest.mark.parametrize("regs, kept", [
    ([0xFFFF, 0xFE70], -40.0), ([0, 1000], 100.0),   # the edges stay in
    ([0xFFFF, 0xFE6F], None), ([0, 1001], None),     # one tenth past them does not
])
def test_sma_temperature_edges(regs, kept):
    out = _poll({30849: regs, 30953: regs})
    for key in ("battery.temp_c", "pv.temp_c"):
        if kept is None:
            assert key not in out
        else:
            assert float(out[key]) == pytest.approx(kept)
