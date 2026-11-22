"""Fronius reads the battery where Fronius's GEN24 and Verto storage maps put it.

Source: Fronius's register map bundle 1.2.7-2 (www.fronius.com/QR-link/0024,
linked from the GEN24 Modbus manual 42,0410,2649), the float maps with
storage. Fronius numbers registers from 1, so the wire address is one lower.

* Model 160 (MPPT) starts at register 40264, wire 40263. Its length is
  8 + 20 x N. With storage, N counts the trackers plus two inputs for the
  battery, "StCha" (charge) and "StDisCha" (discharge), the last two blocks.
  A GEN24 has N = 4 (L = 88), a Verto with three trackers N = 5 (L = 108).
* Model 124 (storage) follows model 160 directly, and only with storage.
  ChaState is at offset 8 and ChaState_SF at offset 22.
* Battery power is the charge input's DCW minus the discharge input's DCW
  (Fronius sets the idle one to 0; evcc's fronius-gen24 template reads it
  the same way). Battery voltage is the inputs' DCV: since firmware 1.31
  both carry it, before that only the active one did.

Earlier releases read model 124 at fixed addresses that assume a two-input
model 160, so on a GEN24 with storage they landed in model 160's battery
blocks, and they took battery power from the OutWRte / InWRte setpoints.
They also sent a battery at 0 W, 0 V and 0 % on an inverter with none, and
their float decoder flipped the sign of every float on 32-bit Lua, which the
harness uses.
"""

import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"
HARNESS = ROOT / "drivers" / "tests" / "lua_harness"
DRIVER = ROOT / "drivers" / "lua" / "fronius.lua"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")

MPPT = 40263          # wire address of model 160's ID (register 40264)
NAN = (0x7FC0, 0x0000)


def u16(value: int) -> int:
    return value & 0xFFFF


def text(s: str) -> list[int]:
    raw = s.encode().ljust(16, b"\0")
    return [raw[i] * 256 + raw[i + 1] for i in range(0, 16, 2)]


def site(trackers: int = 2, storage: bool = True, *, dca_sf=-2, dcv_sf=-1,
         dcw_sf=0, cha=(0, 0, 0), dis=(0, 0, 0), soc_raw=5000, soc_sf=-2,
         mppt1=(850, 3512), mppt2=(420, 3300), names=None) -> dict[int, int]:
    """Registers of a Fronius float map, keyed by wire address.

    cha / dis are (DCA, DCV, DCW) raw values for the storage inputs.
    """
    n = trackers + (2 if storage else 0)
    length = 8 + 20 * n
    regs: dict[int, int] = {
        MPPT: 160, MPPT + 1: length,
        MPPT + 2: u16(dca_sf), MPPT + 3: u16(dcv_sf), MPPT + 4: u16(dcw_sf),
        MPPT + 5: 0, MPPT + 8: n,
    }
    if names is None:
        names = [f"MPPT {k}" for k in range(1, trackers + 1)]
        if storage:
            names += [f"StCha {trackers + 1}", f"StDisCha {trackers + 2}"]
    values = [mppt1, mppt2] + [(0, 0)] * (trackers - 2)
    for k in range(1, n + 1):
        base = MPPT + 10 + 20 * (k - 1)
        regs[base] = k
        for i, word in enumerate(text(names[k - 1])):
            regs[base + 1 + i] = word
        if k <= trackers:
            dca, dcv = values[k - 1]
            regs[base + 9], regs[base + 10], regs[base + 11] = dca, dcv, 0
        else:
            regs[base + 9], regs[base + 10], regs[base + 11] = (
                cha if k == trackers + 1 else dis)
    nxt = MPPT + 2 + length
    if storage:
        regs[nxt], regs[nxt + 1] = 124, 24
        regs[nxt + 8] = soc_raw
        regs[nxt + 22] = u16(soc_sf)
        regs[nxt + 26] = 0xFFFF        # end block
    else:
        regs[nxt], regs[nxt + 1] = 0xFFFF, 0
    return regs


