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
  id           = "ferroamp_modbus",
  name         = "Ferroamp EnergyHub (Modbus)",
  manufacturer = "Ferroamp",
  version      = "2.2.2",
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
-- Returns nil for NaN / ±Inf, which the EnergyHub uses for "not present":
-- the field is left out, never sent as 0 (docs/WRITING-A-DRIVER.md,
-- "Never fabricate"). Up to 2.2.1 they decoded as 0.
--
-- Works on the 16-bit halves (docs/WRITING-A-DRIVER.md, "Numbers"). The
-- earlier version built the 32-bit word and compared it with 0x80000000,
-- which is negative where Lua integers are 32 bits, so every float decoded
-- wrong there. FTW and Blixt L1 use wider numbers and were not affected.
local function decode_f32_be(hi, lo)
    hi = hi % 0x10000
    lo = lo % 0x10000
    local sign = 1
    if hi >= 0x8000 then
        sign = -1
        hi = hi - 0x8000
    end
    local exp = math.floor(hi / 0x80)
    local frac = (hi % 0x80) * 0x10000 + lo
    if exp == 0 and frac == 0 then return 0 end
    if exp == 0xFF then return nil end   -- NaN / Inf → not present
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
    if not regs then return nil end
    local lo = regs[idx]
    local hi = regs[idx + 1]
    if lo == nil or hi == nil then return nil end
    return decode_f32_be(hi, lo)
end

-- The float at idx times scale, or nil when a word is missing or the value
-- is NaN or infinite. Checked again after scaling: float32's largest value
-- times 1000 is infinite where Lua numbers are 32-bit floats
-- (docs/WRITING-A-DRIVER.md, "Numbers").
local function f32_at(regs, idx, scale)
    local v = decode_f32_ws_at(regs, idx)
    if v == nil then return nil end
    v = v * scale
    if v ~= v or v == math.huge or v == -math.huge then return nil end
    return v
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

