-- Kostal Plenticore / Piko IQ hybrid inverter driver (SunSpec)
-- Emits: PV, Battery, Meter
-- Protocol: Modbus TCP, port 1502 (Kostal default), holding registers (FC 0x03)
-- Reference: Kostal SunSpec map. SunSpec is big-endian for u32 values.
-- READ-ONLY: no battery / curtail control.

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "kostal",
  name         = "Kostal Plenticore",
  manufacturer = "Kostal",
  version      = "2.2.0",
  protocols    = { "modbus" },
  capabilities = { "meter", "pv", "battery" },
  read_only    = true,
  description  = "Kostal Plenticore Plus and Piko IQ via Modbus TCP (SunSpec plus Kostal custom map).",
  homepage     = "https://www.kostal-solar-electric.com",
  authors      = { "FTW contributors" },
  tested_models = { "Plenticore Plus", "Piko IQ" },
  verification_status = "experimental",
  verification_notes = "Ported from a reference implementation. Not yet verified against live hardware on a FTW site.",
  connection_defaults = {
    port    = 502,
    unit_id = 1,
  },
}

PROTOCOL = "modbus"

----------------------------------------------------------------------------
-- SunSpec helpers (inline — the FTW host has no host.scale / host.decode_f32)
----------------------------------------------------------------------------

-- Apply a SunSpec signed scale factor: result = value * 10^sf.
-- sf is a small int16 (typical range -4..+4). Negative sf divides.
local function apply_sf(v, sf)
    if sf >= 0 then return v * (10 ^ sf) end
    return v / (10 ^ -sf)
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
            "Kostal: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

-- Read a single holding register as signed i16 (e.g. scale factors).
-- Returns the decoded value, or the default if the read fails.
local function read_i16(addr, default)
    local regs = probe_read(addr, 1, "holding")
    if regs then
        return host.decode_i16(regs[1])
    end
    return default
end

-- Read a single holding register as unsigned u16.
local function read_u16(addr, default)
    local regs = probe_read(addr, 1, "holding")
    if regs then
        return regs[1]
    end
    return default
end

-- Read a u32 big-endian pair (SunSpec standard word order).
local function read_u32_be(addr, default)
    local regs = probe_read(addr, 2, "holding")
    if regs and regs[2] then
        return host.decode_u32_be(regs[1], regs[2])
    end
    return default
end

----------------------------------------------------------------------------
-- What the battery can do now
--
-- From KOSTAL's own register table, "PIKO IQ/PLENTICORE KOSTAL Interface
-- description MODBUS (TCP) & SunSpec with control information", revision
-- 2.10 (12.11.2026). These are KOSTAL's registers, not SunSpec ones, and the
-- addresses are the ones sent on the wire.
--
--   0x05   (5)     MODBUS Byte Order, U16: 0 = little-endian (CDAB, the
--                  default), 1 = big-endian (ABCD). It decides how the two
--                  words of every Float below are ordered.
--   0x24C  (588)   Battery type, U16 (U32 from firmware 3.07.03):
--                  0 = "No battery (PV-Functionality)".
--   0xD6   (214)   Battery temperature, Float, °C, read-only.
--   0x434  (1076)  Maximum charge power limit (read-out from battery),
--                  Float, W, read-only.
--   0x436  (1078)  Maximum discharge power limit (read-out from battery),
--                  Float, W, read-only.
--
-- 0x434/0x436 are the only limits KOSTAL marks as read from the battery.
-- 0x40E/0x410 and 0x500/0x502 next to them are limits an external EMS
-- writes, so they are not what the battery can do. KOSTAL does not say how
-- often 0x434/0x436 refresh or what sign they carry; a negative value falls
-- outside 0..100 kW and is left out. KOSTAL documents no cell temperatures
-- and no grid import/export headroom.
----------------------------------------------------------------------------

local REG_BYTE_ORDER     = 5
local REG_BATTERY_TYPE   = 588
local REG_BATTERY_TEMP   = 214
local REG_BATTERY_LIMITS = 1076

