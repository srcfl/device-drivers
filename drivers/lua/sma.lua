-- SMA Hybrid Inverter Driver
-- Emits: PV, Battery, Meter
-- Register type: ALL INPUT
-- Byte order: Big-Endian

PROTOCOL = "modbus"

function driver_init(config)
    host.set_make("SMA")
end

function driver_poll()
    -- ---- PV ----

    -- PV power: 30775-30776, I32 BE, watts
    local ok_pvw, pvw_regs = pcall(host.modbus_read, 30775, 2, "input")
    local pv_w = 0
    if ok_pvw then
        pv_w = host.decode_i32(pvw_regs[1], pvw_regs[2])
    end

    -- MPPT1 current: 30769-30770, I32 BE × 0.001 A
    local ok_m1a, m1a_regs = pcall(host.modbus_read, 30769, 2, "input")
    local mppt1_a = 0
    if ok_m1a then
        mppt1_a = host.decode_i32(m1a_regs[1], m1a_regs[2]) * 0.001
    end

    -- MPPT1 voltage: 30771-30772, I32 BE × 0.01 V
    local ok_m1v, m1v_regs = pcall(host.modbus_read, 30771, 2, "input")
    local mppt1_v = 0
    if ok_m1v then
        mppt1_v = host.decode_i32(m1v_regs[1], m1v_regs[2]) * 0.01
    end

    -- MPPT2 current: 30957-30958, I32 BE × 0.001 A
    local ok_m2a, m2a_regs = pcall(host.modbus_read, 30957, 2, "input")
    local mppt2_a = 0
    if ok_m2a then
        mppt2_a = host.decode_i32(m2a_regs[1], m2a_regs[2]) * 0.001
    end

    -- MPPT2 voltage: 30959-30960, I32 BE × 0.01 V
    local ok_m2v, m2v_regs = pcall(host.modbus_read, 30959, 2, "input")
    local mppt2_v = 0
    if ok_m2v then
        mppt2_v = host.decode_i32(m2v_regs[1], m2v_regs[2]) * 0.01
    end

    -- PV generation energy: 30513-30516, U64 BE, Wh
    local ok_pvgen, pvgen_regs = pcall(host.modbus_read, 30513, 4, "input")
    local pv_gen_wh = 0
    if ok_pvgen then
        pv_gen_wh = host.decode_u64(pvgen_regs[1], pvgen_regs[2], pvgen_regs[3], pvgen_regs[4])
    end

    -- Inverter temperature: 30953-30954, I32 BE × 0.1 C
    local ok_itemp, itemp_regs = pcall(host.modbus_read, 30953, 2, "input")
    local inv_temp = 0
    if ok_itemp then
        inv_temp = host.decode_i32(itemp_regs[1], itemp_regs[2]) * 0.1
    end

    -- Rated power: 31085-31086, U32 BE, watts
    local ok_rated, rated_regs = pcall(host.modbus_read, 31085, 2, "input")
    local rated_w = 0
    if ok_rated then
        rated_w = host.decode_u32(rated_regs[1], rated_regs[2])
    end

    -- Emit PV telemetry (W always negative for generation)
    host.emit("pv", {
        w           = -pv_w,
        mppt1_v     = mppt1_v,
        mppt1_a     = mppt1_a,
        mppt2_v     = mppt2_v,
        mppt2_a     = mppt2_a,
        lifetime_wh = pv_gen_wh,
        temp_c      = inv_temp,
        rated_w     = rated_w,
    })

    -- ---- Battery ----

    -- Battery current: 30843-30844, I32 BE × 0.001 A
    local ok_ba, ba_regs = pcall(host.modbus_read, 30843, 2, "input")
    local bat_a = 0
    if ok_ba then
        bat_a = host.decode_i32(ba_regs[1], ba_regs[2]) * 0.001
    end

    -- Battery SoC: 30845-30846, U32 BE, percent
    local ok_bsoc, bsoc_regs = pcall(host.modbus_read, 30845, 2, "input")
    local bat_soc = 0
    if ok_bsoc then
        bat_soc = host.decode_u32(bsoc_regs[1], bsoc_regs[2]) / 100  -- to fraction
    end

    -- Battery temperature: 30849-30850, I32 BE × 0.1 C
    local ok_btemp, btemp_regs = pcall(host.modbus_read, 30849, 2, "input")
    local bat_temp = 0
    if ok_btemp then
        bat_temp = host.decode_i32(btemp_regs[1], btemp_regs[2]) * 0.1
    end

    -- Battery voltage: 30851-30852, U32 BE × 0.01 V
    local ok_bv, bv_regs = pcall(host.modbus_read, 30851, 2, "input")
    local bat_v = 0
    if ok_bv then
        bat_v = host.decode_u32(bv_regs[1], bv_regs[2]) * 0.01
    end

    -- Battery W = V * A (positive=charging, negative=discharging)
    local bat_w = bat_v * bat_a

    -- Battery charge energy: 31397-31400, U64 BE, Wh
    local ok_bchg, bchg_regs = pcall(host.modbus_read, 31397, 4, "input")
    local bat_charge_wh = 0
    if ok_bchg then
        bat_charge_wh = host.decode_u64(bchg_regs[1], bchg_regs[2], bchg_regs[3], bchg_regs[4])
    end

    -- Battery discharge energy: 31401-31404, U64 BE, Wh
    local ok_bdis, bdis_regs = pcall(host.modbus_read, 31401, 4, "input")
    local bat_discharge_wh = 0
    if ok_bdis then
        bat_discharge_wh = host.decode_u64(bdis_regs[1], bdis_regs[2], bdis_regs[3], bdis_regs[4])
    end

    -- Emit Battery telemetry
    host.emit("battery", {
        w            = bat_w,
        v            = bat_v,
        a            = bat_a,
        soc          = bat_soc,
        temp_c       = bat_temp,
        charge_wh    = bat_charge_wh,
        discharge_wh = bat_discharge_wh,
    })

    -- ---- Meter ----

    -- Meter total power: 30885-30886, U32 BE, watts
    local ok_mw, mw_regs = pcall(host.modbus_read, 30885, 2, "input")
    local meter_w = 0
    if ok_mw then
        meter_w = host.decode_u32(mw_regs[1], mw_regs[2])
    end

    -- Per-phase meter power: 30887-30892, U32 BE pairs, watts
    local ok_mpw, mpw_regs = pcall(host.modbus_read, 30887, 6, "input")
    local l1_w, l2_w, l3_w = 0, 0, 0
    if ok_mpw then
        l1_w = host.decode_u32(mpw_regs[1], mpw_regs[2])
        l2_w = host.decode_u32(mpw_regs[3], mpw_regs[4])
        l3_w = host.decode_u32(mpw_regs[5], mpw_regs[6])
    end

    -- Frequency: 30901-30902, U32 BE × 0.01 Hz
    local ok_hz, hz_regs = pcall(host.modbus_read, 30901, 2, "input")
    local hz = 0
    if ok_hz then
        hz = host.decode_u32(hz_regs[1], hz_regs[2]) * 0.01
    end

    -- Per-phase voltage: 30903-30908, U32 BE × 0.01 pairs, volts
    local ok_lv, lv_regs = pcall(host.modbus_read, 30903, 6, "input")
    local l1_v, l2_v, l3_v = 0, 0, 0
    if ok_lv then
        l1_v = host.decode_u32(lv_regs[1], lv_regs[2]) * 0.01
        l2_v = host.decode_u32(lv_regs[3], lv_regs[4]) * 0.01
        l3_v = host.decode_u32(lv_regs[5], lv_regs[6]) * 0.01
    end

    -- Per-phase current: 30909-30914, U32 BE × 0.001 pairs, amps
    local ok_la, la_regs = pcall(host.modbus_read, 30909, 6, "input")
    local l1_a, l2_a, l3_a = 0, 0, 0
    if ok_la then
        l1_a = host.decode_u32(la_regs[1], la_regs[2]) * 0.001
        l2_a = host.decode_u32(la_regs[3], la_regs[4]) * 0.001
        l3_a = host.decode_u32(la_regs[5], la_regs[6]) * 0.001
    end

    -- Import energy: 30581-30582, U32 BE, Wh
    local ok_imp, imp_regs = pcall(host.modbus_read, 30581, 2, "input")
    local import_wh = 0
    if ok_imp then
        import_wh = host.decode_u32(imp_regs[1], imp_regs[2])
    end

    -- Export energy: 30583-30584, U32 BE, Wh
    local ok_exp, exp_regs = pcall(host.modbus_read, 30583, 2, "input")
    local export_wh = 0
    if ok_exp then
        export_wh = host.decode_u32(exp_regs[1], exp_regs[2])
    end

    -- Emit Meter telemetry (direct, SMA meter values follow standard convention)
    host.emit("meter", {
        w         = meter_w,
        l1_w      = l1_w,
        l2_w      = l2_w,
        l3_w      = l3_w,
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
    host.log("SMA control not yet implemented: " .. action)
    return false
end

function driver_default_mode()
end

function driver_cleanup()
    -- nothing to clean up
end
