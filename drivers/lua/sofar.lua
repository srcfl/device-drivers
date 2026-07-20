-- Sofar Solar HYD Series Inverter Driver
-- Emits: PV, Battery, Meter
-- Register type: HOLDING (FC 0x03)
-- Port: 502
-- Community tier (untested)
-- Register map from wills106/homeassistant-solax-modbus community
-- Hex addresses converted to decimal

PROTOCOL = "modbus"

function driver_init(config)
    host.set_make("Sofar")
end

function driver_poll()
    -- ---- PV ----

    -- PV1 voltage: 0x0584=1412, U16 × 0.1V
    -- PV1 current: 0x0585=1413, U16 × 0.01A
    local ok_pv1, pv1_regs = pcall(host.modbus_read, 1412, 2, "holding")
    local mppt1_v, mppt1_a = 0, 0
    if ok_pv1 then
        mppt1_v = pv1_regs[1] * 0.1
        mppt1_a = pv1_regs[2] * 0.01
    end

    -- PV total power: 0x0586=1414, U16, 10W
    local ok_pvw, pvw_regs = pcall(host.modbus_read, 1414, 1, "holding")
    local pv_w = 0
    if ok_pvw then
        pv_w = pvw_regs[1] * 10
    end

    -- PV2 voltage: 0x0587=1415, U16 × 0.1V
    -- PV2 current: 0x0588=1416, U16 × 0.01A
    local ok_pv2, pv2_regs = pcall(host.modbus_read, 1415, 2, "holding")
    local mppt2_v, mppt2_a = 0, 0
    if ok_pv2 then
        mppt2_v = pv2_regs[1] * 0.1
        mppt2_a = pv2_regs[2] * 0.01
    end

    -- Grid frequency: 0x020C=524, U16 × 0.01Hz
    local ok_hz, hz_regs = pcall(host.modbus_read, 524, 1, "holding")
    local hz = 0
    if ok_hz then
        hz = hz_regs[1] * 0.01
    end

    -- Total PV energy: 0x0684-0x0685=1668-1669, U32 BE × 0.1 kWh
    local ok_pvgen, pvgen_regs = pcall(host.modbus_read, 1668, 2, "holding")
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

    -- Battery voltage: 0x0604=1540, U16 × 0.1V
    local ok_bv, bv_regs = pcall(host.modbus_read, 1540, 1, "holding")
    local bat_v = 0
    if ok_bv then
        bat_v = bv_regs[1] * 0.1
    end

    -- Battery current: 0x0605=1541, I16 × 0.01A
    local ok_ba, ba_regs = pcall(host.modbus_read, 1541, 1, "holding")
    local bat_a = 0
    if ok_ba then
        bat_a = host.decode_i16(ba_regs[1]) * 0.01
    end

    -- Battery power: 0x0606=1542, I16, 10W (positive=charge, negative=discharge)
    local ok_bw, bw_regs = pcall(host.modbus_read, 1542, 1, "holding")
    local bat_w = 0
    if ok_bw then
        bat_w = host.decode_i16(bw_regs[1]) * 10
    end

    -- Battery temperature: 0x0607=1543, I16, C
    local ok_btemp, btemp_regs = pcall(host.modbus_read, 1543, 1, "holding")
    local bat_temp = 0
    if ok_btemp then
        bat_temp = host.decode_i16(btemp_regs[1])
    end

    -- Battery SoC: 0x0608=1544, U16, %
    local ok_bsoc, bsoc_regs = pcall(host.modbus_read, 1544, 1, "holding")
    local bat_soc = 0
    if ok_bsoc then
        bat_soc = bsoc_regs[1] / 100  -- percent to fraction
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

    -- Grid power: 0x0212=530, I16, 10W (positive=import)
    local ok_mw, mw_regs = pcall(host.modbus_read, 530, 1, "holding")
    local meter_w = 0
    if ok_mw then
        meter_w = host.decode_i16(mw_regs[1]) * 10
    end

    -- Phase voltages: 0x0206=518 (L1), 0x0208=520 (L2), 0x020A=522 (L3), U16 × 0.1V
    local ok_lv1, lv1_regs = pcall(host.modbus_read, 518, 1, "holding")
    local l1_v = 0
    if ok_lv1 then
        l1_v = lv1_regs[1] * 0.1
    end

    local ok_lv2, lv2_regs = pcall(host.modbus_read, 520, 1, "holding")
    local l2_v = 0
    if ok_lv2 then
        l2_v = lv2_regs[1] * 0.1
    end

    local ok_lv3, lv3_regs = pcall(host.modbus_read, 522, 1, "holding")
    local l3_v = 0
    if ok_lv3 then
        l3_v = lv3_regs[1] * 0.1
    end

    -- Phase currents: 0x0207=519 (L1), 0x0209=521 (L2), 0x020B=523 (L3), U16 × 0.01A
    local ok_la1, la1_regs = pcall(host.modbus_read, 519, 1, "holding")
    local l1_a = 0
    if ok_la1 then
        l1_a = la1_regs[1] * 0.01
    end

    local ok_la2, la2_regs = pcall(host.modbus_read, 521, 1, "holding")
    local l2_a = 0
    if ok_la2 then
        l2_a = la2_regs[1] * 0.01
    end

    local ok_la3, la3_regs = pcall(host.modbus_read, 523, 1, "holding")
    local l3_a = 0
    if ok_la3 then
        l3_a = la3_regs[1] * 0.01
    end

    -- Import energy: 0x0688-0x0689=1672-1673, U32 BE × 0.1 kWh
    local ok_imp, imp_regs = pcall(host.modbus_read, 1672, 2, "holding")
    local import_wh = 0
    if ok_imp then
        import_wh = host.decode_u32(imp_regs[1], imp_regs[2]) * 0.1 * 1000
    end

    -- Export energy: 0x068A-0x068B=1674-1675, U32 BE × 0.1 kWh
    local ok_exp, exp_regs = pcall(host.modbus_read, 1674, 2, "holding")
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
    host.log("Sofar control not yet implemented: " .. action)
    return false
end

function driver_default_mode()
end

function driver_cleanup()
    -- nothing to clean up
end
