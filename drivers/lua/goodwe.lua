-- GoodWe ET-Plus / EH Hybrid Inverter Driver
-- Emits: PV, Battery, Meter
-- Protocol: Modbus TCP (port 502)
--
-- Register type: HOLDING (FC 0x03)
-- Byte/word order: Big-Endian for multi-register values
-- Written for: ET-Plus, EH (GoodWe's ET platform, the 35000 register map).
-- Not checked on hardware yet. ES, EM and BP inverters speak another
-- protocol and are not covered.
-- READ-ONLY: control not implemented.

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "goodwe",
  name         = "GoodWe hybrid inverter",
  manufacturer = "GoodWe",
  version      = "2.3.0",
  protocols    = { "modbus" },
  capabilities = { "meter", "pv", "battery" },
  read_only    = true,
  description  = "GoodWe ET-Plus / EH series hybrid inverters via Modbus TCP.",
  homepage     = "https://en.goodwe.com",
  authors      = { "FTW contributors" },
  tested_models = { "ET-Plus", "EH series" },
  verification_status = "experimental",
  verification_notes = "Ported from a reference implementation. Not yet verified against live hardware on a FTW site.",
  connection_defaults = {
    port    = 502,
    unit_id = 1,
  },
}

PROTOCOL = "modbus"

----------------------------------------------------------------------------
-- Register probing
----------------------------------------------------------------------------

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
            "GoodWe: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

