-- Fox ESS H1/H3 Series Inverter Driver
-- Emits: PV, Battery, Meter
-- Register type: HOLDING (FC 0x03)
-- Port: 502
-- Community tier (untested)
-- Register map from nathanmarlor/foxess_modbus community

PROTOCOL = "modbus"

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
            "FoxESS: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

function driver_init(config)
    host.set_make("FoxESS")
end

function driver_poll()
    -- ---- PV ----

    -- PV1 power: 11000, I16, W
    local pv1w_regs = probe_read(11000, 1, "holding")
    local pv1_w = 0
    if pv1w_regs then
        pv1_w = host.decode_i16(pv1w_regs[1])
    end

    -- PV1 current: 11001, U16 × 0.1A; PV1 voltage: 11002, U16 × 0.1V
    local pv1_regs = probe_read(11001, 2, "holding")
    local mppt1_a, mppt1_v = 0, 0
    if pv1_regs then
        mppt1_a = pv1_regs[1] * 0.1
        mppt1_v = pv1_regs[2] * 0.1
    end

    -- PV2 power: 11003, I16, W
    local pv2w_regs = probe_read(11003, 1, "holding")
    local pv2_w = 0
    if pv2w_regs then
        pv2_w = host.decode_i16(pv2w_regs[1])
    end

    -- PV2 current: 11004, U16 × 0.1A; PV2 voltage: 11005, U16 × 0.1V
    local pv2_regs = probe_read(11004, 2, "holding")
    local mppt2_a, mppt2_v = 0, 0
    if pv2_regs then
        mppt2_a = pv2_regs[1] * 0.1
        mppt2_v = pv2_regs[2] * 0.1
    end

    local pv_w = pv1_w + pv2_w

    -- Grid frequency: 11014, U16 × 0.01Hz
    local hz_regs = probe_read(11014, 1, "holding")
    local hz = 0
    if hz_regs then
        hz = hz_regs[1] * 0.01
    end

    -- Total PV energy: 11070-11071, U32 BE × 0.1 kWh
    local pvgen_regs = probe_read(11070, 2, "holding")
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

    -- Battery power: 11034, I16, W (positive=charge, negative=discharge)
    local bw_regs = probe_read(11034, 1, "holding")
    local bat_w = 0
    if bw_regs then
        bat_w = host.decode_i16(bw_regs[1])
    end

    -- Battery current: 11035, I16 × 0.1A
    local ba_regs = probe_read(11035, 1, "holding")
    local bat_a = 0
    if ba_regs then
        bat_a = host.decode_i16(ba_regs[1]) * 0.1
    end

    -- Battery voltage: 11036, U16 × 0.1V
    local bv_regs = probe_read(11036, 1, "holding")
    local bat_v = 0
    if bv_regs then
        bat_v = bv_regs[1] * 0.1
    end

    -- Battery SoC: 11038, U16, %
    local bsoc_regs = probe_read(11038, 1, "holding")
    local bat_soc = 0
    if bsoc_regs then
        bat_soc = bsoc_regs[1] / 100  -- percent to fraction
    end

    -- Battery temperature: 11039, I16 × 0.1C
    local btemp_regs = probe_read(11039, 1, "holding")
    local bat_temp = 0
    if btemp_regs then
        bat_temp = host.decode_i16(btemp_regs[1]) * 0.1
    end

    -- Emit Battery telemetry
    host.emit("battery", {
        W      = bat_w,
        V      = bat_v,
        A      = bat_a,
        SoC_nom_fract    = bat_soc,
        temperature_C = bat_temp,
    })

    -- ---- Meter ----

    -- Grid/Meter power: 11021, I16, W (positive=import)
    local mw_regs = probe_read(11021, 1, "holding")
    local meter_w = 0
    if mw_regs then
        meter_w = host.decode_i16(mw_regs[1])
    end

    -- Phase voltages: 11009, 11011, 11013, U16 × 0.1V
    local lv1_regs = probe_read(11009, 1, "holding")
    local l1_v = 0
    if lv1_regs then
        l1_v = lv1_regs[1] * 0.1
    end

    local lv2_regs = probe_read(11011, 1, "holding")
    local l2_v = 0
    if lv2_regs then
        l2_v = lv2_regs[1] * 0.1
    end

    local lv3_regs = probe_read(11013, 1, "holding")
    local l3_v = 0
    if lv3_regs then
        l3_v = lv3_regs[1] * 0.1
    end

    -- Phase currents: 11010, 11012, 11014, U16 × 0.1A
    local la1_regs = probe_read(11010, 1, "holding")
    local l1_a = 0
    if la1_regs then
        l1_a = la1_regs[1] * 0.1
    end

    local la2_regs = probe_read(11012, 1, "holding")
    local l2_a = 0
    if la2_regs then
        l2_a = la2_regs[1] * 0.1
    end

    -- Note: register 11014 is also grid frequency; for 3-phase current L3
    -- Fox ESS uses the same register address. Read separately if needed.
    local la3_regs = probe_read(11014, 1, "holding")
    local l3_a = 0
    if la3_regs then
        -- This register is shared with frequency on single-phase models
        -- On 3-phase (H3), this holds L3 current × 0.1A
        l3_a = la3_regs[1] * 0.1
    end

    -- Import energy: 11072-11073, U32 BE × 0.1 kWh
    local imp_regs = probe_read(11072, 2, "holding")
    local import_wh = 0
    if imp_regs then
        import_wh = host.decode_u32_be(imp_regs[1], imp_regs[2]) * 0.1 * 1000
    end

    -- Export energy: 11074-11075, U32 BE × 0.1 kWh
    local exp_regs = probe_read(11074, 2, "holding")
    local export_wh = 0
    if exp_regs then
        export_wh = host.decode_u32_be(exp_regs[1], exp_regs[2]) * 0.1 * 1000
    end

    -- Emit Meter telemetry
    host.emit("meter", {
        W         = meter_w,
        L1_V      = l1_v,
        L2_V      = l2_v,
        L3_V      = l3_v,
        L1_A      = l1_a,
        L2_A      = l2_a,
        L3_A      = l3_a,
        Hz        = hz,
        total_import_Wh = import_wh,
        total_export_Wh = export_wh,
    })

    return 5000
end

function driver_command(action, power_w, cmd)
    host.log("FoxESS control not yet implemented: " .. action)
    return false
end

function driver_default_mode()
end

function driver_cleanup()
    -- nothing to clean up
end
