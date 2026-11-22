"""Huawei reports what its battery can do now, and nothing it did not read.

Registers from Huawei's "Solar Inverter Modbus Interface Definitions",
table 3-2: 37022 battery temperature (I16, 0.1 °C), 37046/37048 maximum
charge/discharge power (U32, W), and 32087 inverter temperature (I16, 0.1 °C).
A read that fails, or a value outside -40..100 °C or 0..100 kW, is left out
of the emit and of the metrics (docs/WRITING-A-DRIVER.md, "What a battery
can do now"). The battery's own values are read only once 37007/37009 show
a rated power above 0, since a SUN2000 with no LUNA2000 may answer the
battery registers with 0.
"""

import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"
HARNESS = ROOT / "drivers" / "tests" / "lua_harness"
DRIVER = ROOT / "drivers" / "lua" / "huawei.lua"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")

# A battery that answers: 1500 W charging at 50 % SoC, rated 5000 W both ways.
BATTERY = {37001: [0, 1500], 37004: 500, 37007: [0, 5000, 0, 5000]}


def _poll(registers: dict, fail: tuple = ()) -> dict[str, str]:
    setup = "\n".join(
        f"host._modbus_registers.holding[{addr}] = "
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


def test_huawei_reports_temperature_and_limits_with_their_scale():
    out = _poll({**BATTERY,
                 37022: 0xFFCE,                  # -5.0 °C
                 37046: [0, 5000, 0, 4500],      # 5000 W / 4500 W
                 32087: 412})                    # 41.2 °C
    assert float(out["battery.temp_c"]) == pytest.approx(-5.0)
    assert float(out["battery.available_charge_W"]) == 5000
    assert float(out["battery.available_discharge_W"]) == 4500
    assert float(out["metric.battery_temp_c"]) == pytest.approx(-5.0)
    assert float(out["metric.battery_available_charge_w"]) == 5000
    assert float(out["metric.battery_available_discharge_w"]) == 4500
    assert float(out["pv.temp_c"]) == pytest.approx(41.2)
    assert float(out["metric.inverter_temp_c"]) == pytest.approx(41.2)


def test_huawei_leaves_out_what_did_not_answer():
    out = _poll(BATTERY, fail=(37022, 37046, 32087))
    for key in ("battery.temp_c", "battery.available_charge_W",
                "battery.available_discharge_W", "pv.temp_c",
                "metric.battery_temp_c", "metric.battery_available_charge_w",
                "metric.battery_available_discharge_w",
                "metric.inverter_temp_c"):
        assert key not in out, f"{key} was sent although its read failed"
    assert "battery.w" in out  # the rest of the battery still reports


def test_huawei_drops_values_outside_the_window():
    out = _poll({**BATTERY,
                 37022: 1500,                            # 150.0 °C
                 37046: [0xFFFF, 0xFFFF, 0x0002, 0x0000],  # 4294967295 W, 131072 W
                 32087: 0xFC18})                         # -100.0 °C
    for key in ("battery.temp_c", "battery.available_charge_W",
                "battery.available_discharge_W", "pv.temp_c",
                "metric.battery_temp_c", "metric.inverter_temp_c"):
        assert key not in out, f"{key} passed although it is out of range"


def test_huawei_zero_limit_is_kept():
    """0 W means the BMS allows nothing now; it is a reading, not a gap."""
    out = _poll({**BATTERY, 37046: [0, 0, 0, 3000]})
    assert float(out["battery.available_charge_W"]) == 0
    assert float(out["battery.available_discharge_W"]) == 3000


def test_huawei_no_battery_answer_means_no_limit_read():
    out = _poll({37046: [0, 5000, 0, 4500]}, fail=(37001, 37004))
    assert "read.37046" not in out
    assert "battery.available_charge_W" not in out


BATTERY_KEYS = ("battery.temp_c", "battery.available_charge_W",
                "battery.available_discharge_W", "metric.battery_temp_c",
                "metric.battery_available_charge_w",
                "metric.battery_available_discharge_w")


def test_huawei_without_luna2000_sends_no_battery_limit_or_temperature():
    """A SUN2000 with no battery answers the battery registers with 0.

    That must not become "the battery may not charge now" (0 W) or a 0 °C
    battery: a zero rating means there is no unit, so nothing is read.
    """
    out = _poll({37001: [0, 0], 37004: 0, 37007: [0, 0, 0, 0],
                 37022: 0, 37046: [0, 0, 0, 0]})
    for key in BATTERY_KEYS:
        assert key not in out, f"{key} was sent for a battery that is not there"
    assert "read.37046" not in out and "read.37022" not in out


def test_huawei_rating_that_does_not_answer_reads_no_battery_value():
    out = _poll({37001: [0, 1500], 37004: 500, 37022: 235,
                 37046: [0, 5000, 0, 4500]}, fail=(37007,))
    for key in BATTERY_KEYS:
        assert key not in out, f"{key} was sent without a rated unit"


def test_huawei_one_rating_above_zero_is_enough():
    out = _poll({37001: [0, 1500], 37004: 500, 37007: [0, 0, 0, 3000],
                 37022: 235, 37046: [0, 2500, 0, 3000]})
    assert float(out["battery.temp_c"]) == pytest.approx(23.5)
    assert float(out["battery.available_charge_W"]) == 2500


@pytest.mark.parametrize("raw, kept", [
    (0xFE70, -40.0), (1000, 100.0),      # the edges stay in
    (0xFE6F, None), (1001, None),        # one tenth past them does not
])
def test_huawei_temperature_edges(raw, kept):
    out = _poll({**BATTERY, 37022: raw, 32087: raw})
    for key in ("battery.temp_c", "pv.temp_c"):
        if kept is None:
            assert key not in out
        else:
            assert float(out[key]) == pytest.approx(kept)