----------------------------------------------------------------------------
-- Register map
--
-- Addresses, types and scales from GoodWe's own map, "GoodWe Modbus
-- Protocol Hybrid for Energy Storage Inverters" (2 February 2024, in the
-- manifest's upstream_docs). evcc's goodwe-hybrid template and the goodwe
-- library (et.py) read the same registers. Neither document states a sign
-- in words; both integrations treat battery discharge and meter export as
-- positive (evcc scales meter power by -1 and passes battery power through
-- as "positive = discharging"; the goodwe library's house consumption adds
-- battery power and subtracts meter power). The driver turns both round at
-- the boundary.
--
-- Inverter block, read as the goodwe library does from 35100:
--   35103-35118  PV1..PV4: voltage U16 x 0.1 V, current U16 x 0.1 A,
--                power U32 W (35105, 35109, 35113, 35117)
--   35123        R phase frequency, U16 x 0.01 Hz
--   35176        heat sink temperature, S16 x 0.1 C
--   35180        battery 1 voltage, U16 x 0.1 V (the BMS's value when it
--                talks to the inverter)
--   35181        battery 1 current, S16 x 0.1 A
--   35182-35183  battery 1 power, S32 W
--   35184        battery 1 mode: 0 no battery or disconnected, 1 standby,
--                2 discharging, 3 charging (Table 8-9)
--   35191-35192  PV energy total, U32 x 0.1 kWh
-- Meter block, from the meter the inverter reads (36000 and up):
--   36004        meter communication, 1 OK, 0 failed
--   36014        meter frequency, U16 x 0.01 Hz
--   36015-36016  total energy sold to the grid, float32 Wh
--   36017-36018  total energy bought from the grid, float32 Wh
--   36019-36024  meter power per phase, S32 W
--   36025-36026  meter total power, S32 W
--   36052-36057  meter voltage per phase U16 x 0.1 V, then current per
--                phase U16 x 0.1 A
-- The float32 energy unit is not in GoodWe's table; evcc and the goodwe
-- library both divide by 1000 for kWh, so the raw value is Wh.
--
-- Earlier releases read most of these from the wrong place
-- (srcfl/device-drivers#264): battery power from 35180 (the voltage),
-- battery voltage and current from 35178/35179 (the BUS and NBUS voltages),
-- SoC from 35182, total PV from 35105 alone scaled by 0.1, PV2 from 35109,
-- grid frequency from 35113 (PV3 power), and the meter from the inverter's
-- own phase registers at 35121-35141.
--
-- Known limits, left for a field report:
--   * GoodWe's table says to read 36019-36041 when the ARM firmware is
--     above version 9, and the older 36005-36008 (S16) before that. The
--     driver reads the newer ones, as evcc does for every ET model, and
--     does not read the firmware version.
--   * 36052-36057 are listed in GoodWe's February 2024 table. The goodwe
--     library reads them only on newer units, so on an older one the read
--     may fail; it is given up after three tries and the rest of the meter
--     still reports.
--   * evcc notes that 36017 reads 0 on some newer models (ETA-G20).
--
-- What the battery can do now (docs/WRITING-A-DRIVER.md):
--   37000-37023  "BMS Operation Data", read as one block like the
--                goodwe library does
--     37003      BMS pack temperature            x 0.1 C
--     37004      max BMS charge current          A
--     37005      max BMS discharge current       A
--     37007      SoC of battery 1                %
--     37011      battery protocol, the codes of GoodWe's Table 8-33:
--                0x101 Pylontech, 0x102/0x105/0x106 BYD, 0x104 LG,
--                0x11E Dyness and others, 0x122 GoodWe. 0x11F, "EMS
--                Battery", means the inverter has no direct link to the
--                battery, and 0 means no protocol at all.
--     37020      max cell temperature            x 0.1 C
--     37021      min cell temperature            x 0.1 C
-- The charge and discharge currents come from the BMS, so they move with
-- temperature and charge level: a live limit, not a rating.
--
-- A battery mode other than 0 says a battery is there, not that a BMS
-- talks to the inverter. Without one the block answers zeros, and 0 C,
-- 0 W and 0 % would read as a cold, empty battery that may not charge. So
-- the block's figures, SoC included, count only while 37011 names a BMS
-- protocol (not 0, 0x11F or 0xFFFF). A 0 A limit from a BMS that does talk
-- is sent as 0 W.
----------------------------------------------------------------------------

-- A temperature outside -40..100 C or a power outside 0..100 kW is a
-- sentinel or a misread, so it is dropped, never clamped.
local function plausible_temp(c)
    if c == nil or c ~= c then return nil end
    if c < -40 or c > 100 then return nil end
    return c
end

local function plausible_power(w)
    if w == nil or w ~= w then return nil end
    if w < 0 or w > 100000 then return nil end
    return w
end

-- GoodWe temperatures are tenths of a degree. 0xFFFF and 0x7FFF mean "no
-- value" (the goodwe library drops both), and 0xFFFF would otherwise pass
-- as -0.1 C.
local function goodwe_temp(raw)
    if raw == nil or raw == 0xFFFF or raw == 0x7FFF then return nil end
    return plausible_temp(host.decode_i16(raw) * 0.1)
end

-- Watts the BMS allows now: its current limit times the battery voltage of
-- this poll. Without a fresh voltage there is no figure.
local function limit_w(amps, volts)
    if amps == nil or volts == nil or volts <= 0 then return nil end
    return plausible_power(amps * volts)
end

-- True when 37011 names a BMS the inverter talks to (Table 8-33).
local GOODWE_NO_DIRECT_BMS = 0x11F
local function bms_talks(protocol)
    return protocol ~= nil and protocol ~= 0 and protocol ~= 0xFFFF
        and protocol ~= GOODWE_NO_DIRECT_BMS
end

-- Unsigned and signed 32-bit values from two registers, high word first.
-- Both work on the 16-bit halves, so the sign survives a Lua build with
-- 32-bit integers (docs/WRITING-A-DRIVER.md, "Numbers").
local function u32(hi, lo)
    return (hi % 0x10000) * 0x10000 + (lo % 0x10000)
end

local function s32(hi, lo)
    hi = hi % 0x10000
    lo = lo % 0x10000
    if hi >= 0x8000 then
        return (hi - 0x10000) * 0x10000 + lo
    end
    return hi * 0x10000 + lo
end

-- IEEE 754 float32, high word first, on the 16-bit halves. NaN and
-- infinity mean "no value" and give nil.
local function f32(hi, lo)
    hi = hi % 0x10000
    lo = lo % 0x10000
    local sign = 1
    if hi >= 0x8000 then sign = -1; hi = hi - 0x8000 end
    local exponent = math.floor(hi / 128)
    local mantissa = (hi % 128) * 65536 + lo
    if exponent == 0xFF then return nil end
    if exponent == 0 then return sign * mantissa * 2 ^ -149 end
    return sign * (1 + mantissa / 0x800000) * 2 ^ (exponent - 127)
end

-- A lifetime energy counter in Wh, or nil when it is not a count.
local function energy_wh(hi, lo)
    local wh = f32(hi, lo)
    if wh == nil or wh < 0 then return nil end
    return wh
end

-- 0xFFFF in a meter voltage or current means "no value" (evcc decodes
-- these registers as uint16 with that sentinel).
local function tenths(raw)
    if raw == nil or raw == 0xFFFF then return nil end
    return raw * 0.1
end

----------------------------------------------------------------------------
-- Initialization
----------------------------------------------------------------------------

function driver_init(config)
    host.set_make("GoodWe")
end

----------------------------------------------------------------------------
-- Telemetry polling
--
-- A stream goes out only when its defining read answered, and each field
-- only from a register that answered (docs/WRITING-A-DRIVER.md, "Never
-- fabricate").
----------------------------------------------------------------------------

local function poll_pv()
    -- 35103-35123 in one read: four MPPTs, PV mode, then the R phase.
    local regs = probe_read(35103, 21, "holding")
    if not regs or regs[21] == nil then return end

    local pv_w = u32(regs[3], regs[4]) + u32(regs[7], regs[8])
        + u32(regs[11], regs[12]) + u32(regs[15], regs[16])
    local mppt1_v, mppt1_a = regs[1] * 0.1, regs[2] * 0.1
    local mppt2_v, mppt2_a = regs[5] * 0.1, regs[6] * 0.1
    local hz = regs[21] * 0.01

    local lifetime_wh = nil
    local energy = probe_read(35191, 2, "holding")
    if energy and energy[2] ~= nil then
        lifetime_wh = u32(energy[1], energy[2]) * 100       -- 0.1 kWh
    end

    host.emit("pv", {
        w           = -pv_w,  -- negative = generation (site convention)
        mppt1_v     = mppt1_v,
        mppt1_a     = mppt1_a,
        mppt2_v     = mppt2_v,
        mppt2_a     = mppt2_a,
        lifetime_wh = lifetime_wh,
    })
    host.emit_metric("pv_mppt1_v", mppt1_v)
    host.emit_metric("pv_mppt1_a", mppt1_a)
    host.emit_metric("pv_mppt2_v", mppt2_v)
    host.emit_metric("pv_mppt2_a", mppt2_a)
    host.emit_metric("grid_hz",    hz)
end

local function poll_battery()
    -- 35180-35184: voltage, current, power (two words), mode.
    local regs = probe_read(35180, 5, "holding")
    if not regs or regs[5] == nil then return end
    local mode = regs[5]
    if mode == 0 then return end      -- no battery, or disconnected

    local volts = regs[1] * 0.1
    -- GoodWe counts discharge as positive; the site counts charge as
    -- positive. The current carries the same sign as the power, since the
    -- voltage is never negative.
    local amps = -host.decode_i16(regs[2]) * 0.1
    local battery = {
        w = -s32(regs[3], regs[4]),
        v = volts,
        a = amps,
    }

    local bms_regs = probe_read(37000, 24, "holding")
    if bms_regs and bms_regs[24] == nil then bms_regs = nil end
    if bms_regs and not bms_talks(bms_regs[12]) then          -- 37011
        bms_regs = nil
    end

    if bms_regs then
        battery.soc = bms_regs[8] / 100                       -- 37007

        local bat_temp = goodwe_temp(bms_regs[4])            -- 37003
        if bat_temp ~= nil then
            battery.temp_c = bat_temp
            host.emit_metric("battery_temp_c", bat_temp)
        end

        local charge_w = limit_w(bms_regs[5], volts)          -- 37004
        if charge_w ~= nil then
            battery.available_charge_W = charge_w
            host.emit_metric("battery_charge_limit_a", bms_regs[5])
            host.emit_metric("battery_available_charge_w", charge_w)
        end

        local discharge_w = limit_w(bms_regs[6], volts)       -- 37005
        if discharge_w ~= nil then
            battery.available_discharge_W = discharge_w
            host.emit_metric("battery_discharge_limit_a", bms_regs[6])
            host.emit_metric("battery_available_discharge_w", discharge_w)
        end

        local cell_max = goodwe_temp(bms_regs[21])           -- 37020
        if cell_max ~= nil then
            host.emit_metric("battery_cell_temp_max_c", cell_max)
        end
        local cell_min = goodwe_temp(bms_regs[22])           -- 37021
        if cell_min ~= nil then
            host.emit_metric("battery_cell_temp_min_c", cell_min)
        end
    end

    host.emit("battery", battery)
    host.emit_metric("battery_dc_v", volts)
    host.emit_metric("battery_dc_a", amps)
end

local function poll_meter()
    -- 36004-36026 in one read. Without the meter (36004 not 1) the
    -- inverter has no grid reading to give, so no meter is sent.
    local regs = probe_read(36004, 23, "holding")
    if not regs or regs[23] == nil then return end
    if regs[1] ~= 1 then return end

    -- GoodWe counts export as positive; the site counts import as positive.
    local l1_w = -s32(regs[16], regs[17])                     -- 36019
    local l2_w = -s32(regs[18], regs[19])                     -- 36021
    local l3_w = -s32(regs[20], regs[21])                     -- 36023
    local meter = {
        w         = -s32(regs[22], regs[23]),                 -- 36025
        l1_w      = l1_w,
        l2_w      = l2_w,
        l3_w      = l3_w,
        hz        = regs[11] * 0.01,                          -- 36014
        export_wh = energy_wh(regs[12], regs[13]),            -- 36015
        import_wh = energy_wh(regs[14], regs[15]),            -- 36017
    }
    host.emit_metric("meter_l1_w", l1_w)
    host.emit_metric("meter_l2_w", l2_w)
    host.emit_metric("meter_l3_w", l3_w)

    local va = probe_read(36052, 6, "holding")
    if va and va[6] ~= nil then
        meter.l1_v, meter.l2_v, meter.l3_v = tenths(va[1]), tenths(va[2]), tenths(va[3])
        meter.l1_a, meter.l2_a, meter.l3_a = tenths(va[4]), tenths(va[5]), tenths(va[6])
        for _, key in ipairs({"l1_v", "l2_v", "l3_v", "l1_a", "l2_a", "l3_a"}) do
            if meter[key] ~= nil then host.emit_metric("meter_" .. key, meter[key]) end
        end
    end

    host.emit("meter", meter)
end

function driver_poll()
    poll_pv()
    poll_battery()

    -- Inverter heat sink temperature: 35176, S16 x 0.1 C.
    local itemp_regs = probe_read(35176, 1, "holding")
    if itemp_regs then
        local inv_temp = goodwe_temp(itemp_regs[1])
        if inv_temp ~= nil then
            host.emit_metric("inverter_temp_c", inv_temp)
        end
    end

    poll_meter()
    return 5000
end

----------------------------------------------------------------------------
-- Control (read-only driver — not implemented)
----------------------------------------------------------------------------

function driver_command(action, power_w, cmd)
    if action == "init" then
        return true
    end
    host.log("warn", "GoodWe: control not implemented (action=" .. tostring(action) .. ")")
    return false
end

function driver_default_mode()
    -- Read-only driver: nothing to revert.
end

function driver_cleanup()
    -- Read-only driver: nothing to clean up.
end