-- A reply shorter than the read did not deliver every register asked for.
local function complete(regs, count)
    return regs ~= nil and regs[count] ~= nil
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

    -- Each field comes only from a register that answered, and the meter
    -- reading only with the grid power (docs/WRITING-A-DRIVER.md, "Never
    -- fabricate"). A failed read used to send 0: a 0 W meter looks like a
    -- site in balance. What did answer still goes to history as a metric.
    local meter = {}

    -- Grid frequency: input 2016, float32, Hz (2 regs, word-swapped)
    local hz_regs = probe_read(2016, 2, "input")
    if complete(hz_regs, 2) then
        meter.hz = f32_at(hz_regs, 1, 1)
        if meter.hz ~= nil then host.emit_metric("grid_hz", meter.hz) end
    end

    -- Grid voltage L1/L2/L3: input 2032/2036/2040, float32, Vrms.
    -- Each value occupies 4 regs (2 f32 + 2 unused), so read 10 regs for 3 values.
    local v_regs = probe_read(2032, 10, "input")
    if complete(v_regs, 10) then
        meter.l1_v = f32_at(v_regs, 1, 1)   -- 2032-2033
        meter.l2_v = f32_at(v_regs, 5, 1)   -- 2036-2037
        meter.l3_v = f32_at(v_regs, 9, 1)   -- 2040-2041
    end

    -- Grid active power (total): input 3100, float32, kW
    local gw_regs = probe_read(3100, 2, "input")
    if complete(gw_regs, 2) then meter.w = f32_at(gw_regs, 1, 1000) end

    -- Grid active current L1/L2/L3: input 3112/3116/3120, float32, Arms
    local ga_regs = probe_read(3112, 10, "input")
    if complete(ga_regs, 10) then
        meter.l1_a = f32_at(ga_regs, 1, 1)   -- 3112-3113
        meter.l2_a = f32_at(ga_regs, 5, 1)   -- 3116-3117
        meter.l3_a = f32_at(ga_regs, 9, 1)   -- 3120-3121
    end

    -- Per-phase power: V * I_active (no per-phase power registers available),
    -- only when both answered.
    for _, phase in ipairs({ "l1", "l2", "l3" }) do
        local v, a = meter[phase .. "_v"], meter[phase .. "_a"]
        if v ~= nil and a ~= nil then meter[phase .. "_w"] = v * a end
    end

    -- Grid energy: export at 3064, import at 3068, float32, kWh (8 regs, two values)
    local ge_regs = probe_read(3064, 8, "input")
    if complete(ge_regs, 8) then
        meter.export_wh = f32_at(ge_regs, 1, 1000)   -- 3064-3065
        meter.import_wh = f32_at(ge_regs, 5, 1000)   -- 3068-3069
    end

    if meter.w ~= nil then host.emit("meter", meter) end

    -- Diagnostics: long-format TS DB
    for _, phase in ipairs({ "l1", "l2", "l3" }) do
        for _, unit in ipairs({ "w", "v", "a" }) do
            local value = meter[phase .. "_" .. unit]
            if value ~= nil then host.emit_metric("meter_" .. phase .. "_" .. unit, value) end
        end
    end

    --------------------------------------------------------------------------
    -- PV (solar generation)
    --------------------------------------------------------------------------

    -- Solar power: input 5100, float32, kW (always positive from Ferroamp).
    -- Without it there is no PV reading.
    local pv_regs = probe_read(5100, 2, "input")
    local pv_w = complete(pv_regs, 2) and f32_at(pv_regs, 1, 1000) or nil
    if pv_w ~= nil then
        local pv = {}
        pv.w = -pv_w   -- negative = generation

        -- Solar energy produced: input 5064, float32, kWh
        local pe_regs = probe_read(5064, 2, "input")
        if complete(pe_regs, 2) then pv.lifetime_wh = f32_at(pe_regs, 1, 1000) end

        host.emit("pv", pv)
    end

    --------------------------------------------------------------------------
    -- Battery
    --------------------------------------------------------------------------

    -- Each field comes only from a register that answered. A failed read is
    -- left out, never sent as 0: 0 W looks like an idle pack, 0 % SoC like an
    -- empty one, and a 0 Wh counter like a reset.
    --
    -- Ferroamp's Modbus map (Modbus TCP Revision D, 2024-06-03) has no
    -- battery temperature, no live charge or discharge limit and no inverter
    -- temperature, so this driver reports none. Its import and export
    -- thresholds (8002, 8012) are settings someone wrote, not limits the
    -- device sets.
    local bat_data = {}

    -- Battery power: input 6100, float32, kW.
    -- Ferroamp: positive = discharging. Site convention: positive = charging.
    -- Negate and convert kW → W (matches drivers/ferroamp.lua's sign handling).
    local bw_regs = probe_read(6100, 2, "input")
    local bat_w = f32_at(bw_regs, 1, 1000)
    if bat_w ~= nil then bat_data.w = -bat_w end

    -- Battery SoC: input 6016, float32, percent → 0-1 fraction
    local soc_regs = probe_read(6016, 2, "input")
    local soc_pct = f32_at(soc_regs, 1, 1)
    if soc_pct ~= nil then bat_data.soc = soc_pct / 100 end

    -- Battery energy: discharge at 6064, charge at 6068, float32, kWh (8 regs).
    -- Read as input registers; driver_command writes holding 6064 for the power
    -- setpoint, which is a different function code and a separate path.
    local be_regs = probe_read(6064, 8, "input")
    bat_data.discharge_wh = f32_at(be_regs, 1, 1000)   -- 6064-6065
    bat_data.charge_wh    = f32_at(be_regs, 5, 1000)   -- 6068-6069

    -- Send whatever answered (docs/WRITING-A-DRIVER.md, "A hybrid inverter
    -- may have no battery"): a failed power read must not also drop a good
    -- SoC or energy count. With nothing answered there is no battery reading.
    if next(bat_data) ~= nil then host.emit("battery", bat_data) end

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