-- nil until register 5 has answered; then true for CDAB, false for ABCD.
local float_low_word_first = nil
-- nil until register 588 has answered.
local battery_present = nil

-- IEEE-754 float32 from two 16-bit words, high word first, or nil for NaN
-- and infinity. Works on the halves so a 32-bit Lua build cannot flip the
-- sign (docs/WRITING-A-DRIVER.md, "Numbers").
local function f32_from_words(hi, lo)
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

-- The Float at regs[i], regs[i + 1] in the order register 5 reported.
local function kostal_float(regs, i)
    if float_low_word_first == nil or not regs then return nil end
    local first, second = regs[i], regs[i + 1]
    if first == nil or second == nil then return nil end
    if float_low_word_first then return f32_from_words(second, first) end
    return f32_from_words(first, second)
end

-- A value outside these bounds is a sentinel or a decoding slip, not a
-- reading, so it is left out rather than sent.
local function plausible_temp_c(v)
    if v == nil or v ~= v or v < -40 or v > 100 then return nil end
    return v
end

local function plausible_power_w(v)
    if v == nil or v ~= v or v < 0 or v > 100000 then return nil end
    return v
end

-- Learn the word order and whether a battery is fitted. Both are settings,
-- so each is read until it answers once (bounded by probe_read) and kept
-- for the run; a restart reads them again.
local function learn_battery_setup()
    if float_low_word_first == nil then
        local regs = probe_read(REG_BYTE_ORDER, 1, "holding")
        if regs then
            if regs[1] == 0 then float_low_word_first = true
            elseif regs[1] == 1 then float_low_word_first = false end
        end
    end
    if battery_present == nil then
        -- One word only. Older firmware has a U16 here. On 3.07.03 and later
        -- it is a U32: with the default CDAB order the first word is the low
        -- one, which holds every type code but M-TEC's. With ABCD it is the
        -- high word, 0 for those types, so the battery reads as absent and
        -- its fields are left out rather than guessed.
        local regs = probe_read(REG_BATTERY_TYPE, 1, "holding")
        if regs then battery_present = (regs[1] ~= 0) end
    end
end

----------------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------------

local sn_read = false

function driver_init(config)
    host.set_make("Kostal")
    host.log("info", "Kostal: initialised, SunSpec Modbus TCP (holding registers)")
end

