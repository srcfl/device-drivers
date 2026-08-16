-- ferroamp_modbus.lua
-- Ferroamp EnergyHub Modbus TCP driver (alternative transport to drivers/ferroamp.lua)
-- Emits: PV, Battery, Meter telemetry
-- Ported from sourceful-hugin/device-support/drivers/lua/ferroamp_modbus.lua
-- Port notes (FTW v2.1 API drift vs hugin):
--   host.log(msg)                 → host.log("info", msg)
--   host.decode_f32               → inline IEEE-754 (decode_f32_be, word-swap helper)
--
-- Port: 502, Unit ID: 1 (default)
-- Float format: IEEE 754, word-swapped (low word at lower address)
-- Register map: Ferroamp proprietary (not SunSpec)
--
-- Sign convention (site/EMS):
--   meter.w  : positive = importing from grid, negative = exporting
--   pv.w     : always <= 0 (generation)
--   battery.w: positive = charging (into battery), negative = discharging
--   Ferroamp reports battery power as positive = discharging, so we negate
--   at the driver boundary to match drivers/ferroamp.lua (the MQTT variant).

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "ferroamp-modbus",
  name         = "Ferroamp EnergyHub (Modbus)",
  manufacturer = "Ferroamp",
  version      = "2.1.2",
  protocols    = { "modbus" },
  capabilities = { "meter", "pv", "battery" },
  read_only    = true,
  description  = "Read-only Ferroamp EnergyHub XL telemetry over Modbus TCP. Use the MQTT driver for battery control.",
  homepage     = "https://ferroamp.com",
  authors      = { "FTW contributors" },
  tested_models = { "EnergyHub XL" },
  verification_status = "experimental",
  verification_notes = "Ported from sourceful-hugin. No EnergyHub firmware HIL record exists for the former Modbus control path. Its 0 W command selected auto mode instead of holding zero. Control stays on the hardware-verified MQTT driver until a named model and firmware prove a held-zero Modbus command and safe release.",
  connection_defaults = {
    port    = 502,
    unit_id = 1,
  },
}

PROTOCOL = "modbus"

----------------------------------------------------------------------------
-- Local decoders / encoders
----------------------------------------------------------------------------

-- Decode IEEE 754 single-precision float from two u16 registers,
-- big-endian word order: hi = first register, lo = second.
-- Returns 0 for NaN / ±Inf (treated as "not implemented" sentinels).
local function decode_f32_be(hi, lo)
    hi = hi % 0x10000
    lo = lo % 0x10000
    local bits = hi * 0x10000 + lo
    if bits == 0 then return 0 end
    local sign = 1
    if bits >= 0x80000000 then
        sign = -1
        bits = bits - 0x80000000
    end
    local exp = math.floor(bits / 0x800000)
    local frac = bits % 0x800000
    if exp == 0xFF then return 0 end   -- NaN / Inf → not present
    if exp == 0 then
        return sign * frac / 0x800000 * (2 ^ -126)
    end
    return sign * (1 + frac / 0x800000) * (2 ^ (exp - 127))
end

-- Decode a word-swapped float32 from a register block at offset idx.
-- Ferroamp stores the low word at the lower address; our decoder expects
-- (hi, lo), so we swap here. `regs` is the 1-indexed table returned by
-- host.modbus_read, `idx` is the position of the LOW word.
local function decode_f32_ws_at(regs, idx)
    if not regs then return 0 end
    local lo = regs[idx]
    local hi = regs[idx + 1]
    if lo == nil or hi == nil then return 0 end
    return decode_f32_be(hi, lo)
end

----------------------------------------------------------------------------
-- Bounded reads
----------------------------------------------------------------------------

-- A register the EnergyHub never answers costs a failed read on every poll for
-- as long as the driver keeps asking. The host counts those failures against
-- the poll whether or not the pcall caught them, so a driver that keeps
-- reporting telemetry while permanently failing one read gets the whole site
-- marked offline. Give a register three chances, then leave it alone until
-- restart. Three rather than one: a single failure is not proof, the link may
-- just have been slow.
--
-- Only the poll path goes through here. driver_command writes, it never reads,
-- so a poll-time give-up can never veto a battery or curtail setpoint.
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
            "Ferroamp Modbus: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

----------------------------------------------------------------------------
-- Driver interface
----------------------------------------------------------------------------

function driver_init(config)
    host.set_make("Ferroamp")
    -- Ferroamp EnergyHub does not expose its serial on a stable Modbus
    -- register, so device_id resolves via ARP MAC (preferred) or the
    -- configured endpoint. No set_sn here.
    host.log("info", "Ferroamp Modbus: init complete (Unit ID 1, port 502)")
end

