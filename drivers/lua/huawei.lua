-- Huawei SUN2000 Hybrid Inverter Driver
-- Emits: PV, Battery, Meter
-- Protocol: Modbus TCP, ALL HOLDING registers, Big-Endian word order
--
-- Ported from sourceful-hugin/device-support/drivers/lua/huawei.lua
-- for FTW Lua host v2.1.
--
-- Reference: Huawei SUN2000 Modbus Interface Definition
-- (inverter + LUNA2000 battery module via SDongle / embedded Modbus TCP).
-- The battery and limit registers below were checked against Huawei's
-- "Solar Inverter Modbus Interface Definitions", issue 02 (2021-08-12) and
-- issue 05 (2023-02-16), table 3-2 "Battery Equipment Register". Huawei does
-- not publish that document at a public URL of its own; the copies found
-- were forum uploads, so it is named here instead of in upstream_docs.
--
-- Sign convention (site convention — positive W = INTO the site):
--   pv.w:       always negative (generation)
--   battery.w:  positive = charging, negative = discharging
--   meter.w:    positive = import from grid, negative = export
--
-- Huawei's meter register reports power with the OPPOSITE sign from our
-- convention (positive = export on Huawei), so meter power + per-phase
-- power + per-phase current are all negated at the boundary.

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "huawei",
  name         = "Huawei SUN2000 Hybrid Inverter",
  manufacturer = "Huawei",
  version      = "2.2.1",
  protocols    = { "modbus" },
  capabilities = { "meter", "pv", "battery" },
  read_only    = true,
  description  = "Huawei SUN2000 hybrid inverter telemetry with LUNA2000 battery via Modbus TCP. Read-only until a held-zero command is verified on hardware.",
  setup_hint   = "Ask your installer to set Modbus TCP on the SDongle to Enable (unrestricted) in FusionSolar.",
  homepage     = "https://solar.huawei.com",
  authors      = { "FTW contributors" },
  tested_models = { "SUN2000L1", "SUN2000-LUNA2000" },
  verification_status = "experimental",
  verification_notes = "Ported from a reference implementation. No model or firmware HIL record exists for the former control path. Its 0 W command wrote stop-forcible-mode, which releases the inverter to self-consumption instead of holding zero. Control stays disabled until a named SUN2000/LUNA2000 model and firmware prove held zero and a safe release.",
  connection_defaults = {
    port    = 502,
    unit_id = 1,
  },
}

PROTOCOL = "modbus"

local sn_read = false

-- True once energy storage unit 1 has reported a rated charge or discharge
-- power above 0 (37007/37009). Kept for the run, since a rating does not
-- change while the inverter runs; a restart reads it again.
local esu1_rated = false

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

-- Decode a 10-register ASCII string (20 bytes, big-endian packing).
-- Skips bytes outside printable ASCII.
local function decode_ascii(regs, n)
    local s = ""
    for i = 1, n do
        local hi = math.floor(regs[i] / 256)
        local lo = regs[i] % 256
        if hi > 32 and hi < 127 then s = s .. string.char(hi) end
        if lo > 32 and lo < 127 then s = s .. string.char(lo) end
    end
    return s
end

-- Registers this device has stopped answering.
--
-- The host counts every failed host.modbus_read against the poll whether or
-- not this driver caught the error — "driver_poll: N of M modbus reads
-- failed". So a register retried on every poll costs a failed poll on every
-- poll, and the stale-telemetry watchdog takes the driver offline. The site
-- then reports nothing at all, which is worse than reporting one field less.
--
-- Three attempts absorb a transient blip; after that we stop asking. A
-- restart re-probes, so firmware that gains the register is picked up.
--
-- The meter power register (37113) deliberately does NOT go through here:
-- when it fails the driver emits nothing at all, so it never claims the
-- device is fine while paying for a failed read. Giving up on it would
-- silence the driver for good after three transient blips instead of
-- letting it recover the moment the meter answers again.
local GIVE_UP_AFTER = 3
local read_failures = {}

