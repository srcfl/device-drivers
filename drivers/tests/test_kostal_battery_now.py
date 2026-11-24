"""KOSTAL reports what its battery can do now, and nothing it did not read.

From KOSTAL's interface description (revision 2.10): 0x05 is the MODBUS byte
order (0 = CDAB, 1 = ABCD), 0x24C (588) the battery type (0 = no battery),
0xD6 (214) the battery temperature and 0x434/0x436 (1076/1078) the maximum
charge and discharge power limit "read-out from battery", each a Float. A
failed read, NaN, a value outside -40..100 °C or 0..100 kW, an unknown word
order or a missing battery leaves the field and its metric out
(docs/WRITING-A-DRIVER.md, "What a battery can do now").
"""

import struct
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"
HARNESS = ROOT / "drivers" / "tests" / "lua_harness"
DRIVER = ROOT / "drivers" / "lua" / "kostal.lua"
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
for _, call in ipairs(host._calls) do
    if call.func == "modbus_read" then print("read." .. tostring(call.args[1]) .. " 1") end
end
'''
    result = subprocess.run([str(LUA), "-e", script],
                            capture_output=True, text=True, cwd=ROOT)
    assert result.returncode == 0, result.stdout + result.stderr
    return dict(line.split(" ", 1)
                for line in result.stdout.strip().splitlines() if " " in line)


def words(value: float, low_word_first: bool) -> list[int]:
    """A float32 as two registers in KOSTAL's configured word order."""
    hi, lo = struct.unpack(">HH", struct.pack(">f", value))
    return [lo, hi] if low_word_first else [hi, lo]


def device(temp: float, charge: float, discharge: float,
           low_word_first: bool = True, battery_type: int = 0x0004) -> dict:
    return {
        5: 0 if low_word_first else 1,
        588: battery_type,                       # 0x0004 = BYD
        214: words(temp, low_word_first),
        1076: words(charge, low_word_first) + words(discharge, low_word_first),
    }


BATTERY_KEYS = ("battery.temperature_C", "battery.available_charge_W",
                "battery.available_discharge_W", "metric.battery_temp_c",
                "metric.battery_available_charge_w",
                "metric.battery_available_discharge_w")


@pytest.mark.parametrize("low_word_first", [True, False], ids=["cdab", "abcd"])
def test_kostal_reports_temperature_and_limits_in_either_word_order(low_word_first):
    out = _poll(device(-5.5, 5000.0, 6200.0, low_word_first))
    assert float(out["battery.temperature_C"]) == pytest.approx(-5.5)
    assert float(out["battery.available_charge_W"]) == pytest.approx(5000.0)
    assert float(out["battery.available_discharge_W"]) == pytest.approx(6200.0)
    assert float(out["metric.battery_temp_c"]) == pytest.approx(-5.5)
    assert float(out["metric.battery_available_charge_w"]) == pytest.approx(5000.0)
    assert float(out["metric.battery_available_discharge_w"]) == pytest.approx(6200.0)


def test_kostal_zero_limit_is_kept():
    """0 W means the battery allows nothing now; it is a reading, not a gap."""
    out = _poll(device(1.0, 0.0, 3000.0))
    assert float(out["battery.available_charge_W"]) == 0


def test_kostal_leaves_out_what_did_not_answer():
    out = _poll(device(20.0, 5000.0, 6200.0), fail=(214, 1076))
    for key in BATTERY_KEYS:
        assert key not in out, f"{key} was sent although its read failed"
    assert "battery.w" in out  # the rest of the battery still reports


def test_kostal_without_word_order_reads_no_float():
    out = _poll(device(20.0, 5000.0, 6200.0), fail=(5,))
    for key in BATTERY_KEYS:
        assert key not in out, f"{key} was sent with an unknown word order"
    assert "read.214" not in out and "read.1076" not in out


def test_kostal_without_battery_reads_no_battery_value():
    out = _poll(device(20.0, 5000.0, 6200.0, battery_type=0))
    for key in BATTERY_KEYS:
        assert key not in out, f"{key} was sent for an inverter with no battery"
    assert "read.214" not in out and "read.1076" not in out


def test_kostal_drops_values_outside_the_window():
    out = _poll(device(150.0, -5000.0, 150000.0))
    for key in BATTERY_KEYS:
        assert key not in out, f"{key} passed although it is out of range"


def test_kostal_drops_nan():
    regs = device(20.0, 5000.0, 6200.0)
    regs[214] = [0x0000, 0x7FC0]                 # NaN, CDAB
    regs[1076] = [0x0000, 0x7FC0, 0x0000, 0x7F80]  # NaN, +inf
    out = _poll(regs)
    for key in BATTERY_KEYS:
        assert key not in out, f"{key} was sent for NaN or infinity"


def test_kostal_inverter_temperature_needs_value_and_scale():
    good = _poll({40103: 412, 40106: 0xFFFF})    # 412 × 10^-1
    assert float(good["pv.temp_c"]) == pytest.approx(41.2)
    assert float(good["metric.inverter_temp_c"]) == pytest.approx(41.2)
    for regs, fail in (({40106: 0xFFFF}, (40103,)),
                       ({40103: 412}, (40106,)),
                       ({40103: 0x8000, 40106: 0xFFFF}, ())):
        out = _poll(regs, fail=fail)
        assert "pv.temp_c" not in out
        assert "metric.inverter_temp_c" not in out


@pytest.mark.parametrize("temp, kept", [
    (-40.0, True), (100.0, True), (-40.5, False), (100.5, False)])
def test_kostal_temperature_edges(temp, kept):
    out = _poll(device(temp, 1000.0, 1000.0))
    assert ("battery.temperature_C" in out) == kept
