-- Growatt Hybrid Inverter Driver
-- Emits: PV, Battery, Meter (READ-ONLY)
-- Protocol: Modbus TCP, INPUT registers (FC 0x04), Big-Endian word order
--
-- Ported from sourceful-hugin/device-support/drivers/lua/growatt.lua
-- for FTW Lua host v2.1.
--
-- Sign convention (site convention — positive W = INTO the site):
--   pv.w:       always negative (generation)
--   battery.w:  positive = charging, negative = discharging
--   meter.w:    positive = import from grid, negative = export
--
-- Growatt reports separate charge / discharge power registers; we
-- combine them into a signed site-convention value at the boundary.
-- The native meter register is already positive=import, so it maps
-- to site convention without a flip.

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "growatt",
  name         = "Growatt hybrid inverter",
  manufacturer = "Growatt",
  version      = "2.2.2",
  protocols    = { "modbus" },
  capabilities = { "meter", "pv", "battery" },
  read_only    = true,
  description  = "Growatt SPH / MOD hybrid inverters via Modbus TCP.",
  homepage     = "https://www.growatt.com",
  authors      = { "FTW contributors" },
  tested_models = { "SPH", "MOD" },
  verification_status = "experimental",
  verification_notes = "Ported from a reference implementation. Not yet verified against live hardware on a FTW site.",
  connection_defaults = {
    port    = 502,
    unit_id = 1,
  },
}

PROTOCOL = "modbus"

----------------------------------------------------------------------------
-- Absent registers
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
            "Growatt: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

----------------------------------------------------------------------------
-- What the battery can do now (docs/WRITING-A-DRIVER.md)
--
-- Growatt Modbus RTU Protocol II V1.39, input registers (the SPH addresses
-- match homeassistant-solax-modbus and Growatt-Local-Modbus):
--   93    Temp1, inverter temperature          0.1 C (all families)
--   1040  battery temperature                  0.1 C (SPA/SPH)
--   1114  uwMaxTemprCell_10T, max cell temp    0.1 C (SPA/SPH BMS block)
--   1115  uwMinTemprCell_10T, min cell temp    0.1 C
-- The BMS block has one BMS_MaxCurr (1090) for charge and discharge
-- together, and the protocol gives it no unit, so this driver reports no
-- available_* figures.
----------------------------------------------------------------------------

-- A temperature outside -40..100 C is a sentinel or a misread, so it is
-- dropped, never clamped.
local function plausible_temp(c)
    if c == nil or c ~= c then return nil end
    if c < -40 or c > 100 then return nil end
    return c
end

-- A read that answered with every register asked for, or nil. A shorter
-- reply would leave a missing word for the decoders to misread.
local function read_input(addr, count)
    local regs = probe_read(addr, count, "input")
    if regs and regs[count] ~= nil then return regs end
    return nil
end

----------------------------------------------------------------------------
-- Initialization
----------------------------------------------------------------------------

function driver_init(config)
    host.set_make("Growatt")
    host.log("info", "Growatt: driver_init")
end

----------------------------------------------------------------------------
-- Telemetry polling
----------------------------------------------------------------------------

