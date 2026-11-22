-- SolaX X1/X3 Hybrid Series Inverter Driver
-- Emits: PV, Battery, Meter
-- Register type: INPUT (FC 0x04)
-- Byte order: Big-Endian for multi-register values
-- Port: 502
-- Community tier (untested)

-- No control code has been written for this inverter yet: driver_command
-- only refuses. It says read_only so FTW and the catalog tell the owner
-- plainly, instead of offering control that cannot work.
DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "solax",
  name         = "SolaX X1/X3 inverter",
  manufacturer = "SolaX",
  version      = "1.2.0",
  protocols    = { "modbus" },
  capabilities = { "pv", "battery", "meter" },
  read_only    = true,
  description  = "SolaX X1 and X3 hybrid and string inverters via Modbus TCP. Read-only: no control code has been written for it yet, so FTW reads it but cannot charge or discharge the battery.",
}

PROTOCOL = "modbus"

-- Reading a register the device does not have costs a failed read on every
-- poll forever, and the host counts those against the poll whether or not Lua
-- caught the error. Enough of them and the site is marked offline and reports
-- nothing at all, which is worse than reporting one field less. So stop asking
-- once a register has proved it is not there. Three tries, because one failure
-- proves nothing -- the link may just have been slow.
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
            "SolaX: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

----------------------------------------------------------------------------
-- What the battery can do now (docs/WRITING-A-DRIVER.md)
--
-- SolaX "Energy Storage Inverter Modbus TCP&RTU Communication protocols"
-- V3.28 (X1/X3 Hybrid G4), input registers:
--   0x0008  Temperature (radiator)   int16, 1 C
--   0x0014  BatVoltage_Charge1       int16, 0.1 V
--   0x0018  TemperatureBat           int16, 1 C
--   0x0024  BMS ChargeMaxCurrent     uint16, 0.1 A, "(real time)"
--   0x0025  BMS DischargeMaxCurrent  uint16, 0.1 A
-- The two currents are what the BMS allows now, a live limit.
-- homeassistant-solax-modbus uses the same addresses and scales for Gen3 to
-- Gen6, except that some Gen5/Gen6 X3 units report 0x0008 in tenths; this
-- driver follows the G4 map its manifest lists.
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

-- Watts the BMS allows now: its current limit times the battery voltage of
-- this poll. Without a fresh voltage there is no figure.
local function limit_w(amps, volts)
    if amps == nil or volts == nil or volts <= 0 then return nil end
    return plausible_power(amps * volts)
end

function driver_init(config)
    host.set_make("SolaX")
end

