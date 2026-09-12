-- fronius_smart_meter.lua
-- Fronius Smart Meter (three-phase energy meter) driver
-- Emits: Meter (read-only)
-- Protocol: Modbus TCP (SunSpec), ALL HOLDING registers, F32 BE throughout
-- Ported from sourceful-hugin/device-support/drivers/lua/fronius_smart_meter.lua
-- Port notes (v2.1 API drift vs hugin):
--   host.log(msg)           → host.log("info", msg)
--   host.decode_u32/i32     → _be variants
--   host.decode_f32         → inline IEEE-754 (two u16, big-endian words)

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "fronius-smart-meter",
  name         = "Fronius Smart Meter",
  manufacturer = "Fronius",
  version      = "2.1.2",
  protocols    = { "modbus" },
  capabilities = { "meter" },
  read_only    = true,
  description  = "Fronius Smart Meter three-phase energy meter via Modbus TCP (SunSpec).",
  homepage     = "https://www.fronius.com",
  authors      = { "FTW contributors" },
  tested_models = { "Smart Meter 50kA-3", "Smart Meter 63A-3", "Smart Meter TS 65A-3" },
  verification_status = "experimental",
  verification_notes = "Ported from a reference implementation. Not yet verified against live hardware on a FTW site.",
  connection_defaults = {
    port    = 502,
    unit_id = 1,
  },
}
--
-- Register map (all HOLDING, all SunSpec F32 BE pairs — hi word first):
--   40074/40076/40078 — per-phase current (A)
--   40082/40084/40086 — per-phase voltage (V)
--   40096             — grid frequency (Hz)
--   40098             — total AC power (W)  positive = importing from grid
--   40100/40102/40104 — per-phase power (W)
--   40130             — total export energy (Wh)  lifetime counter
--   40138             — total import energy (Wh)  lifetime counter
--
-- Sign convention (site/EMS):
--   meter.w  : positive = importing from grid, negative = exporting
-- Fronius Smart Meter already reports import-positive, no flip needed.
--
-- This driver complements drivers/fronius.lua (inverter). Mark the meter
-- entry in config.yaml as `is_site_meter: true` when it's the household
-- grid-connection meter.

PROTOCOL = "modbus"

----------------------------------------------------------------------------
-- Local decoder (replaces host.decode_f32 from hugin v1.x)
----------------------------------------------------------------------------

-- Decode IEEE 754 single-precision float from two u16 registers,
-- big-endian word order: hi = first register, lo = second.
-- Returns 0 for NaN / ±Inf (SunSpec "not implemented" sentinel is 0x7FC00000).
local function decode_f32_be(hi, lo)
    hi = hi % 0x10000
    lo = lo % 0x10000
    local bits = hi * 0x10000 + lo
    local sign = 1
    if bits >= 0x80000000 then
        sign = -1
        bits = bits - 0x80000000
    end
    local exp = math.floor(bits / 0x800000)
    local frac = bits % 0x800000
    if exp == 0xFF then
        return 0  -- NaN or Inf → treat as not-present
    end
    local value
    if exp == 0 then
        -- Subnormal (or zero)
        value = frac / 0x800000 * (2 ^ -126)
    else
        value = (1 + frac / 0x800000) * (2 ^ (exp - 127))
    end
    return sign * value
end

----------------------------------------------------------------------------
-- Bounded register probe
----------------------------------------------------------------------------

-- The host counts every failed host.modbus_read against the poll, even one
-- pcall caught here. A driver that keeps emitting while a register keeps
-- failing is marked offline by the stale-telemetry watchdog, and the site
-- then reports nothing at all. So: three tries, then leave the register
-- alone. Three rather than one because a single failure is not proof the
-- register is missing -- the link may just have been slow.
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
            "Fronius Smart Meter: register %d did not answer %d times; " ..
            "leaving it alone until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

-- Helper: read a contiguous F32 BE pair at `addr` and return the decoded
-- float. On Modbus error / give-up, returns nil so callers can omit the
-- field or skip the emit rather than publishing a fabricated 0 W.
local function read_f32(addr)
    local regs = probe_read(addr, 2, "holding")
    if regs then
        return decode_f32_be(regs[1], regs[2])
    end
    return nil
end

----------------------------------------------------------------------------
-- Initialization
----------------------------------------------------------------------------

function driver_init(config)
    host.set_make("Fronius")
    -- Smart Meter has no accessible serial block; set_sn is skipped.
    -- device_id falls back to mac:<arp> or ep:<endpoint>.
end

----------------------------------------------------------------------------
-- Telemetry polling
----------------------------------------------------------------------------

function driver_poll()
    -- Total AC power (W) — Fronius: positive = import, matches site convention.
    -- Without it there is no trustworthy site-meter reading; do not emit a
    -- fabricated 0 W after the register has been given up.
    local total_w = read_f32(40098)
    if total_w == nil then
        return 5000
    end

    -- Optional phase / energy fields: omit nil rather than coercing to 0.
    local l1_a = read_f32(40074)
    local l2_a = read_f32(40076)
    local l3_a = read_f32(40078)
    local l1_v = read_f32(40082)
    local l2_v = read_f32(40084)
    local l3_v = read_f32(40086)
    local hz = read_f32(40096)
    local l1_w = read_f32(40100)
    local l2_w = read_f32(40102)
    local l3_w = read_f32(40104)
    local export_wh = read_f32(40130)
    local import_wh = read_f32(40138)

    local meter = { w = total_w }
    if l1_w ~= nil then meter.l1_w = l1_w end
    if l2_w ~= nil then meter.l2_w = l2_w end
    if l3_w ~= nil then meter.l3_w = l3_w end
    if l1_v ~= nil then meter.l1_v = l1_v end
    if l2_v ~= nil then meter.l2_v = l2_v end
    if l3_v ~= nil then meter.l3_v = l3_v end
    if l1_a ~= nil then meter.l1_a = l1_a end
    if l2_a ~= nil then meter.l2_a = l2_a end
    if l3_a ~= nil then meter.l3_a = l3_a end
    if hz ~= nil then meter.hz = hz end
    if import_wh ~= nil then meter.import_wh = import_wh end
    if export_wh ~= nil then meter.export_wh = export_wh end

    host.emit("meter", meter)
    if l1_w ~= nil then host.emit_metric("meter_l1_w", l1_w) end
    if l2_w ~= nil then host.emit_metric("meter_l2_w", l2_w) end
    if l3_w ~= nil then host.emit_metric("meter_l3_w", l3_w) end
    if l1_v ~= nil then host.emit_metric("meter_l1_v", l1_v) end
    if l2_v ~= nil then host.emit_metric("meter_l2_v", l2_v) end
    if l3_v ~= nil then host.emit_metric("meter_l3_v", l3_v) end
    if l1_a ~= nil then host.emit_metric("meter_l1_a", l1_a) end
    if l2_a ~= nil then host.emit_metric("meter_l2_a", l2_a) end
    if l3_a ~= nil then host.emit_metric("meter_l3_a", l3_a) end
    if hz ~= nil then host.emit_metric("grid_hz", hz) end

    return 5000
end

----------------------------------------------------------------------------
-- Control (READ-ONLY — meter exposes no writable registers)
----------------------------------------------------------------------------

function driver_command(action, power_w, cmd)
    if action == "init" or action == "deinit" then
        return true
    end
    host.log("warn", "Fronius Smart Meter: read-only driver, ignoring action=" .. tostring(action))
    return false
end

function driver_default_mode()
    -- Read-only: nothing to revert.
end

function driver_cleanup()
    -- No cached state to clear.
end