function driver_poll()
    -- A read that failed is left out, never sent as 0 (docs/WRITING-A-DRIVER.md,
    -- "Never fabricate"): 0 W looks like a site in balance, 0 % SoC like an
    -- empty pack. Each field comes only from a read that answered with every
    -- register asked for, and PV and meter go out only with their power.

    -- ---- PV ----

    local pv = {}

    -- PV total power: 1-2, U32 BE × 0.1 W
    local pvw_regs = read_input(1, 2)
    if pvw_regs then
        pv.w = -host.decode_u32_be(pvw_regs[1], pvw_regs[2]) * 0.1   -- generation is negative
    end

    -- PV1 V/A: 3-4, U16 × 0.1 V, U16 × 0.1 A
    local m1_regs = read_input(3, 2)
    if m1_regs then
        pv.mppt1_v = m1_regs[1] * 0.1
        pv.mppt1_a = m1_regs[2] * 0.1
    end

    -- PV2 V/A: 7-8, U16 × 0.1 V, U16 × 0.1 A
    local m2_regs = read_input(7, 2)
    if m2_regs then
        pv.mppt2_v = m2_regs[1] * 0.1
        pv.mppt2_a = m2_regs[2] * 0.1
    end

    -- Grid frequency: 37, U16 × 0.01 Hz
    local hz_regs = read_input(37, 1)
    local hz
    if hz_regs then
        hz = hz_regs[1] * 0.01
        host.emit_metric("grid_hz", hz)
    end

    -- Total PV lifetime energy: 91-92, U32 BE × 0.1 kWh → × 1000 for Wh
    local pvgen_regs = read_input(91, 2)
    if pvgen_regs then
        pv.lifetime_wh = host.decode_u32_be(pvgen_regs[1], pvgen_regs[2]) * 0.1 * 1000
    end

    if pv.w ~= nil then host.emit("pv", pv) end
    for _, name in ipairs({ "mppt1_v", "mppt1_a", "mppt2_v", "mppt2_a" }) do
        if pv[name] ~= nil then host.emit_metric("pv_" .. name, pv[name]) end
    end

    -- ---- Battery ----

    -- Growatt Modbus RTU Protocol II V1.39 puts discharge first:
    --   1009-1010  Pdischarge1  discharge power, U32 BE × 0.1 W
    --   1011-1012  Pcharge1     charge power,    U32 BE × 0.1 W
    -- Growatt-Local-Modbus maps them the same way. Up to 2.2.0 this driver
    -- read them the other way round and showed charging as discharging
    -- (srcfl/device-drivers#263).
    local bdisw_regs = read_input(1009, 2)
    local bat_discharge_w
    if bdisw_regs then
        bat_discharge_w = host.decode_u32_be(bdisw_regs[1], bdisw_regs[2]) * 0.1
    end

    local bchgw_regs = read_input(1011, 2)
    local bat_charge_w
    if bchgw_regs then
        bat_charge_w = host.decode_u32_be(bchgw_regs[1], bchgw_regs[2]) * 0.1
    end

    -- Battery voltage: 1013, U16 × 0.1 V
    local bv_regs = read_input(1013, 1)
    local bat_v
    if bv_regs then bat_v = bv_regs[1] * 0.1 end

    -- Battery SoC: 1014, U16, percent → 0-1 fraction
    local bsoc_regs = read_input(1014, 1)
    local bat_soc
    if bsoc_regs then bat_soc = bsoc_regs[1] / 100 end

    -- Battery temperature: 1040, U16 × 0.1 °C
    local btemp_regs = read_input(1040, 1)
    local bat_temp
    if btemp_regs then
        bat_temp = plausible_temp(btemp_regs[1] * 0.1)
    end

    -- A PV-only Growatt (no battery connected) still answers the battery
    -- registers with 0, which made FTW render a phantom "Battery" node on
    -- Overview even though no battery exists. A real battery reports a
    -- terminal voltage and/or SoC above 0 even at rest, so treat all-zero
    -- battery readings as "no battery present" and skip the emit.
    --   see srcfl/ftw#1669
    -- Only a read that answered can show a battery (docs/WRITING-A-DRIVER.md,
    -- "A hybrid inverter may have no battery").
    local function above_zero(v) return v ~= nil and v > 0 end
    local has_battery = above_zero(bat_v) or above_zero(bat_soc)
        or above_zero(bat_charge_w) or above_zero(bat_discharge_w)
    if has_battery then
        local battery = { v = bat_v, soc = bat_soc, temp_c = bat_temp }
        -- Net power needs both registers: either alone is not the net.
        -- Positive = charging, negative = discharging (site convention).
        if bat_charge_w ~= nil and bat_discharge_w ~= nil then
            battery.w = bat_charge_w - bat_discharge_w
        end
        host.emit("battery", battery)
        if bat_v ~= nil then
            host.emit_metric("battery_dc_v", bat_v)
        end
        if bat_temp ~= nil then
            host.emit_metric("battery_temp_c", bat_temp)
        end

        -- Max / min cell temperature from the BMS: 1114-1115, U16 × 0.1 °C.
        local cell_regs = read_input(1114, 2)
        if cell_regs then
            local cell_max = plausible_temp(cell_regs[1] * 0.1)
            local cell_min = plausible_temp(cell_regs[2] * 0.1)
            if cell_max ~= nil then
                host.emit_metric("battery_cell_temp_max_c", cell_max)
            end
            if cell_min ~= nil then
                host.emit_metric("battery_cell_temp_min_c", cell_min)
            end
        end
    end

    -- Inverter temperature: 93, U16 × 0.1 °C
    local itemp_regs = read_input(93, 1)
    if itemp_regs then
        local inv_temp = plausible_temp(itemp_regs[1] * 0.1)
        if inv_temp ~= nil then
            host.emit_metric("inverter_temp_c", inv_temp)
        end
    end

    -- ---- Meter ----
    -- Which registers these should be is srcfl/device-drivers#271; this
    -- release only stops a failed read from becoming 0.

    local meter = { hz = hz }

    -- Meter total power: 1015-1016, I32 BE × 0.1 W
    -- Growatt sign: positive = import (matches site convention).
    local mw_regs = read_input(1015, 2)
    if mw_regs then
        meter.w = host.decode_i32_be(mw_regs[1], mw_regs[2]) * 0.1
    end

    -- Per-phase voltages: L1=38, L2=42, L3=46, U16 × 0.1 V
    -- Per-phase currents: L1=39, L2=43, L3=47, U16 × 0.1 A
    for phase, addr in ipairs({ 38, 42, 46 }) do
        local v_regs = read_input(addr, 1)
        if v_regs then meter["l" .. phase .. "_v"] = v_regs[1] * 0.1 end
        local a_regs = read_input(addr + 1, 1)
        if a_regs then meter["l" .. phase .. "_a"] = a_regs[1] * 0.1 end
    end

    -- Total import energy: 1021-1022, U32 BE × 0.1 kWh → × 1000 for Wh
    local imp_regs = read_input(1021, 2)
    if imp_regs then
        meter.import_wh = host.decode_u32_be(imp_regs[1], imp_regs[2]) * 0.1 * 1000
    end

    -- Total export energy: 1029-1030, U32 BE × 0.1 kWh → × 1000 for Wh
    local exp_regs = read_input(1029, 2)
    if exp_regs then
        meter.export_wh = host.decode_u32_be(exp_regs[1], exp_regs[2]) * 0.1 * 1000
    end

    if meter.w ~= nil then host.emit("meter", meter) end
    for phase = 1, 3 do
        for _, unit in ipairs({ "v", "a" }) do
            local name = "l" .. phase .. "_" .. unit
            if meter[name] ~= nil then host.emit_metric("meter_" .. name, meter[name]) end
        end
    end

    return 5000
end

----------------------------------------------------------------------------
-- Control (read-only driver — no battery control implemented)
----------------------------------------------------------------------------

-- Read-only driver: control is not implemented. Returning false lets the
-- control loop register the no-op without flooding the log — the EMS
-- sends a battery dispatch every tick even when power_w = 0.
function driver_command(action, power_w, cmd)
    return false
end

function driver_default_mode()
    -- Read-only driver: device manages itself autonomously.
end

function driver_cleanup()
    -- Nothing to clean up.
end
