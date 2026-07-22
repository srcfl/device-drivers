-- Pixii PowerShaper Driver
-- Emits: Battery, Meter
-- Register type: ALL HOLDING
-- Uses SunSpec scale factors

PROTOCOL = "modbus"

local REG_METER_ENERGY_SF = 40288 -- SunSpec model 213 offset 53; absent on some firmware
local has_meter_energy_sf = true -- probed once in driver_init

function driver_init(config)
    host.set_make("Pixii")

    -- Some PowerShaper firmware omits the meter-energy scale factor (Modbus
    -- exception 0x02 on 40288). Poll evidence counts every failed read, so
    -- probe once here and skip the register for the rest of the session.
    local ok, regs = pcall(host.modbus_read, REG_METER_ENERGY_SF, 1, "holding")
    has_meter_energy_sf = ok and regs ~= nil and regs[1] ~= nil
    if not has_meter_energy_sf then
        host.log("info", "Pixii: meter energy scale factor @" .. REG_METER_ENERGY_SF
            .. " not available; import/export Wh use sf=0")
    end
end

function driver_poll()
    -- ---- Scale Factors ----

    -- AC power SF: 40084, I16
    local ok_acsf, acsf_regs = pcall(host.modbus_read, 40084, 1, "holding")
    local ac_w_sf = 0
    if ok_acsf then ac_w_sf = host.decode_i16(acsf_regs[1]) end

    -- Hz SF: 40086, I16
    local ok_hzsf, hzsf_regs = pcall(host.modbus_read, 40086, 1, "holding")
    local hz_sf = 0
    if ok_hzsf then hz_sf = host.decode_i16(hzsf_regs[1]) end

    -- Temp SF: 40106, I16
    local ok_tsf, tsf_regs = pcall(host.modbus_read, 40106, 1, "holding")
    local temp_sf = 0
    if ok_tsf then temp_sf = host.decode_i16(tsf_regs[1]) end

    -- SoC SF: 40177, I16
    local ok_socsf, socsf_regs = pcall(host.modbus_read, 40177, 1, "holding")
    local soc_sf = 0
    if ok_socsf then soc_sf = host.decode_i16(socsf_regs[1]) end

    -- SoH SF: 40179, I16
    local ok_sohsf, sohsf_regs = pcall(host.modbus_read, 40179, 1, "holding")
    local soh_sf = 0
    if ok_sohsf then soh_sf = host.decode_i16(sohsf_regs[1]) end

    -- Battery V SF: 40180, I16
    local ok_bvsf, bvsf_regs = pcall(host.modbus_read, 40180, 1, "holding")
    local bat_v_sf = 0
    if ok_bvsf then bat_v_sf = host.decode_i16(bvsf_regs[1]) end

    -- Battery A SF: 40182, I16
    local ok_basf, basf_regs = pcall(host.modbus_read, 40182, 1, "holding")
    local bat_a_sf = 0
    if ok_basf then bat_a_sf = host.decode_i16(basf_regs[1]) end

    -- Battery W SF: 40184, I16
    local ok_bwsf, bwsf_regs = pcall(host.modbus_read, 40184, 1, "holding")
    local bat_w_sf = 0
    if ok_bwsf then bat_w_sf = host.decode_i16(bwsf_regs[1]) end

    -- Meter A SF: 40240, I16
    local ok_masf, masf_regs = pcall(host.modbus_read, 40240, 1, "holding")
    local meter_a_sf = 0
    if ok_masf then meter_a_sf = host.decode_i16(masf_regs[1]) end

    -- Meter V SF: 40249, I16
    local ok_mvsf, mvsf_regs = pcall(host.modbus_read, 40249, 1, "holding")
    local meter_v_sf = 0
    if ok_mvsf then meter_v_sf = host.decode_i16(mvsf_regs[1]) end

    -- Meter Hz SF: 40251, I16
    local ok_mhsf, mhsf_regs = pcall(host.modbus_read, 40251, 1, "holding")
    local meter_hz_sf = 0
    if ok_mhsf then meter_hz_sf = host.decode_i16(mhsf_regs[1]) end

    -- Meter W SF: 40256, I16
    local ok_mwsf, mwsf_regs = pcall(host.modbus_read, 40256, 1, "holding")
    local meter_w_sf = 0
    if ok_mwsf then meter_w_sf = host.decode_i16(mwsf_regs[1]) end

    -- Meter energy SF: 40288, I16 (optional on older firmware)
    local meter_energy_sf = 0
    if has_meter_energy_sf then
        local ok_mesf, mesf_regs = pcall(host.modbus_read, REG_METER_ENERGY_SF, 1, "holding")
        if ok_mesf then meter_energy_sf = host.decode_i16(mesf_regs[1]) end
    end

    -- ---- Battery Values ----

    -- AC power: 40083, I16
    local ok_acw, acw_regs = pcall(host.modbus_read, 40083, 1, "holding")
    local ac_w = 0
    if ok_acw then ac_w = host.scale(host.decode_i16(acw_regs[1]), ac_w_sf) end

    -- Frequency (inverter): 40085, U16
    local ok_hz, hz_regs = pcall(host.modbus_read, 40085, 1, "holding")
    local inv_hz = 0
    if ok_hz then inv_hz = host.scale(hz_regs[1], hz_sf) end

    -- Temperature: 40102, I16
    local ok_temp, temp_regs = pcall(host.modbus_read, 40102, 1, "holding")
    local temp_c = 0
    if ok_temp then temp_c = host.scale(host.decode_i16(temp_regs[1]), temp_sf) end

    -- Battery SoC: 40132, U16
    local ok_soc, soc_regs = pcall(host.modbus_read, 40132, 1, "holding")
    local bat_soc = 0
    if ok_soc then bat_soc = host.scale(soc_regs[1], soc_sf) / 100 end  -- percent to fraction

    -- Battery voltage: 40155, I16
    local ok_bv, bv_regs = pcall(host.modbus_read, 40155, 1, "holding")
    local bat_v = 0
    if ok_bv then bat_v = host.scale(host.decode_i16(bv_regs[1]), bat_v_sf) end

    -- Battery current: 40165, I16
    local ok_ba, ba_regs = pcall(host.modbus_read, 40165, 1, "holding")
    local bat_a = 0
    if ok_ba then bat_a = host.scale(host.decode_i16(ba_regs[1]), bat_a_sf) end

    -- Battery DC power: 40168, I16
    local ok_bw, bw_regs = pcall(host.modbus_read, 40168, 1, "holding")
    local bat_w = 0
    if ok_bw then bat_w = host.scale(host.decode_i16(bw_regs[1]), bat_w_sf) end

    -- Cabinet charge/discharge energy: 39958-39961, two I32 BE pairs, kWh
    local ok_cab, cab_regs = pcall(host.modbus_read, 39958, 4, "holding")
    local bat_charge_wh, bat_discharge_wh = 0, 0
    if ok_cab then
        bat_charge_wh    = host.decode_i32(cab_regs[1], cab_regs[2]) * 1000
        bat_discharge_wh = host.decode_i32(cab_regs[3], cab_regs[4]) * 1000
    end

    -- Emit Battery telemetry
    host.emit("battery", {
        w            = bat_w,
        v            = bat_v,
        a            = bat_a,
        soc          = bat_soc,
        temp_c       = temp_c,
        charge_wh    = bat_charge_wh,
        discharge_wh = bat_discharge_wh,
    })

    -- ---- Meter Values ----

    -- Per-phase current: 40237-40239, I16 each
    local ok_la, la_regs = pcall(host.modbus_read, 40237, 3, "holding")
    local l1_a, l2_a, l3_a = 0, 0, 0
    if ok_la then
        l1_a = host.scale(host.decode_i16(la_regs[1]), meter_a_sf)
        l2_a = host.scale(host.decode_i16(la_regs[2]), meter_a_sf)
        l3_a = host.scale(host.decode_i16(la_regs[3]), meter_a_sf)
    end

    -- Per-phase voltage: 40242-40244, I16 each
    local ok_lv, lv_regs = pcall(host.modbus_read, 40242, 3, "holding")
    local l1_v, l2_v, l3_v = 0, 0, 0
    if ok_lv then
        l1_v = host.scale(host.decode_i16(lv_regs[1]), meter_v_sf)
        l2_v = host.scale(host.decode_i16(lv_regs[2]), meter_v_sf)
        l3_v = host.scale(host.decode_i16(lv_regs[3]), meter_v_sf)
    end

    -- Meter frequency: 40250, U16
    local ok_mhz, mhz_regs = pcall(host.modbus_read, 40250, 1, "holding")
    local meter_hz = 0
    if ok_mhz then meter_hz = host.scale(mhz_regs[1], meter_hz_sf) end

    -- Total meter power: 40252, I16
    local ok_mw, mw_regs = pcall(host.modbus_read, 40252, 1, "holding")
    local meter_w = 0
    if ok_mw then meter_w = host.scale(host.decode_i16(mw_regs[1]), meter_w_sf) end

    -- Per-phase meter power: 40253-40255, I16 each
    local ok_lpw, lpw_regs = pcall(host.modbus_read, 40253, 3, "holding")
    local l1_w, l2_w, l3_w = 0, 0, 0
    if ok_lpw then
        l1_w = host.scale(host.decode_i16(lpw_regs[1]), meter_w_sf)
        l2_w = host.scale(host.decode_i16(lpw_regs[2]), meter_w_sf)
        l3_w = host.scale(host.decode_i16(lpw_regs[3]), meter_w_sf)
    end

    -- Export energy: 40272-40275, two U32 BE
    local ok_exp, exp_regs = pcall(host.modbus_read, 40272, 4, "holding")
    local export_wh = 0
    if ok_exp then
        export_wh = host.scale(host.decode_u32(exp_regs[1], exp_regs[2]), meter_energy_sf)
    end

    -- Import energy: 40280-40283, two U32 BE
    local ok_imp, imp_regs = pcall(host.modbus_read, 40280, 4, "holding")
    local import_wh = 0
    if ok_imp then
        import_wh = host.scale(host.decode_u32(imp_regs[1], imp_regs[2]), meter_energy_sf)
    end

    -- Emit Meter telemetry (Pixii: negative=import, so negate for our convention)
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
        hz        = meter_hz,
        import_wh = import_wh,
        export_wh = export_wh,
    })

    return 5000
end

function driver_command(action, power_w, cmd)
    host.log("Pixii control not yet implemented: " .. action)
    return false
end

function driver_default_mode()
end

function driver_cleanup()
    -- nothing to clean up
end