def _poll(registers: dict, fail: tuple = (), polls: int = 1) -> dict[str, str]:
    setup = "\n".join(
        f"host._modbus_registers.holding[{addr}] = {val}"
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
for _ = 1, {polls} do
    host._emitted = {{}}
    host._metrics = {{}}
    local ok, err = pcall(driver_poll)
    if not ok then print("POLL_ERROR " .. tostring(err)) os.exit(1) end
end
for _, der in ipairs({{"battery", "pv", "meter"}}) do
    local list = host._emitted[der]
    if list and #list > 0 then
        print(der .. " emitted")
        for k, v in pairs(list[#list]) do print(der .. "." .. k .. " " .. tostring(v)) end
    end
end
for name, m in pairs(host._metrics) do print("metric." .. name .. " " .. tostring(m.value)) end
local reads = {{}}
for _, c in ipairs(host._calls) do
    if c.func == "modbus_read" then reads[#reads + 1] = c.args[1] .. ":" .. c.args[2] end
end
print("reads " .. table.concat(reads, ","))
'''
    result = subprocess.run([str(LUA), "-e", script],
                            capture_output=True, text=True, cwd=ROOT)
    assert result.returncode == 0, result.stdout + result.stderr
    return dict(line.split(" ", 1)
                for line in result.stdout.strip().splitlines() if " " in line)


def test_gen24_charging():
    # DCW_SF 0: 1234 W into the battery. DCV_SF -1: 52.3 V. ChaState 65.43 %.
    out = _poll(site(cha=(2360, 523, 1234), dis=(0, 523, 0), soc_raw=6543))
    assert float(out["battery.w"]) == pytest.approx(1234)
    assert float(out["battery.v"]) == pytest.approx(52.3)
    assert float(out["battery.soc"]) == pytest.approx(0.6543)
    assert float(out["metric.battery_dc_v"]) == pytest.approx(52.3)


def test_gen24_discharging_is_negative():
    out = _poll(site(dcw_sf=-1, cha=(0, 518, 0), dis=(4800, 518, 25000)))
    assert float(out["battery.w"]) == pytest.approx(-2500)
    assert float(out["battery.v"]) == pytest.approx(51.8)


def test_gen24_old_firmware_voltage_on_the_active_input_only():
    # Up to firmware 1.30 the idle input's DCV is 0 as well.
    out = _poll(site(cha=(0, 0, 0), dis=(1000, 510, 500)))
    assert float(out["battery.v"]) == pytest.approx(51.0)
    assert float(out["battery.w"]) == pytest.approx(-500)


def test_gen24_idle_old_firmware_leaves_voltage_out():
    # Both inputs at 0 V means neither is active, not a 0 V battery.
    out = _poll(site(cha=(0, 0, 0), dis=(0, 0, 0)))
    assert "battery.v" not in out
    assert "metric.battery_dc_v" not in out
    assert float(out["battery.w"]) == 0
    assert float(out["battery.soc"]) == pytest.approx(0.5)


def test_verto_three_trackers_and_storage():
    # Verto: N = 5, model 124 at register 40374 (wire 40373).
    regs = site(trackers=3, cha=(0, 0, 0), dis=(0, 0, 0), soc_raw=8000)
    regs.update({MPPT + 10 + 20 * 3 + 9: 1500, MPPT + 10 + 20 * 3 + 10: 530,
                 MPPT + 10 + 20 * 3 + 11: 800})
    assert regs[40373] == 124
    out = _poll(regs)
    assert float(out["battery.w"]) == pytest.approx(800)
    assert float(out["battery.v"]) == pytest.approx(53.0)
    assert float(out["battery.soc"]) == pytest.approx(0.8)


def test_mppt_values_from_the_model_160_block():
    out = _poll(site(mppt1=(850, 3512), mppt2=(420, 3300)))
    assert float(out["pv.mppt1_a"]) == pytest.approx(8.5)
    assert float(out["pv.mppt1_v"]) == pytest.approx(351.2)
    assert float(out["pv.mppt2_a"]) == pytest.approx(4.2)
    assert float(out["pv.mppt2_v"]) == pytest.approx(330.0)


def test_no_storage_sends_no_battery():
    out = _poll(site(storage=False), polls=3)
    assert "battery" not in out
    assert "metric.battery_dc_v" not in out
    assert float(out["pv.mppt1_v"]) == pytest.approx(351.2)


def test_no_storage_reads_nothing_past_the_end_block():
    # The register after model 160 is the end block there (wire 40313),
    # which answers, so the driver learns there is no battery without
    # reading past the end of the map, where a real inverter answers with
    # an exception.
    out = _poll(site(storage=False), polls=3)
    assert "battery" not in out
    for read in out["reads"].split(","):
        addr, count = (int(x) for x in read.split(":"))
        assert addr + count <= 40315, f"read {count} registers at {addr}"


def test_model_124_does_not_answer():
    out = _poll(site(cha=(0, 520, 900)), fail=(40353,), polls=4)
    assert "battery" not in out


def test_soc_not_implemented_leaves_soc_out():
    for regs in (site(cha=(0, 520, 900), soc_raw=0xFFFF),
                 site(cha=(0, 520, 900), soc_sf=-32768)):
        out = _poll(regs)
        assert "battery.soc" not in out
        assert float(out["battery.w"]) == pytest.approx(900)


def test_soc_out_of_range_is_dropped():
    out = _poll(site(cha=(0, 520, 900), soc_raw=10001))
    assert "battery.soc" not in out


def test_storage_inputs_not_named_as_documented():
    names = ["MPPT 1", "MPPT 2", "MPPT 3", "MPPT 4"]
    out = _poll(site(cha=(0, 520, 900), names=names))
    assert "battery.w" not in out
    assert "battery.v" not in out
    assert float(out["battery.soc"]) == pytest.approx(0.5)


def test_model_160_not_where_the_float_map_puts_it():
    # The int+SF maps start model 160 at register 40254; at 40264 there is
    # something else. The driver reads no DC input or battery values then.
    regs = site()
    regs[MPPT] = 0
    out = _poll(regs)
    assert "battery" not in out
    assert not any(k.startswith("pv.mppt") for k in out)


def test_model_160_does_not_answer():
    out = _poll(site(), fail=(MPPT,), polls=4)
    assert "battery" not in out
    assert not any(k.startswith("pv.mppt") for k in out)


def test_old_addresses_are_not_read():
    # Main read WChaMax at wire 40315, ChaState at 40321, InBatV at 40323 and
    # OutWRte / InWRte at 40325 / 40326 with scale factors at 40331-40338.
    regs = site(cha=(0, 520, 900))
    out = _poll(regs, fail=(40315, 40321, 40323, 40325, 40326,
                            40331, 40335, 40337, 40338))
    assert float(out["battery.w"]) == pytest.approx(900)
    assert float(out["battery.soc"]) == pytest.approx(0.5)


def test_float_values_keep_their_sign():
    # 6000.0 W DC, 50.0 Hz, 12345678 Wh. Main's decoder joined the words into
    # one 32-bit number and compared it with 0x80000000, which is negative on
    # 32-bit Lua, so every float came out negative here.
    regs = site()
    regs.update({40107: 0x45BB, 40108: 0x8000,      # DCW 6000.0
                 40093: 0x4248, 40094: 0x0000,      # Hz 50.0
                 40101: 0x4B3C, 40102: 0x614E})     # WH 12345678.0
    out = _poll(regs)
    assert float(out["pv.w"]) == pytest.approx(-6000)
    assert float(out["metric.grid_hz"]) == pytest.approx(50.0)
    assert float(out["pv.lifetime_wh"]) == pytest.approx(12345678)


def test_float_nan_is_left_out_not_sent_as_zero():
    regs = site()
    regs.update({40107: NAN[0], 40108: NAN[1],
                 40093: NAN[0], 40094: NAN[1],
                 40101: NAN[0], 40102: NAN[1]})
    out = _poll(regs)
    assert "pv" not in out          # DC power is PV's defining value
    assert "metric.grid_hz" not in out


def test_failed_pv_reads_are_left_out():
    out = _poll(site(), fail=(40101, 40093, 40134))
    assert "pv.lifetime_wh" not in out
    assert "pv.rated_w" not in out
    assert "metric.grid_hz" not in out
    assert "pv.w" in out


def test_rated_power_with_its_scale_factor():
    regs = site()
    regs.update({40134: 1000, 40135: 1})       # WRtg 1000 x 10^1
    out = _poll(regs)
    assert float(out["pv.rated_w"]) == pytest.approx(10000)