function driver_poll()
    --------------------------------------------------------------------------
    -- Meter (grid connection point)
    --------------------------------------------------------------------------

    -- Grid frequency: input 2016, float32, Hz (2 regs, word-swapped)
    local hz_regs = probe_read(2016, 2, "input")
    local hz = 0
    if hz_regs then hz = decode_f32_ws_at(hz_regs, 1) end

    -- Grid voltage L1/L2/L3: input 2032/2036/2040, float32, Vrms.
    -- Each value occupies 4 regs (2 f32 + 2 unused), so read 10 regs for 3 values.
    local v_regs = probe_read(2032, 10, "input")
    local l1_v, l2_v, l3_v = 0, 0, 0
    if v_regs then
        l1_v = decode_f32_ws_at(v_regs, 1)   -- 2032-2033
        l2_v = decode_f32_ws_at(v_regs, 5)   -- 2036-2037
        l3_v = decode_f32_ws_at(v_regs, 9)   -- 2040-2041
    end

    -- Grid active power (total): input 3100, float32, kW
    local gw_regs = probe_read(3100, 2, "input")
    local grid_w = 0
    if gw_regs then grid_w = decode_f32_ws_at(gw_regs, 1) * 1000 end

    -- Grid active current L1/L2/L3: input 3112/3116/3120, float32, Arms
    local ga_regs = probe_read(3112, 10, "input")
    local l1_a, l2_a, l3_a = 0, 0, 0
    if ga_regs then
        l1_a = decode_f32_ws_at(ga_regs, 1)   -- 3112-3113
        l2_a = decode_f32_ws_at(ga_regs, 5)   -- 3116-3117
        l3_a = decode_f32_ws_at(ga_regs, 9)   -- 3120-3121
    end

    -- Per-phase power: V * I_active (no per-phase power registers available)
    local l1_w = l1_v * l1_a
    local l2_w = l2_v * l2_a
    local l3_w = l3_v * l3_a

    -- Grid energy: export at 3064, import at 3068, float32, kWh (8 regs, two values)
    local ge_regs = probe_read(3064, 8, "input")
    local export_wh, import_wh = 0, 0
    if ge_regs then
        export_wh = decode_f32_ws_at(ge_regs, 1) * 1000   -- 3064-3065
        import_wh = decode_f32_ws_at(ge_regs, 5) * 1000   -- 3068-3069
    end

    host.emit("meter", {
        w         = grid_w,
        hz        = hz,
        l1_w      = l1_w,
        l2_w      = l2_w,
        l3_w      = l3_w,
        l1_v      = l1_v,
        l2_v      = l2_v,
        l3_v      = l3_v,
        l1_a      = l1_a,
        l2_a      = l2_a,
        l3_a      = l3_a,
        import_wh = import_wh,
        export_wh = export_wh,
    })
    -- Diagnostics: long-format TS DB
    host.emit_metric("meter_l1_w", l1_w)
    host.emit_metric("meter_l2_w", l2_w)
    host.emit_metric("meter_l3_w", l3_w)
    host.emit_metric("meter_l1_v", l1_v)
    host.emit_metric("meter_l2_v", l2_v)
    host.emit_metric("meter_l3_v", l3_v)
    host.emit_metric("meter_l1_a", l1_a)
    host.emit_metric("meter_l2_a", l2_a)
    host.emit_metric("meter_l3_a", l3_a)
    host.emit_metric("grid_hz",    hz)

    --------------------------------------------------------------------------
    -- PV (solar generation)
    --------------------------------------------------------------------------

    -- Solar power: input 5100, float32, kW (always positive from Ferroamp)
    local pv_regs = probe_read(5100, 2, "input")
    local pv_w = 0
    if pv_regs then pv_w = decode_f32_ws_at(pv_regs, 1) * 1000 end

    -- Solar energy produced: input 5064, float32, kWh
    local pe_regs = probe_read(5064, 2, "input")
    local pv_lifetime_wh = 0
    if pe_regs then pv_lifetime_wh = decode_f32_ws_at(pe_regs, 1) * 1000 end

    host.emit("pv", {
        w           = -pv_w,   -- negative = generation (site convention)
        lifetime_wh = pv_lifetime_wh,
    })

    --------------------------------------------------------------------------
    -- Battery
    --------------------------------------------------------------------------

    -- Battery power: input 6100, float32, kW.
    -- Ferroamp: positive = discharging. Site convention: positive = charging.
    -- Negate and convert kW → W (matches drivers/ferroamp.lua's sign handling).
    local bw_regs = probe_read(6100, 2, "input")
    local bat_w = 0
    if bw_regs then bat_w = -decode_f32_ws_at(bw_regs, 1) * 1000 end

    -- Battery SoC: input 6016, float32, percent → 0-1 fraction
    local soc_regs = probe_read(6016, 2, "input")
    local bat_soc = nil
    if soc_regs then bat_soc = decode_f32_ws_at(soc_regs, 1) / 100 end

    -- Battery energy: discharge at 6064, charge at 6068, float32, kWh (8 regs).
    -- Read as input registers; driver_command writes holding 6064 for the power
    -- setpoint, which is a different function code and a separate path.
    local be_regs = probe_read(6064, 8, "input")
    local bat_discharge_wh, bat_charge_wh = 0, 0
    if be_regs then
        bat_discharge_wh = decode_f32_ws_at(be_regs, 1) * 1000   -- 6064-6065
        bat_charge_wh    = decode_f32_ws_at(be_regs, 5) * 1000   -- 6068-6069
    end

    -- Omit soc from the emit table when the read failed — emitting 0
    -- would cause the control loop to think the battery is empty.
    local bat_data = {
        w            = bat_w,
        charge_wh    = bat_charge_wh,
        discharge_wh = bat_discharge_wh,
    }
    if bat_soc ~= nil then bat_data.soc = bat_soc end
    host.emit("battery", bat_data)

    return 5000
end

----------------------------------------------------------------------------
-- Read-only boundary
----------------------------------------------------------------------------

-- The Modbus write map has not passed HIL acceptance, and its former 0 W path
-- selected auto mode instead of holding the battery at zero. That violates
-- Core's battery command contract. Keep this transport strictly telemetry-only;
-- the Ferroamp MQTT driver owns the verified control path.
function driver_command(_action, _power_w, _cmd)
    return false
end

function driver_default_mode()
    -- Read-only: the driver never took control, so there is nothing to release.
end

function driver_cleanup()
end