function driver_poll()
    -- ---- PV ----

    -- PV1: voltage=0 (U16 × 0.1V), current=1 (U16 × 0.1A), power=2 (U16, W)
    local pv1_regs = probe_read(0, 3, "input")
    local mppt1_v, mppt1_a, pv1_w = 0, 0, 0
    if pv1_regs then
        mppt1_v = pv1_regs[1] * 0.1
        mppt1_a = pv1_regs[2] * 0.1
        pv1_w   = pv1_regs[3]
    end

    -- PV2: voltage=3 (U16 × 0.1V), current=4 (U16 × 0.1A), power=5 (U16, W)
    local pv2_regs = probe_read(3, 3, "input")
    local mppt2_v, mppt2_a, pv2_w = 0, 0, 0
    if pv2_regs then
        mppt2_v = pv2_regs[1] * 0.1
        mppt2_a = pv2_regs[2] * 0.1
        pv2_w   = pv2_regs[3]
    end

    local pv_w = pv1_w + pv2_w

    -- Grid frequency: 7, U16 × 0.01Hz
    local hz_regs = probe_read(7, 1, "input")
    local hz = 0
    if hz_regs then
        hz = hz_regs[1] * 0.01
    end

    -- Total PV energy: 68-69, U32 BE × 0.1 kWh
    local pvgen_regs = probe_read(68, 2, "input")
    local pv_gen_wh = 0
    if pvgen_regs then
        pv_gen_wh = host.decode_u32_be(pvgen_regs[1], pvgen_regs[2]) * 0.1 * 1000
    end

    -- Emit PV telemetry (W always negative for generation)
    host.emit("pv", {
        W           = -pv_w,
        mppt1_v     = mppt1_v,
        mppt1_a     = mppt1_a,
        mppt2_v     = mppt2_v,
        mppt2_a     = mppt2_a,
        total_generation_Wh = pv_gen_wh,
    })

    -- ---- Battery ----

    -- Battery voltage: 20, U16 × 0.1V
    local bv_regs = probe_read(20, 1, "input")
    local bat_v = 0
    if bv_regs then
        bat_v = bv_regs[1] * 0.1
    end

    -- Battery current: 21, I16 × 0.1A
    local ba_regs = probe_read(21, 1, "input")
    local bat_a = 0
    if ba_regs then
        bat_a = host.decode_i16(ba_regs[1]) * 0.1
    end

    -- Battery power: 22, I16, W (positive=charge, negative=discharge)
    local bw_regs = probe_read(22, 1, "input")
    local bat_w = 0
    if bw_regs then
        bat_w = host.decode_i16(bw_regs[1])
    end

    -- A battery voltage read in this poll. The temperature and the limits
    -- need it: a hybrid without a pack answers zeros, and 0 C or 0 W
    -- would read as a cold battery that may not charge.
    local fresh_v
    if bv_regs and bat_v > 0 then fresh_v = bat_v end

    -- Battery temperature: 24 (0x0018), I16, whole degrees C. Earlier
    -- releases scaled it by 0.1, so 25 C showed as 2.5 C.
    local btemp_regs = probe_read(24, 1, "input")
    local bat_temp
    if btemp_regs and fresh_v then
        bat_temp = plausible_temp(host.decode_i16(btemp_regs[1]))
    end

    -- Battery SoC: 28, U16, %
    local bsoc_regs = probe_read(28, 1, "input")
    local bat_soc = 0
    if bsoc_regs then
        bat_soc = bsoc_regs[1] / 100  -- percent to fraction
    end

    -- BMS charge / discharge max current: 36-37 (0x0024-0x0025), U16 × 0.1 A.
    local charge_a, discharge_a, charge_w, discharge_w
    local blim_regs = probe_read(36, 2, "input")
    if blim_regs and blim_regs[2] ~= nil then
        charge_a = blim_regs[1] * 0.1
        discharge_a = blim_regs[2] * 0.1
        charge_w = limit_w(charge_a, fresh_v)
        discharge_w = limit_w(discharge_a, fresh_v)
    end

    -- Emit Battery telemetry
    host.emit("battery", {
        W      = bat_w,
        V      = bat_v,
        A      = bat_a,
        SoC_nom_fract    = bat_soc,
        temperature_C = bat_temp,
        available_charge_W    = charge_w,
        available_discharge_W = discharge_w,
    })
    if bat_temp ~= nil then
        host.emit_metric("battery_temp_c", bat_temp)
    end
    if charge_w ~= nil then
        host.emit_metric("battery_charge_limit_a", charge_a)
        host.emit_metric("battery_available_charge_w", charge_w)
    end
    if discharge_w ~= nil then
        host.emit_metric("battery_discharge_limit_a", discharge_a)
        host.emit_metric("battery_available_discharge_w", discharge_w)
    end

    -- Inverter (radiator) temperature: 8, I16, whole degrees C.
    local itemp_regs = probe_read(8, 1, "input")
    if itemp_regs then
        local inv_temp = plausible_temp(host.decode_i16(itemp_regs[1]))
        if inv_temp ~= nil then
            host.emit_metric("inverter_temp_c", inv_temp)
        end
    end

    -- ---- Meter ----

    -- Grid power (meter): 70-71, I32 BE, W (positive=import)
    local mw_regs = probe_read(70, 2, "input")
    local meter_w = 0
    if mw_regs then
        meter_w = host.decode_i32_be(mw_regs[1], mw_regs[2])
    end

    -- Feed-in (export) energy: 72-73, U32 BE × 0.01 kWh
    local exp_regs = probe_read(72, 2, "input")
    local export_wh = 0
    if exp_regs then
        export_wh = host.decode_u32_be(exp_regs[1], exp_regs[2]) * 0.01 * 1000
    end

    -- Consumed (import) energy: 74-75, U32 BE × 0.01 kWh
    local imp_regs = probe_read(74, 2, "input")
    local import_wh = 0
    if imp_regs then
        import_wh = host.decode_u32_be(imp_regs[1], imp_regs[2]) * 0.01 * 1000
    end

    -- Emit Meter telemetry
    host.emit("meter", {
        W         = meter_w,
        Hz        = hz,
        total_import_Wh = import_wh,
        total_export_Wh = export_wh,
    })

    return 5000
end

function driver_command(action, power_w, cmd)
    host.log("SolaX control not yet implemented: " .. action)
    return false
end

function driver_default_mode()
end

function driver_cleanup()
    -- nothing to clean up
end
