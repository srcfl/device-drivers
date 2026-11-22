"""Fronius reads its cabinet temperature, and sends it only when it has one.

Fronius's GEN24, Tauro and Verto maps put TmpCab, "Cabinet Temperature"
(float32 °C), at register 40110 in their 1-based numbering, which is address
40109 on the wire, and mark TmpSnk at 40111 "not supported". Earlier
releases read 40111, got NaN and sent 0 °C. A failed read, NaN or a value
outside -40..100 °C is now left out of the emit and of the metric
(docs/WRITING-A-DRIVER.md, "What a battery can do now"). Fronius documents
no battery temperature and no live charge or discharge limit over Modbus,
so none is sent.
"""

import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"
HARNESS = ROOT / "drivers" / "tests" / "lua_harness"
DRIVER = ROOT / "drivers" / "lua" / "fronius.lua"
KIND = "holding"

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


NAN = [0x7FC0, 0x0000]


def test_fronius_reports_cabinet_temperature():
    # 31.5 °C at TmpCab; TmpSnk next to it answers NaN, as Fronius documents.
    out = _poll({40109: [0x41FC, 0x0000], 40111: NAN})
    assert float(out["pv.temp_c"]) == pytest.approx(31.5)
    assert float(out["metric.inverter_temp_c"]) == pytest.approx(31.5)


def test_fronius_negative_cabinet_temperature():
    out = _poll({40109: [0xC0A0, 0x0000]})  # -5.0 °C
    assert float(out["pv.temp_c"]) == pytest.approx(-5.0)


def test_fronius_leaves_out_a_failed_read():
    out = _poll({}, fail=(40109,))
    assert "pv.temp_c" not in out
    assert "metric.inverter_temp_c" not in out
    assert "pv.w" in out  # the rest of PV still reports


def test_fronius_leaves_out_nan_and_out_of_range():
    for regs in (NAN, [0x7F80, 0x0000], [0x4316, 0x0000]):  # NaN, +inf, 150.0
        out = _poll({40109: regs})
        assert "pv.temp_c" not in out, f"{regs} was sent as a temperature"
        assert "metric.inverter_temp_c" not in out


def test_fronius_sends_no_battery_temperature_or_available_power():
    out = _poll({40109: [0x41FC, 0x0000]})
    assert "battery.temp_c" not in out
    assert "battery.temperature_C" not in out
    assert not any(k.startswith("battery.available_") for k in out)


@pytest.mark.parametrize("regs, kept", [
    ([0xC220, 0x0000], -40.0), ([0x42C8, 0x0000], 100.0),   # the edges stay in
    ([0xC221, 0x0000], None), ([0x42C9, 0x0000], None),     # just past them does not
])
def test_fronius_temperature_edges(regs, kept):
    out = _poll({40109: regs})
    if kept is None:
        assert "pv.temp_c" not in out
    else:
        assert float(out["pv.temp_c"]) == pytest.approx(kept)
