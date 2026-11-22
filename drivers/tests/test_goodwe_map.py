"""GoodWe ET / EH: PV, battery and meter come from GoodWe's documented map.

Up to 2.2.0 the driver read most of these values from the wrong registers
(srcfl/device-drivers#264): battery power from 35180 (the battery voltage),
battery voltage from 35178 (the BUS voltage), SoC from 35182 (the high word
of battery power), total PV from 35105 (PV1 power alone, scaled by 0.1),
grid frequency from 35113 (PV3 power), and the meter from the inverter's
own phase registers. These tests encode GoodWe's map:

- GoodWe, "Modbus Protocol Hybrid for Energy Storage Inverters",
  2 February 2024 (manifest upstream_docs): addresses, types and scales.
- evcc's goodwe-hybrid template and the goodwe library (et.py): the same
  addresses, and the signs. GoodWe counts battery discharge and meter
  export as positive; the driver turns both round.

All values are synthetic, not a capture.
"""

import math
import struct
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"
HARNESS = ROOT / "drivers" / "tests" / "lua_harness"
DRIVER = ROOT / "drivers" / "lua" / "goodwe.lua"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")

PYLONTECH = 0x101   # GoodWe Table 8-33, a BMS that talks


def u32(value: int) -> list[int]:
    value &= 0xFFFFFFFF
    return [value >> 16, value & 0xFFFF]


def s16(value: int) -> int:
    return value & 0xFFFF


def f32(value: float) -> list[int]:
    hi, lo = struct.unpack(">HH", struct.pack(">f", value))
    return [hi, lo]


NAN = [0x7FC0, 0x0000]


def pv_block(*, p1=2800, p2=2300, p3=0, p4=0, hz_raw=5001) -> list[int]:
    """35103-35123: PV1..PV4 V/A/P, PV mode, R-phase V/A/Hz."""
    return ([3500, 80] + u32(p1)       # 35103 V, 35104 A, 35105-35106 W
            + [3400, 70] + u32(p2)     # 35107-35110
            + [0, 0] + u32(p3)         # 35111-35114
            + [0, 0] + u32(p4)         # 35115-35118
            + [0, 0]                   # 35119-35120 PV mode
            + [2300, 50, hz_raw])      # 35121 V, 35122 A, 35123 Hz


def battery_block(*, volts_raw=5120, amps=39, watts=2000, mode=2) -> list[int]:
    """35180-35184. GoodWe signs: positive current and power = discharging."""
    return [volts_raw, s16(amps)] + u32(watts) + [mode]


def bms_block(*, soc=76, protocol=PYLONTECH) -> list[int]:
    bms = [0] * 24
    bms[7] = soc              # 37007, %
    bms[11] = protocol        # 37011
    return bms


def meter_block(*, comm=1, total=1200, phases=(400, 500, 300),
                export_wh=1234500.0, import_wh=6789000.0,
                hz_raw=5002) -> list[int]:
    """36004-36026. GoodWe signs: positive meter power = export."""
    regs = [0] * 23
    regs[0] = comm                          # 36004 meter communication
    regs[10] = hz_raw                       # 36014, x 0.01 Hz
    regs[11:13] = (export_wh if isinstance(export_wh, list)
                   else f32(export_wh))     # 36015-36016 float
    regs[13:15] = (import_wh if isinstance(import_wh, list)
                   else f32(import_wh))     # 36017-36018 float
    regs[15:17] = u32(phases[0])            # 36019-36020 S32
    regs[17:19] = u32(phases[1])            # 36021-36022
    regs[19:21] = u32(phases[2])            # 36023-36024
    regs[21:23] = u32(total)                # 36025-36026
    return regs


def site(over: dict[int, list[int]] | None = None) -> dict[int, list[int]]:
    regs = {
        35103: pv_block(),
        35191: u32(123456),                 # x 0.1 kWh
        35176: [455],
        35180: battery_block(),
        37000: bms_block(),
        36004: meter_block(),
        36052: [2301, 2302, 2303, 51, 62, 73],
    }
    regs.update(over or {})
    return regs