local function probe_read(addr, count, kind)
    if (read_failures[addr] or 0) >= GIVE_UP_AFTER then return nil end
    local ok, regs = pcall(host.modbus_read, addr, count, kind)
    if ok and regs and regs[1] ~= nil then
        read_failures[addr] = nil
        return regs
    end
    local failures = (read_failures[addr] or 0) + 1
    read_failures[addr] = failures
    if failures == GIVE_UP_AFTER then
        host.log("info", string.format(
            "Huawei: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

-- What the battery can do now (docs/WRITING-A-DRIVER.md). A value outside
-- these bounds is a sentinel or a decoding slip, not a reading, so it is
-- left out rather than sent.
--
-- A temperature in tenths of a degree, as the register holds it. Compared
-- in tenths so -40.0 and 100.0 stay in on any float width.
local function temp_c_from_tenths(tenths)
    if tenths < -400 or tenths > 1000 then return nil end
    return tenths * 0.1
end

local function plausible_power_w(v)
    if v == nil or v ~= v or v < 0 or v > 100000 then return nil end
    return v
end

local function positive_w(v)
    local w = plausible_power_w(v)
    return w ~= nil and w > 0
end

----------------------------------------------------------------------------
-- Initialization
----------------------------------------------------------------------------

function driver_init(config)
    host.set_make("Huawei")
    host.log("info", "Huawei SUN2000: driver_init")
end

----------------------------------------------------------------------------
-- Telemetry polling
----------------------------------------------------------------------------

function driver_poll()
    -- Read serial number once (register 30015, 10 registers, ASCII).
    if not sn_read then
        local sn_regs = probe_read(30015, 10, "holding")
        if sn_regs then
            local sn = decode_ascii(sn_regs, 10)
            if string.len(sn) > 0 then
                host.set_sn(sn)
                sn_read = true
                host.log("info", "Huawei SUN2000: SN=" .. sn)
            end
        end
    end

    -- ---- PV ----

    -- PV1 V/A: 32016-32017, I16 × 0.1 V, I16 × 0.01 A
    local pv1_regs = probe_read(32016, 2, "holding")
    local pv1_v, pv1_a = 0, 0
    if pv1_regs then
        pv1_v = host.decode_i16(pv1_regs[1]) * 0.1
        pv1_a = host.decode_i16(pv1_regs[2]) * 0.01
    end

    -- PV2 V/A: 32018-32019, I16 × 0.1 V, I16 × 0.01 A
    local pv2_regs = probe_read(32018, 2, "holding")
    local pv2_v, pv2_a = 0, 0
    if pv2_regs then
        pv2_v = host.decode_i16(pv2_regs[1]) * 0.1
        pv2_a = host.decode_i16(pv2_regs[2]) * 0.01
    end

    -- Input power (PV total): 32064-32065, I32 BE × 0.001 kW → × 1000 for W
    local pvw_regs = probe_read(32064, 2, "holding")
    local pv_w = 0
    if pvw_regs then
        pv_w = host.decode_i32_be(pvw_regs[1], pvw_regs[2]) * 0.001 * 1000
    end

    -- Inverter internal temperature: 32087, I16 × 0.1 °C. Left out when the
    -- read fails: 0 °C is a reading, not a placeholder.
    local itemp_regs = probe_read(32087, 1, "holding")
    local inv_temp = nil
    if itemp_regs then
        inv_temp = temp_c_from_tenths(host.decode_i16(itemp_regs[1]))
    end

    -- PV lifetime yield: 32106-32107, U32 BE × 0.01 kWh → × 1000 for Wh
    local yield_regs = probe_read(32106, 2, "holding")
    local pv_gen_wh = 0
    if yield_regs then
        pv_gen_wh = host.decode_u32_be(yield_regs[1], yield_regs[2]) * 0.01 * 1000
    end

    -- ---- Battery ----

    -- Battery power: 37001-37002, I32 BE, watts
    -- Huawei sign: positive = charging, negative = discharging (matches site convention).
    local bw_regs = probe_read(37001, 2, "holding")
    local bat_w = 0
    if bw_regs then
        bat_w = host.decode_i32_be(bw_regs[1], bw_regs[2])
    end

    -- Battery bus voltage: 37003, U16 × 0.1 V
    local bv_regs = probe_read(37003, 1, "holding")
    local bat_v = 0
    if bv_regs then
        bat_v = bv_regs[1] * 0.1
    end

    -- Battery SoC: 37004, U16 × 0.1 percent (convert to 0-1 fraction).
    local bsoc_regs = probe_read(37004, 1, "holding")
    local bat_soc = 0
    if bsoc_regs then
        bat_soc = bsoc_regs[1] * 0.1 / 100
    end

    -- Battery current: 37021, I16 × 0.1 A
    local ba_regs = probe_read(37021, 1, "holding")
    local bat_a = 0
    if ba_regs then
        bat_a = host.decode_i16(ba_regs[1]) * 0.1
    end

    -- Is a battery fitted? A SUN2000 with no LUNA2000 may still answer the
    -- battery registers, with 0, so an answer alone proves nothing. Its
    -- temperature would then read 0 °C and its limits 0 W, "may not charge
    -- now". 37007-37008 "[Energy storage unit 1] Rated charge power" and
    -- 37009-37010 "Rated discharge power" (U32 BE, W) say whether a unit is
    -- there: a rating above 0 does. Until one is seen it is read on each poll
    -- the battery answers, so a pack found late is picked up.
    -- Only unit 1 is read, as for power and SoC above; a second unit
    -- (37700-37755) is not.
    if not esu1_rated and (bw_regs or bsoc_regs) then
        local rated_regs = probe_read(37007, 4, "holding")
        if rated_regs and rated_regs[4] ~= nil then
            esu1_rated =
                positive_w(host.decode_u32_be(rated_regs[1], rated_regs[2])) or
                positive_w(host.decode_u32_be(rated_regs[3], rated_regs[4]))
        end
    end

    -- Battery temperature: 37022, I16 × 0.1 °C, "[Energy storage unit 1]
    -- battery temperature" -- the LUNA2000's own value, not the inverter's.
    -- Left out when the read fails or no unit is fitted: 0 °C looks like a
    -- cold battery.
    -- Per-pack maximum and minimum temperatures are documented too
    -- (38452-38463, I16 × 0.1 °C, two per pack for three packs on each of two
    -- ESUs), but Huawei does not say what a pack slot with no pack answers,
    -- so they are not read: a 0 there would pass for a real cell reading.
    local bat_temp = nil
    if esu1_rated then
        local btemp_regs = probe_read(37022, 1, "holding")
        if btemp_regs then
            bat_temp = temp_c_from_tenths(host.decode_i16(btemp_regs[1]))
        end
    end

    -- What the battery may charge and discharge at now:
    -- 37046-37047 "[Energy storage] Maximum charge power" and 37048-37049
    -- "Maximum discharge power", U32 BE, W, read-only. Huawei defines each as
    -- the smaller of the inverter's and the connected ESU's charge/discharge
    -- capability, and keeps the ESU's rated charge/discharge power apart at
    -- 37007/37009. It does not say whether the value follows the BMS (for a
    -- cold or full pack), and no one has seen it move on hardware: it is the
    -- device's own limit, not shown to be live. If a site shows it flat while
    -- the battery is held back, it is a rating and does not belong in
    -- available_*.
    -- Read only when unit 1 is fitted (above), so a SUN2000 with no LUNA2000
    -- never reports "may not charge now" for a battery it does not have.
    local avail_charge_w, avail_discharge_w = nil, nil
    if esu1_rated then
        local lim_regs = probe_read(37046, 4, "holding")
        if lim_regs and lim_regs[2] ~= nil then
            avail_charge_w = plausible_power_w(
                host.decode_u32_be(lim_regs[1], lim_regs[2]))
        end
        if lim_regs and lim_regs[4] ~= nil then
            avail_discharge_w = plausible_power_w(
                host.decode_u32_be(lim_regs[3], lim_regs[4]))
        end
    end

    -- Battery charge/discharge lifetime energy: 37066-37069, U32 BE × 0.01 kWh pairs.
    local benergy_regs = probe_read(37066, 4, "holding")
    local bat_charge_wh, bat_discharge_wh = 0, 0
    if benergy_regs then
        bat_charge_wh    = host.decode_u32_be(benergy_regs[1], benergy_regs[2]) * 0.01 * 1000
        bat_discharge_wh = host.decode_u32_be(benergy_regs[3], benergy_regs[4]) * 0.01 * 1000
    end

    -- ---- Meter ----

    -- Per-phase voltage: 37101-37106, I32 BE × 0.1 pairs (L1 V, L2 V, L3 V)
    local lv_regs = probe_read(37101, 6, "holding")
    local l1_v, l2_v, l3_v = 0, 0, 0
    if lv_regs then
        l1_v = host.decode_i32_be(lv_regs[1], lv_regs[2]) * 0.1
        l2_v = host.decode_i32_be(lv_regs[3], lv_regs[4]) * 0.1
        l3_v = host.decode_i32_be(lv_regs[5], lv_regs[6]) * 0.1
    end

    -- Per-phase current: 37107-37112, I32 BE × 0.01 pairs (L1 A, L2 A, L3 A)
    local la_regs = probe_read(37107, 6, "holding")
    local l1_a, l2_a, l3_a = 0, 0, 0
    if la_regs then
        l1_a = host.decode_i32_be(la_regs[1], la_regs[2]) * 0.01
        l2_a = host.decode_i32_be(la_regs[3], la_regs[4]) * 0.01
        l3_a = host.decode_i32_be(la_regs[5], la_regs[6]) * 0.01
    end

    -- Meter total power: 37113-37114, I32 BE, watts.
    -- Huawei sign: positive = export, negative = import. Negate for site convention.
    -- If this read fails, skip ALL emits so the watchdog catches staleness —
    -- emitting PV/battery while meter is down would keep the driver "healthy"
    -- but give the control loop a stale grid reading.
    local ok_mw, mw_regs = pcall(host.modbus_read, 37113, 2, "holding")
    if not ok_mw or not mw_regs then
        host.log("warn", "Huawei: meter power read failed, skipping all emits")
        return 5000
    end
    local meter_w = host.decode_i32_be(mw_regs[1], mw_regs[2])

    -- Grid frequency: 37118, I16 × 0.01 Hz
    local hz_regs = probe_read(37118, 1, "holding")
    local hz = 0
    if hz_regs then
        hz = host.decode_i16(hz_regs[1]) * 0.01
    end

    -- Export/Import lifetime energy: 37119-37122, I32 BE × 0.01 kWh pairs
    local energy_regs = probe_read(37119, 4, "holding")
    local export_wh, import_wh = 0, 0
    if energy_regs then
        export_wh = host.decode_i32_be(energy_regs[1], energy_regs[2]) * 0.01 * 1000
        import_wh = host.decode_i32_be(energy_regs[3], energy_regs[4]) * 0.01 * 1000
    end

    -- Per-phase power: 37132-37137, I32 BE pairs, watts (Huawei sign).
    local lpw_regs = probe_read(37132, 6, "holding")
    local l1_w, l2_w, l3_w = 0, 0, 0
    if lpw_regs then
        l1_w = host.decode_i32_be(lpw_regs[1], lpw_regs[2])
        l2_w = host.decode_i32_be(lpw_regs[3], lpw_regs[4])
        l3_w = host.decode_i32_be(lpw_regs[5], lpw_regs[6])
    end

    -- ---- All reads succeeded — emit everything ----

    -- PV telemetry (site convention: generation is negative).
    host.emit("pv", {
        w           = -pv_w,
        mppt1_v     = pv1_v,
        mppt1_a     = pv1_a,
        mppt2_v     = pv2_v,
        mppt2_a     = pv2_a,
        lifetime_wh = pv_gen_wh,
        temp_c      = inv_temp,
    })
    host.emit_metric("pv_mppt1_v",      pv1_v)
    host.emit_metric("pv_mppt1_a",      pv1_a)
    host.emit_metric("pv_mppt2_v",      pv2_v)
    host.emit_metric("pv_mppt2_a",      pv2_a)
    if inv_temp ~= nil then
        host.emit_metric("inverter_temp_c", inv_temp)
    end

    -- Battery telemetry. A field set to nil is left out of the table.
    host.emit("battery", {
        w                     = bat_w,
        v                     = bat_v,
        a                     = bat_a,
        soc                   = bat_soc,
        temp_c                = bat_temp,
        charge_wh             = bat_charge_wh,
        discharge_wh          = bat_discharge_wh,
        available_charge_W    = avail_charge_w,
        available_discharge_W = avail_discharge_w,
    })
    host.emit_metric("battery_dc_v",    bat_v)
    host.emit_metric("battery_dc_a",    bat_a)
    if bat_temp ~= nil then
        host.emit_metric("battery_temp_c", bat_temp)
    end
    if avail_charge_w ~= nil then
        host.emit_metric("battery_available_charge_w", avail_charge_w)
    end
    if avail_discharge_w ~= nil then
        host.emit_metric("battery_available_discharge_w", avail_discharge_w)
    end

    -- Negate meter power + per-phase power + per-phase current to site convention
    -- (positive = import from grid).
    host.emit("meter", {
        w         = -meter_w,
        l1_w      = -l1_w,
        l2_w      = -l2_w,
        l3_w      = -l3_w,
        l1_v      = l1_v,
        l2_v      = l2_v,
        l3_v      = l3_v,
        l1_a      = -l1_a,
        l2_a      = -l2_a,
        l3_a      = -l3_a,
        hz        = hz,
        import_wh = import_wh,
        export_wh = export_wh,
    })
    host.emit_metric("meter_l1_w", -l1_w)
    host.emit_metric("meter_l2_w", -l2_w)
    host.emit_metric("meter_l3_w", -l3_w)
    host.emit_metric("meter_l1_v", l1_v)
    host.emit_metric("meter_l2_v", l2_v)
    host.emit_metric("meter_l3_v", l3_v)
    host.emit_metric("meter_l1_a", -l1_a)
    host.emit_metric("meter_l2_a", -l2_a)
    host.emit_metric("meter_l3_a", -l3_a)
    host.emit_metric("grid_hz",    hz)

    return 5000
end

----------------------------------------------------------------------------
-- Read-only boundary
----------------------------------------------------------------------------

-- A 0 W Huawei forcible command is a release to the inverter's native
-- self-consumption mode, not a held battery setpoint. Core uses 0 W as an
-- enforceable hold, so exposing the former write path made an idle/export slot
-- look controlled while the inverter could still absorb PV on its own.
-- Keep every command inert until a real SUN2000/LUNA2000 rig proves a distinct
-- held-zero sequence and its safe default.
function driver_command(_action, _power_w, _cmd)
    return false
end

function driver_default_mode()
    -- Read-only: the driver never took control, so there is nothing to release.
end

function driver_cleanup()
    sn_read = false
    esu1_rated = false
end
