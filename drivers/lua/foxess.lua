-- Fox ESS H1/H3 Series Inverter Driver
-- Emits: PV, Battery, Meter
-- Register type: HOLDING (FC 0x03)
-- Port: 502
-- Community tier (untested)
-- Register map from nathanmarlor/foxess_modbus community

PROTOCOL = "modbus"

function driver_init(config)
    host.set_make("FoxESS")
end

function driver_poll()
    -- ---- PV ----

    -- PV1 power: 11000, I16, W
    local ok_pv1w, pv1w_regs = pcall(host.modbus_read, 11000, 1, "holding")
    local pv1_w = 0
    if ok_pv1w then
        pv1_w = host.decode_i16(pv1w_regs[1])
    end

    -- PV1 current: 11001, U16 × 0.1A; PV1 voltage: 11002, U16 × 0.1V
    local ok_pv1, pv1_regs = pcall(host.modbus_read, 11001, 2, "holding")
    local mppt1_a, mppt1_v = 0, 0
    if ok_pv1 then
        mppt1_a = pv1_regs[1] * 0.1
        mppt1_v = pv1_regs[2] * 0.1
    end

    -- PV2 power: 11003, I16, W
    local ok_pv2w, pv2w_regs = pcall(host.modbus_read, 11003, 1, "holding")
    local pv2_w = 0
    if ok_pv2w then
        pv2_w = host.decode_i16(pv2w_regs[1])
    end

    -- PV2 current: 11004, U16 × 0.1A; PV2 voltage: 11005, U16 × 0.1V
    local ok_pv2, pv2_regs = pcall(host.modbus_read, 11004, 2, "holding")
    local mppt2_a, mppt2_v = 0, 0
    if ok_pv2 then
        mppt2_a = pv2_regs[1] * 0.1
        mppt2_v = pv2_regs[2] * 0.1
    end

    local pv_w = pv1_w + pv2_w

    -- Grid frequency: 11014, U16 × 0.01Hz
    local ok_hz, hz_regs = pcall(host.modbus_read, 11014, 1, "holding")
    local hz = 0
    if ok_hz then
        hz = hz_regs[1] * 0.01
    end

    -- Total PV energy: 11070-11071, U32 BE × 0.1 kWh
    local ok_pvgen, pvgen_regs = pcall(host.modbus_read, 11070, 2, "holding")
    local pv_gen_wh = 0
    if ok_pvgen then
        pv_gen_wh = host.decode_u32(pvgen_regs[1], pvgen_regs[2]) * 0.1 * 1000
    end

    -- Emit PV telemetry (W always negative for generation)
    host.emit("pv", {
        w           = -pv_w,
        mppt1_v     = mppt1_v,
        mppt1_a     = mppt1_a,
        mppt2_v     = mppt2_v,
        mppt2_a     = mppt2_a,
        lifetime_wh = pv_gen_wh,
    })

    -- ---- Battery ----

    -- Battery power: 11034, I16, W (positive=charge, negative=discharge)
    local ok_bw, bw_regs = pcall(host.modbus_read, 11034, 1, "holding")
    local bat_w = 0
    if ok_bw then
        bat_w = host.decode_i16(bw_regs[1])
    end

    -- Battery current: 11035, I16 × 0.1A
    local ok_ba, ba_regs = pcall(host.modbus_read, 11035, 1, "holding")
    local bat_a = 0
    if ok_ba then
        bat_a = host.decode_i16(ba_regs[1]) * 0.1
    end

    -- Battery voltage: 11036, U16 × 0.1V
    local ok_bv, bv_regs = pcall(host.modbus_read, 11036, 1, "holding")
    local bat_v = 0
    if ok_bv then
        bat_v = bv_regs[1] * 0.1
    end

    -- Battery SoC: 11038, U16, %
    local ok_bsoc, bsoc_regs = pcall(host.modbus_read, 11038, 1, "holding")
    local bat_soc = 0
    if ok_bsoc then
        bat_soc = bsoc_regs[1] / 100  -- percent to fraction
    end

    -- Battery temperature: 11039, I16 × 0.1C
    local ok_btemp, btemp_regs = pcall(host.modbus_read, 11039, 1, "holding")
    local bat_temp = 0
    if ok_btemp then
        bat_temp = host.decode_i16(btemp_regs[1]) * 0.1
    end

    -- Emit Battery telemetry
    host.emit("battery", {
        w      = bat_w,
        v      = bat_v,
        a      = bat_a,
        soc    = bat_soc,
        temp_c = bat_temp,
    })

    -- ---- Meter ----

    -- Grid/Meter power: 11021, I16, W (positive=import)
    local ok_mw, mw_regs = pcall(host.modbus_read, 11021, 1, "holding")
    local meter_w = 0
    if ok_mw then
        meter_w = host.decode_i16(mw_regs[1])
    end

    -- Phase voltages: 11009, 11011, 11013, U16 × 0.1V
    local ok_lv1, lv1_regs = pcall(host.modbus_read, 11009, 1, "holding")
    local l1_v = 0
    if ok_lv1 then
        l1_v = lv1_regs[1] * 0.1
    end

    local ok_lv2, lv2_regs = pcall(host.modbus_read, 11011, 1, "holding")
    local l2_v = 0
    if ok_lv2 then
        l2_v = lv2_regs[1] * 0.1
    end

    local ok_lv3, lv3_regs = pcall(host.modbus_read, 11013, 1, "holding")
    local l3_v = 0
    if ok_lv3 then
        l3_v = lv3_regs[1] * 0.1
    end

    -- Phase currents: 11010, 11012, 11014, U16 × 0.1A
    local ok_la1, la1_regs = pcall(host.modbus_read, 11010, 1, "holding")
    local l1_a = 0
    if ok_la1 then
        l1_a = la1_regs[1] * 0.1
    end

    local ok_la2, la2_regs = pcall(host.modbus_read, 11012, 1, "holding")
    local l2_a = 0
    if ok_la2 then
        l2_a = la2_regs[1] * 0.1
    end

    -- Note: register 11014 is also grid frequency; for 3-phase current L3
    -- Fox ESS uses the same register address. Read separately if needed.
    local ok_la3, la3_regs = pcall(host.modbus_read, 11014, 1, "holding")
    local l3_a = 0
    if ok_la3 then
        -- This register is shared with frequency on single-phase models
        -- On 3-phase (H3), this holds L3 current × 0.1A
        l3_a = la3_regs[1] * 0.1
    end

    -- Import energy: 11072-11073, U32 BE × 0.1 kWh
    local ok_imp, imp_regs = pcall(host.modbus_read, 11072, 2, "holding")
    local import_wh = 0
    if ok_imp then
        import_wh = host.decode_u32(imp_regs[1], imp_regs[2]) * 0.1 * 1000
    end

    -- Export energy: 11074-11075, U32 BE × 0.1 kWh
    local ok_exp, exp_regs = pcall(host.modbus_read, 11074, 2, "holding")
    local export_wh = 0
    if ok_exp then
        export_wh = host.decode_u32(exp_regs[1], exp_regs[2]) * 0.1 * 1000
    end

    -- Emit Meter telemetry
    host.emit("meter", {
        w         = meter_w,
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