def poll(regs: dict[int, list[int]], fail: tuple[int, ...] = ()) -> dict[str, str]:
    setup = "\n".join(
        f"host._modbus_registers.holding[{addr}] = "
        "{" + ", ".join(str(v) for v in vals) + "}"
        for addr, vals in regs.items())
    setup += "\n" + "\n".join(
        f'host._modbus_read_fail_addresses[{addr}] = "Illegal Data Address"'
        for addr in fail)
    script = f'''
package.path = "{HARNESS}/?.lua;" .. package.path
require("host_mock")
host.reset()
{setup}
dofile("{DRIVER}")
driver_init({{}})
local ok, err = pcall(driver_poll)
if not ok then print("POLL_ERROR " .. tostring(err)) os.exit(1) end
for _, der in ipairs({{"pv", "battery", "meter"}}) do
    local list = host._emitted[der]
    print("EMITTED_" .. der .. " " .. tostring(list ~= nil and #list > 0))
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


def val(out: dict[str, str], key: str) -> float:
    assert key in out, f"{key} missing from {sorted(out)}"
    return float(out[key])


def close(out, key, expected):
    assert math.isclose(val(out, key), expected, rel_tol=1e-6, abs_tol=1e-9), \
        f"{key}={out.get(key)}, expected {expected}"


# ---------------------------------------------------------------- PV

def test_pv_power_is_the_sum_of_the_four_mppt_powers():
    # 35105, 35109, 35113, 35117 are U32 watts, one per MPPT.
    out = poll(site({35103: pv_block(p1=2800, p2=2300, p3=150, p4=50)}))
    close(out, "pv.w", -5300)


def test_pv_power_uses_both_words():
    out = poll(site({35103: pv_block(p1=70000, p2=0)}))
    close(out, "pv.w", -70000)


def test_pv_mppt_voltages_and_currents():
    out = poll(site())
    close(out, "pv.mppt1_v", 350.0)
    close(out, "pv.mppt1_a", 8.0)
    close(out, "pv.mppt2_v", 340.0)     # 35107, not 35109
    close(out, "pv.mppt2_a", 7.0)       # 35108
    close(out, "metric.pv_mppt2_v", 340.0)


def test_pv_lifetime_energy():
    out = poll(site())
    close(out, "pv.lifetime_wh", 12345600)   # 12345.6 kWh


def test_grid_frequency_comes_from_35123_not_pv3_power():
    out = poll(site({35103: pv_block(p3=4000, hz_raw=4998)}))
    close(out, "metric.grid_hz", 49.98)


def test_failed_pv_read_sends_no_pv():
    out = poll(site(), fail=(35103,))
    assert out["EMITTED_pv"] == "false"
    assert "metric.pv_mppt1_v" not in out
    assert "metric.grid_hz" not in out
    assert out["EMITTED_meter"] == "true"    # the rest still reports


def test_failed_pv_energy_read_leaves_only_that_out():
    out = poll(site(), fail=(35191,))
    assert "pv.lifetime_wh" not in out
    close(out, "pv.w", -5100)


# ----------------------------------------------------------- battery

def test_battery_discharging_is_negative():
    # GoodWe: +2000 W and +3.9 A while discharging (Table 8-9 mode 2).
    out = poll(site())
    close(out, "battery.w", -2000)
    close(out, "battery.a", -3.9)
    close(out, "battery.v", 512.0)
    close(out, "metric.battery_dc_v", 512.0)
    close(out, "metric.battery_dc_a", -3.9)


def test_battery_charging_is_positive_and_uses_both_words():
    out = poll(site({35180: battery_block(amps=-140, watts=-70000, mode=3)}))
    close(out, "battery.w", 70000)
    close(out, "battery.a", 14.0)


def test_battery_soc_comes_from_the_bms_block():
    out = poll(site())
    close(out, "battery.soc", 0.76)     # 37007, not 35182


def test_no_battery_sends_no_battery():
    # 35184 = 0: "No Battery, or battery disconnected".
    out = poll(site({35180: battery_block(volts_raw=0, amps=0, watts=0, mode=0)}))
    assert out["EMITTED_battery"] == "false"
    assert "metric.battery_dc_v" not in out
    assert out["EMITTED_pv"] == "true"


def test_failed_battery_read_sends_no_battery():
    out = poll(site(), fail=(35180,))
    assert out["EMITTED_battery"] == "false"
    assert "metric.battery_dc_v" not in out
    assert "metric.battery_dc_a" not in out


def test_soc_left_out_without_a_talking_bms():
    out = poll(site({37000: bms_block(soc=0, protocol=0x11F)}))
    assert "battery.soc" not in out
    close(out, "battery.w", -2000)


def test_failed_bms_read_leaves_soc_out():
    out = poll(site(), fail=(37000,))
    assert "battery.soc" not in out
    close(out, "battery.w", -2000)


# ------------------------------------------------------------- meter

def test_meter_export_is_negative():
    out = poll(site())
    close(out, "meter.w", -1200)        # 36025, GoodWe +1200 = export
    close(out, "meter.l1_w", -400)
    close(out, "meter.l2_w", -500)
    close(out, "meter.l3_w", -300)
    close(out, "metric.meter_l1_w", -400)


def test_meter_import_is_positive_and_uses_both_words():
    out = poll(site({36004: meter_block(total=-70000, phases=(-40000, -20000, -10000))}))
    close(out, "meter.w", 70000)
    close(out, "meter.l1_w", 40000)
    close(out, "meter.l3_w", 10000)


def test_meter_frequency_and_energy():
    out = poll(site())
    close(out, "meter.hz", 50.02)                 # 36014
    close(out, "meter.export_wh", 1234500.0)      # 36015, float Wh
    close(out, "meter.import_wh", 6789000.0)      # 36017, float Wh


def test_meter_phase_voltage_and_current():
    out = poll(site())
    close(out, "meter.l1_v", 230.1)
    close(out, "meter.l3_v", 230.3)
    close(out, "meter.l1_a", 5.1)
    close(out, "meter.l3_a", 7.3)
    close(out, "metric.meter_l2_a", 6.2)


def test_meter_phase_block_missing_keeps_the_rest():
    out = poll(site(), fail=(36052,))
    assert "meter.l1_v" not in out
    assert "meter.l1_a" not in out
    close(out, "meter.w", -1200)


def test_no_meter_sends_no_meter():
    # 36004 = 0: the inverter does not hear its meter.
    out = poll(site({36004: meter_block(comm=0, total=0, phases=(0, 0, 0))}))
    assert out["EMITTED_meter"] == "false"
    assert "metric.meter_l1_w" not in out
    assert out["EMITTED_pv"] == "true"
    assert out["EMITTED_battery"] == "true"


def test_failed_meter_read_sends_no_meter():
    out = poll(site(), fail=(36004,))
    assert out["EMITTED_meter"] == "false"


def test_nan_energy_is_left_out():
    out = poll(site({36004: meter_block(export_wh=NAN, import_wh=NAN)}))
    assert "meter.export_wh" not in out
    assert "meter.import_wh" not in out
    close(out, "meter.w", -1200)


def test_no_read_of_the_old_wrong_registers():
    """35178 (BUS voltage) and 35113 alone are gone; 35132-35141 too."""
    script = f'''
package.path = "{HARNESS}/?.lua;" .. package.path
require("host_mock")
host.reset()
dofile("{DRIVER}")
driver_init({{}})
pcall(driver_poll)
for _, c in ipairs(host._calls) do
    if c.func == "modbus_read" then print(c.args[1] .. " " .. c.args[2]) end
end
'''
    result = subprocess.run([str(LUA), "-e", script],
                            capture_output=True, text=True, cwd=ROOT)
    assert result.returncode == 0, result.stdout + result.stderr
    starts = {int(line.split()[0]) for line in result.stdout.split("\n") if line}
    for old in (35178, 35179, 35182, 35113, 35109, 35140, 35132, 35121, 35195, 35199):
        assert old not in starts, f"still reads {old}"
