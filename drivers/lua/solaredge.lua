-- SolarEdge SunSpec Inverter Driver
-- Emits: PV, Meter
-- Register type: INPUT (SolarEdge uses FC 0x04 for SunSpec data)
-- Uses SunSpec scale factors
-- Note: SolarEdge port 1502 (non-standard)

PROTOCOL = "modbus"

function driver_init(config)
    host.set_make("SolarEdge")
end

function driver_poll()
    -- ---- Scale Factors ----

    -- AC power SF: 40084, I16
    local ok_acsf, acsf_regs = pcall(host.modbus_read, 40084, 1, "input")
    local ac_power_sf = 0
    if ok_acsf then
        ac_power_sf = host.decode_i16(acsf_regs[1])
    end

    -- Hz SF: 40086, I16
    local ok_hzsf, hzsf_regs = pcall(host.modbus_read, 40086, 1, "input")
    local hz_sf = 0
    if ok_hzsf then
        hz_sf = host.decode_i16(hzsf_regs[1])
    end

    -- Energy SF (inverter): 40095, U16
    local ok_esf, esf_regs = pcall(host.modbus_read, 40095, 1, "input")
    local energy_sf = 0
    if ok_esf then
        energy_sf = host.decode_i16(esf_regs[1])
    end

    -- Temp SF: 40106, I16
    local ok_tsf, tsf_regs = pcall(host.modbus_read, 40106, 1, "input")
    local temp_sf = 0
    if ok_tsf then
        temp_sf = host.decode_i16(tsf_regs[1])
    end

    -- MPPT A SF: 40123, I16
    local ok_masf, masf_regs = pcall(host.modbus_read, 40123, 1, "input")
    local mppt_a_sf = 0
    if ok_masf then
        mppt_a_sf = host.decode_i16(masf_regs[1])
    end

    -- MPPT V SF: 40124, I16
    local ok_mvsf, mvsf_regs = pcall(host.modbus_read, 40124, 1, "input")
    local mppt_v_sf = 0
    if ok_mvsf then
        mppt_v_sf = host.decode_i16(mvsf_regs[1])
    end

    -- Meter W SF: 40101, I16
    local ok_mwsf, mwsf_regs = pcall(host.modbus_read, 40101, 1, "input")
    local meter_w_sf = 0
    if ok_mwsf then
        meter_w_sf = host.decode_i16(mwsf_regs[1])
    end

    -- Meter A SF: 40194, I16
    local ok_asf, asf_regs = pcall(host.modbus_read, 40194, 1, "input")
    local meter_a_sf = 0
    if ok_asf then
        meter_a_sf = host.decode_i16(asf_regs[1])
    end

    -- Meter V SF: 40203, I16
    local ok_vsf, vsf_regs = pcall(host.modbus_read, 40203, 1, "input")
    local meter_v_sf = 0
    if ok_vsf then
        meter_v_sf = host.decode_i16(vsf_regs[1])
    end

    -- Phase W SF: 40210, I16
    local ok_pwsf, pwsf_regs = pcall(host.modbus_read, 40210, 1, "input")
    local phase_w_sf = 0
    if ok_pwsf then
        phase_w_sf = host.decode_i16(pwsf_regs[1])
    end

    -- Meter energy SF: 40242, I16
    local ok_mesf, mesf_regs = pcall(host.modbus_read, 40242, 1, "input")
    local meter_energy_sf = 0
    if ok_mesf then
        meter_energy_sf = host.decode_i16(mesf_regs[1])
    end

    -- ---- PV Values ----

    -- AC power: 40083, I16
    local ok_acw, acw_regs = pcall(host.modbus_read, 40083, 1, "input")
    local ac_w = 0
    if ok_acw then
        ac_w = host.scale(host.decode_i16(acw_regs[1]), ac_power_sf)
    end

    -- Frequency: 40085, U16
    local ok_hz, hz_regs = pcall(host.modbus_read, 40085, 1, "input")
    local hz = 0
    if ok_hz then
        hz = host.scale(hz_regs[1], hz_sf)
    end

    -- Lifetime energy: 40093-40094, U32 BE
    local ok_le, le_regs = pcall(host.modbus_read, 40093, 2, "input")
    local lifetime_wh = 0
    if ok_le then
        lifetime_wh = host.scale(host.decode_u32(le_regs[1], le_regs[2]), energy_sf)
    end

    -- Temperature: 40103, I16
    local ok_temp, temp_regs = pcall(host.modbus_read, 40103, 1, "input")
    local temp_c = 0
    if ok_temp then
        temp_c = host.scale(host.decode_i16(temp_regs[1]), temp_sf)
    end

    -- MPPT1 A/V: 40140-40141, U16 each
    local ok_m1, m1_regs = pcall(host.modbus_read, 40140, 2, "input")
    local mppt1_a, mppt1_v = 0, 0
    if ok_m1 then
        mppt1_a = host.scale(m1_regs[1], mppt_a_sf)
        mppt1_v = host.scale(m1_regs[2], mppt_v_sf)
    end

    -- MPPT2 A/V: 40160-40161, U16 each
    local ok_m2, m2_regs = pcall(host.modbus_read, 40160, 2, "input")
    local mppt2_a, mppt2_v = 0, 0
    if ok_m2 then
        mppt2_a = host.scale(m2_regs[1], mppt_a_sf)
        mppt2_v = host.scale(m2_regs[2], mppt_v_sf)
    end

    -- Emit PV telemetry (W always negative for generation)
    host.emit("pv", {
        w           = -ac_w,
        mppt1_v     = mppt1_v,
        mppt1_a     = mppt1_a,
        mppt2_v     = mppt2_v,
        mppt2_a     = mppt2_a,
        lifetime_wh = lifetime_wh,
        temp_c      = temp_c,
    })

    -- ---- Meter Values ----

    -- Meter total W: 40100, I16
    local ok_mw, mw_regs = pcall(host.modbus_read, 40100, 1, "input")
    local meter_w = 0
    if ok_mw then
        meter_w = host.scale(host.decode_i16(mw_regs[1]), meter_w_sf)
    end

    -- Per-phase current: 40191-40193, I16 each
    local ok_la, la_regs = pcall(host.modbus_read, 40191, 3, "input")
    local l1_a, l2_a, l3_a = 0, 0, 0
    if ok_la then
        l1_a = host.scale(host.decode_i16(la_regs[1]), meter_a_sf)
        l2_a = host.scale(host.decode_i16(la_regs[2]), meter_a_sf)
        l3_a = host.scale(host.decode_i16(la_regs[3]), meter_a_sf)
    end

    -- Per-phase voltage: 40196-40198, I16 each
    local ok_lv, lv_regs = pcall(host.modbus_read, 40196, 3, "input")
    local l1_v, l2_v, l3_v = 0, 0, 0
    if ok_lv then
        l1_v = host.scale(host.decode_i16(lv_regs[1]), meter_v_sf)
        l2_v = host.scale(host.decode_i16(lv_regs[2]), meter_v_sf)
        l3_v = host.scale(host.decode_i16(lv_regs[3]), meter_v_sf)
    end

    -- Per-phase power: 40207-40209, I16 each
    local ok_lw, lw_regs = pcall(host.modbus_read, 40207, 3, "input")
    local l1_w, l2_w, l3_w = 0, 0, 0
    if ok_lw then
        l1_w = host.scale(host.decode_i16(lw_regs[1]), phase_w_sf)
        l2_w = host.scale(host.decode_i16(lw_regs[2]), phase_w_sf)
        l3_w = host.scale(host.decode_i16(lw_regs[3]), phase_w_sf)
    end

    -- Export energy: 40226-40227, U32 BE
    local ok_exp, exp_regs = pcall(host.modbus_read, 40226, 2, "input")
    local export_wh = 0
    if ok_exp then
        export_wh = host.scale(host.decode_u32(exp_regs[1], exp_regs[2]), meter_energy_sf)
    end

    -- Import energy: 40234-40235, U32 BE
    local ok_imp, imp_regs = pcall(host.modbus_read, 40234, 2, "input")
    local import_wh = 0
    if ok_imp then
        import_wh = host.scale(host.decode_u32(imp_regs[1], imp_regs[2]), meter_energy_sf)
    end

    -- Emit Meter telemetry (negate W and A for our convention)
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

    return 5000
end

function driver_command(action, power_w, cmd)
    host.log("SolarEdge control not yet implemented: " .. action)
    return false
end

function driver_default_mode()
end

function driver_cleanup()
    -- nothing to clean up
end
