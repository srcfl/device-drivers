-- Fronius SunSpec Inverter Driver
-- Emits: PV, Battery, Meter
-- Register type: ALL HOLDING
-- Uses F32 BE for inverter values, SunSpec scale factors for MPPT/battery

PROTOCOL = "modbus"

function driver_init(config)
    host.set_make("Fronius")
end

function driver_poll()
    -- ---- Scale Factors ----

    -- Rated W SF: 40135, I16
    local ok_rwsf, rwsf_regs = pcall(host.modbus_read, 40135, 1, "holding")
    local rated_w_sf = 0
    if ok_rwsf then
        rated_w_sf = host.decode_i16(rwsf_regs[1])
    end

    -- MPPT A SF: 40265, I16
    local ok_masf, masf_regs = pcall(host.modbus_read, 40265, 1, "holding")
    local mppt_a_sf = 0
    if ok_masf then
        mppt_a_sf = host.decode_i16(masf_regs[1])
    end

    -- MPPT V SF: 40266, I16
    local ok_mvsf, mvsf_regs = pcall(host.modbus_read, 40266, 1, "holding")
    local mppt_v_sf = 0
    if ok_mvsf then
        mppt_v_sf = host.decode_i16(mvsf_regs[1])
    end

    -- Max charge SF: 40331, I16
    local ok_mcsf, mcsf_regs = pcall(host.modbus_read, 40331, 1, "holding")
    local max_charge_sf = 0
    if ok_mcsf then
        max_charge_sf = host.decode_i16(mcsf_regs[1])
    end

    -- SoC SF: 40335, I16
    local ok_socsf, socsf_regs = pcall(host.modbus_read, 40335, 1, "holding")
    local soc_sf = 0
    if ok_socsf then
        soc_sf = host.decode_i16(socsf_regs[1])
    end

    -- Battery V SF: 40337, I16
    local ok_bvsf, bvsf_regs = pcall(host.modbus_read, 40337, 1, "holding")
    local bat_v_sf = 0
    if ok_bvsf then
        bat_v_sf = host.decode_i16(bvsf_regs[1])
    end

    -- Charge rate SF: 40338, I16
    local ok_crsf, crsf_regs = pcall(host.modbus_read, 40338, 1, "holding")
    local charge_rate_sf = 0
    if ok_crsf then
        charge_rate_sf = host.decode_i16(crsf_regs[1])
    end

    -- ---- PV / Inverter values (F32) ----

    -- AC power: 40091-40092, F32 BE, watts
    local ok_acw, acw_regs = pcall(host.modbus_read, 40091, 2, "holding")
    local ac_w = 0
    if ok_acw then
        ac_w = host.decode_f32(acw_regs[1], acw_regs[2])
    end

    -- Frequency: 40093-40094, F32 BE, Hz
    local ok_hz, hz_regs = pcall(host.modbus_read, 40093, 2, "holding")
    local hz = 0
    if ok_hz then
        hz = host.decode_f32(hz_regs[1], hz_regs[2])
    end

    -- Lifetime energy: 40101-40102, F32 BE, Wh
    local ok_le, le_regs = pcall(host.modbus_read, 40101, 2, "holding")
    local lifetime_wh = 0
    if ok_le then
        lifetime_wh = host.decode_f32(le_regs[1], le_regs[2])
    end

    -- DC power (PV): 40107-40108, F32 BE, watts
    local ok_dcw, dcw_regs = pcall(host.modbus_read, 40107, 2, "holding")
    local dc_w = 0
    if ok_dcw then
        dc_w = host.decode_f32(dcw_regs[1], dcw_regs[2])
    end

    -- Heatsink temperature: 40111-40112, F32 BE, C
    local ok_temp, temp_regs = pcall(host.modbus_read, 40111, 2, "holding")
    local heatsink_c = 0
    if ok_temp then
        heatsink_c = host.decode_f32(temp_regs[1], temp_regs[2])
    end

    -- Rated W: 40134, U16 raw
    local ok_rw, rw_regs = pcall(host.modbus_read, 40134, 1, "holding")
    local rated_w = 0
    if ok_rw then
        rated_w = host.scale(rw_regs[1], rated_w_sf)
    end

    -- MPPT1 A/V: 40282-40283, U16 each
    local ok_m1, m1_regs = pcall(host.modbus_read, 40282, 2, "holding")
    local mppt1_a, mppt1_v = 0, 0
    if ok_m1 then
        mppt1_a = host.scale(m1_regs[1], mppt_a_sf)
        mppt1_v = host.scale(m1_regs[2], mppt_v_sf)
    end

    -- MPPT2 A/V: 40302-40303, U16 each
    local ok_m2, m2_regs = pcall(host.modbus_read, 40302, 2, "holding")
    local mppt2_a, mppt2_v = 0, 0
    if ok_m2 then
        mppt2_a = host.scale(m2_regs[1], mppt_a_sf)
        mppt2_v = host.scale(m2_regs[2], mppt_v_sf)
    end

    -- Per-phase AC current: 40073, 40075, 40077 (F32 BE pairs)
    local ok_l1a, l1a_regs = pcall(host.modbus_read, 40073, 2, "holding")
    local l1_a = 0
    if ok_l1a then l1_a = host.decode_f32(l1a_regs[1], l1a_regs[2]) end

    local ok_l2a, l2a_regs = pcall(host.modbus_read, 40075, 2, "holding")
    local l2_a = 0
    if ok_l2a then l2_a = host.decode_f32(l2a_regs[1], l2a_regs[2]) end

    local ok_l3a, l3a_regs = pcall(host.modbus_read, 40077, 2, "holding")
    local l3_a = 0
    if ok_l3a then l3_a = host.decode_f32(l3a_regs[1], l3a_regs[2]) end

    -- Per-phase AC voltage: 40085, 40087, 40089 (F32 BE pairs)
    local ok_l1v, l1v_regs = pcall(host.modbus_read, 40085, 2, "holding")
    local l1_v = 0
    if ok_l1v then l1_v = host.decode_f32(l1v_regs[1], l1v_regs[2]) end

    local ok_l2v, l2v_regs = pcall(host.modbus_read, 40087, 2, "holding")
    local l2_v = 0
    if ok_l2v then l2_v = host.decode_f32(l2v_regs[1], l2v_regs[2]) end

    local ok_l3v, l3v_regs = pcall(host.modbus_read, 40089, 2, "holding")
    local l3_v = 0
    if ok_l3v then l3_v = host.decode_f32(l3v_regs[1], l3v_regs[2]) end

    -- Emit PV telemetry (PV = -DC_W, always negative for generation)
    host.emit("pv", {
        w           = -dc_w,
        mppt1_v     = mppt1_v,
        mppt1_a     = mppt1_a,
        mppt2_v     = mppt2_v,
        mppt2_a     = mppt2_a,
        lifetime_wh = lifetime_wh,
        temp_c      = heatsink_c,
        rated_w     = rated_w,
    })

    -- ---- Battery ----

    -- Max charge power: 40315, U16 raw
    local ok_maxchg, maxchg_regs = pcall(host.modbus_read, 40315, 1, "holding")
    local max_charge_w = 0
    if ok_maxchg then
        max_charge_w = host.scale(maxchg_regs[1], max_charge_sf)
    end

    -- Battery SoC: 40321, U16 raw
    local ok_bsoc, bsoc_regs = pcall(host.modbus_read, 40321, 1, "holding")
    local bat_soc = 0
    if ok_bsoc then
        bat_soc = host.scale(bsoc_regs[1], soc_sf) / 100  -- percent to fraction
    end

    -- Battery voltage: 40323, U16 raw
    local ok_batv, batv_regs = pcall(host.modbus_read, 40323, 1, "holding")
    local bat_v = 0
    if ok_batv then
        bat_v = host.scale(batv_regs[1], bat_v_sf)
    end

    -- Discharge rate %: 40325, I16 raw
    local ok_dis, dis_regs = pcall(host.modbus_read, 40325, 1, "holding")
    local discharge_rate = 0
    if ok_dis then
        discharge_rate = host.scale(host.decode_i16(dis_regs[1]), charge_rate_sf)
    end

    -- Charge rate %: 40326, I16 raw
    local ok_chg, chg_regs = pcall(host.modbus_read, 40326, 1, "holding")
    local charge_rate = 0
    if ok_chg then
        charge_rate = host.scale(host.decode_i16(chg_regs[1]), charge_rate_sf)
    end

    -- Calculate battery power from rates and max power
    -- discharge_rate > 0: discharging -> negative W
    -- charge_rate > 0: charging -> positive W
    local bat_w = 0
    if discharge_rate > 0 then
        bat_w = -(discharge_rate / 100) * max_charge_w
    elseif charge_rate > 0 then
        bat_w = (charge_rate / 100) * max_charge_w
    end

    -- Emit Battery telemetry
    host.emit("battery", {
        w   = bat_w,
        v   = bat_v,
        soc = bat_soc,
    })

    -- ---- Meter (derived from AC values) ----
    -- Per-phase meter W = V * A
    local l1_w = l1_v * l1_a
    local l2_w = l2_v * l2_a
    local l3_w = l3_v * l3_a

    -- Emit Meter telemetry (AC power direct, positive=import)
    host.emit("meter", {
        w    = ac_w,
        l1_w = l1_w,
        l2_w = l2_w,
        l3_w = l3_w,
        l1_v = l1_v,
        l2_v = l2_v,
        l3_v = l3_v,
        l1_a = l1_a,
        l2_a = l2_a,
        l3_a = l3_a,
        hz   = hz,
    })

    return 5000
end

function driver_command(action, power_w, cmd)
    host.log("Fronius control not yet implemented: " .. action)
    return false
end

function driver_default_mode()
end

function driver_cleanup()
    -- nothing to clean up
end