function driver_poll()
    -- -----------------------------------------------------------------
    -- Serial number (SunSpec Common Model 1: SN at regs 40052-40067,
    -- 16 regs = 32 chars ASCII. NOTE: 40004-40019 is Md (manufacturer),
    -- 40020-40035 is Opt (model string) — NOT serial number.)
    -- -----------------------------------------------------------------
    if not sn_read then
        local sn_regs = probe_read(40052, 16, "holding")
        if sn_regs then
            local sn = ""
            for i = 1, 16 do
                local hi = math.floor(sn_regs[i] / 256)
                local lo = sn_regs[i] % 256
                if hi > 32 and hi < 127 then sn = sn .. string.char(hi) end
                if lo > 32 and lo < 127 then sn = sn .. string.char(lo) end
            end
            if string.len(sn) > 0 then
                host.set_sn(sn)
                sn_read = true
            end
        end
    end

    -- -----------------------------------------------------------------
    -- Scale factors (SunSpec inverter model 103)
    -- -----------------------------------------------------------------
    local ac_power_sf = read_i16(40084, 0)  -- AC power SF
    local hz_sf       = read_i16(40086, 0)  -- Hz SF
    local energy_sf   = read_i16(40095, 0)  -- Lifetime energy SF
    local temp_sf     = read_i16(40106, nil)  -- Heatsink temp SF

    -- MPPT scale factors (SunSpec model 160, base 40253)
    local mppt_a_sf   = read_i16(40255, 0)  -- DCA_SF (+2 from base)
    local mppt_v_sf   = read_i16(40256, 0)  -- DCV_SF (+3 from base)

    -- -----------------------------------------------------------------
    -- PV (SunSpec inverter model 103)
    -- -----------------------------------------------------------------
    local ac_w_raw = read_i16(40083, 0)
    local ac_w     = apply_sf(ac_w_raw, ac_power_sf)

    local hz_raw = read_u16(40085, 0)
    local hz     = apply_sf(hz_raw, hz_sf)

    local lifetime_raw = read_u32_be(40093, 0)
    local lifetime_wh  = apply_sf(lifetime_raw, energy_sf)

    -- Inverter temperature: value and scale factor both have to answer, and
    -- -32768 (0x8000) is SunSpec's "not implemented". Left out otherwise:
    -- 0 °C is a reading, not a placeholder.
    local temp_raw = read_i16(40103, nil)
    local temp_c   = nil
    if temp_raw ~= nil and temp_sf ~= nil
        and temp_raw ~= -32768 and temp_sf ~= -32768 then
        temp_c = plausible_temp_c(apply_sf(temp_raw, temp_sf))
    end

    -- MPPT1: module 1 current @ 40260, voltage @ 40261
    local mppt1_a = apply_sf(read_u16(40260, 0), mppt_a_sf)
    local mppt1_v = apply_sf(read_u16(40261, 0), mppt_v_sf)

    -- MPPT2: module 2 current @ 40280, voltage @ 40281
    local mppt2_a = apply_sf(read_u16(40280, 0), mppt_a_sf)
    local mppt2_v = apply_sf(read_u16(40281, 0), mppt_v_sf)

    -- PV emit: w is always negative (generation leaves the array)
    host.emit("pv", {
        w           = -ac_w,
        mppt1_v     = mppt1_v,
        mppt1_a     = mppt1_a,
        mppt2_v     = mppt2_v,
        mppt2_a     = mppt2_a,
        lifetime_wh = lifetime_wh,
        temp_c      = temp_c,
    })
    host.emit_metric("pv_mppt1_v",      mppt1_v)
    host.emit_metric("pv_mppt1_a",      mppt1_a)
    host.emit_metric("pv_mppt2_v",      mppt2_v)
    host.emit_metric("pv_mppt2_a",      mppt2_a)
    if temp_c ~= nil then
        host.emit_metric("inverter_temp_c", temp_c)
    end
    host.emit_metric("grid_hz",         hz)

    -- -----------------------------------------------------------------
    -- Battery (SunSpec storage model 124 — Kostal custom offsets)
    -- -----------------------------------------------------------------
    -- SoC @ 40137, %; battery power @ 40138, i16 W (+ = charge, - = discharge)
    local bat_soc_raw = read_u16(40137, 0)
    local bat_soc     = bat_soc_raw / 100.0    -- percent → 0-1 fraction

    local bat_w = 0
    local bw_regs = probe_read(40138, 1, "holding")
    if bw_regs then
        -- Kostal reports battery power with EMS-compatible sign already:
        -- positive = charging, negative = discharging.
        bat_w = host.decode_i16(bw_regs[1])
    end

    -- What the battery can do now; see the register list near the top.
    -- Each field is left out when its read fails, when the word order is
    -- not yet known, or when no battery is fitted.
    learn_battery_setup()
    local bat_temp, avail_charge_w, avail_discharge_w = nil, nil, nil
    if battery_present and float_low_word_first ~= nil then
        bat_temp = plausible_temp_c(kostal_float(
            probe_read(REG_BATTERY_TEMP, 2, "holding"), 1))
        local lim_regs = probe_read(REG_BATTERY_LIMITS, 4, "holding")
        avail_charge_w    = plausible_power_w(kostal_float(lim_regs, 1))
        avail_discharge_w = plausible_power_w(kostal_float(lim_regs, 3))
    end

    host.emit("battery", {
        w                     = bat_w,
        soc                   = bat_soc,
        temperature_C         = bat_temp,
        available_charge_W    = avail_charge_w,
        available_discharge_W = avail_discharge_w,
    })
    if bat_temp ~= nil then
        host.emit_metric("battery_temp_c", bat_temp)
    end
    if avail_charge_w ~= nil then
        host.emit_metric("battery_available_charge_w", avail_charge_w)
    end
    if avail_discharge_w ~= nil then
        host.emit_metric("battery_available_discharge_w", avail_discharge_w)
    end

    -- -----------------------------------------------------------------
    -- Meter (SunSpec meter model 203 — Kostal custom offsets)
    -- -----------------------------------------------------------------
    local meter_w_sf      = read_i16(40210, 0)  -- total W SF (also phase W SF)
    local meter_a_sf      = read_i16(40194, 0)  -- per-phase A SF
    local meter_v_sf      = read_i16(40203, 0)  -- per-phase V SF
    local meter_energy_sf = read_i16(40242, 0)  -- meter energy SF

    -- Total grid power: 40100, I16 (Kostal reports meter W at inverter 40100)
    local meter_w_raw = read_i16(40100, 0)
    -- SunSpec convention at this map negates vs site convention (+ = export).
    -- Flip to site convention: + = import, - = export.
    local meter_w = -apply_sf(meter_w_raw, meter_w_sf)

    -- Per-phase current: 40191-40193, I16
    local l1_a, l2_a, l3_a = 0, 0, 0
    local la_regs = probe_read(40191, 3, "holding")
    if la_regs then
        l1_a = -apply_sf(host.decode_i16(la_regs[1]), meter_a_sf)
        l2_a = -apply_sf(host.decode_i16(la_regs[2]), meter_a_sf)
        l3_a = -apply_sf(host.decode_i16(la_regs[3]), meter_a_sf)
    end

    -- Per-phase voltage: 40196-40198, I16
    local l1_v, l2_v, l3_v = 0, 0, 0
    local lv_regs = probe_read(40196, 3, "holding")
    if lv_regs then
        l1_v = apply_sf(host.decode_i16(lv_regs[1]), meter_v_sf)
        l2_v = apply_sf(host.decode_i16(lv_regs[2]), meter_v_sf)
        l3_v = apply_sf(host.decode_i16(lv_regs[3]), meter_v_sf)
    end

    -- Per-phase power: 40207-40209, I16
    local l1_w, l2_w, l3_w = 0, 0, 0
    local lw_regs = probe_read(40207, 3, "holding")
    if lw_regs then
        l1_w = -apply_sf(host.decode_i16(lw_regs[1]), meter_w_sf)
        l2_w = -apply_sf(host.decode_i16(lw_regs[2]), meter_w_sf)
        l3_w = -apply_sf(host.decode_i16(lw_regs[3]), meter_w_sf)
    end

    -- Energy counters: 40226-40227 export, 40234-40235 import, U32 BE
    local export_wh = apply_sf(read_u32_be(40226, 0), meter_energy_sf)
    local import_wh = apply_sf(read_u32_be(40234, 0), meter_energy_sf)

    host.emit("meter", {
        w         = meter_w,
        l1_w      = l1_w,
        l2_w      = l2_w,
        l3_w      = l3_w,
        l1_v      = l1_v,
        l2_v      = l2_v,
        l3_v      = l3_v,
        l1_a      = l1_a,
        l2_a      = l2_a,
        l3_a      = l3_a,
        hz        = hz,
        import_wh = import_wh,
        export_wh = export_wh,
    })
    host.emit_metric("meter_l1_w", l1_w)
    host.emit_metric("meter_l2_w", l2_w)
    host.emit_metric("meter_l3_w", l3_w)
    host.emit_metric("meter_l1_v", l1_v)
    host.emit_metric("meter_l2_v", l2_v)
    host.emit_metric("meter_l3_v", l3_v)
    host.emit_metric("meter_l1_a", l1_a)
    host.emit_metric("meter_l2_a", l2_a)
    host.emit_metric("meter_l3_a", l3_a)

    return 5000
end

----------------------------------------------------------------------------
-- Control (READ-ONLY for this driver — Kostal write map is tier-locked)
----------------------------------------------------------------------------

function driver_command(action, power_w, cmd)
    -- Read-only driver: accept "init" (EMS handshake) and ignore the rest.
    if action == "init" then
        return true
    end
    return false
end

function driver_default_mode()
    -- Read-only driver — device stays in its own autonomous mode.
end

function driver_cleanup()
    float_low_word_first = nil
    battery_present = nil
end
