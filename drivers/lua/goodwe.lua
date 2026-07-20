-- GoodWe ET/EH/BT/BH/ES/DT Series Inverter Driver
-- Emits: PV, Battery, Meter
-- Register type: HOLDING (FC 0x03)
-- Byte order: Big-Endian for multi-register values
-- Port: 502
-- Community tier (untested)

PROTOCOL = "modbus"

function driver_init(config)
    host.set_make("GoodWe")
end

function driver_poll()
    -- ---- PV ----

    -- PV total power: 35105-35106, U32 BE, 0.1W
    local ok_pvw, pvw_regs = pcall(host.modbus_read, 35105, 2, "holding")
    local pv_w = 0
    if ok_pvw then
        pv_w = host.decode_u32(pvw_regs[1], pvw_regs[2]) * 0.1
    end

    -- PV1 voltage: 35103, U16 × 0.1V; PV1 current: 35104, U16 × 0.1A
    local ok_m1, m1_regs = pcall(host.modbus_read, 35103, 2, "holding")
    local mppt1_v, mppt1_a = 0, 0
    if ok_m1 then
        mppt1_v = m1_regs[1] * 0.1
        mppt1_a = m1_regs[2] * 0.1
    end

    -- PV2 voltage: 35109, U16 × 0.1V; PV2 current: 35110, U16 × 0.1A
    local ok_m2, m2_regs = pcall(host.modbus_read, 35109, 2, "holding")
    local mppt2_v, mppt2_a = 0, 0
    if ok_m2 then
        mppt2_v = m2_regs[1] * 0.1
        mppt2_a = m2_regs[2] * 0.1
    end

    -- Grid frequency: 35113, U16 × 0.01Hz
    local ok_hz, hz_regs = pcall(host.modbus_read, 35113, 1, "holding")
    local hz = 0
    if ok_hz then
        hz = hz_regs[1] * 0.01
    end

    -- PV generation energy: 35191-35192, U32 BE × 0.1 kWh
    local ok_pvgen, pvgen_regs = pcall(host.modbus_read, 35191, 2, "holding")
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

    -- Battery voltage: 35178, U16 × 0.1V
    local ok_bv, bv_regs = pcall(host.modbus_read, 35178, 1, "holding")
    local bat_v = 0
    if ok_bv then
        bat_v = bv_regs[1] * 0.1
    end

    -- Battery current: 35179, I16 × 0.1A
    local ok_ba, ba_regs = pcall(host.modbus_read, 35179, 1, "holding")
    local bat_a = 0
    if ok_ba then
        bat_a = host.decode_i16(ba_regs[1]) * 0.1
    end

    -- Battery power: 35180, I16, W (positive=charge, negative=discharge)
    local ok_bw, bw_regs = pcall(host.modbus_read, 35180, 1, "holding")
    local bat_w = 0
    if ok_bw then
        bat_w = host.decode_i16(bw_regs[1])
    end

    -- Battery SoC: 35182, U16, %
    local ok_bsoc, bsoc_regs = pcall(host.modbus_read, 35182, 1, "holding")
    local bat_soc = 0
    if ok_bsoc then
        bat_soc = bsoc_regs[1] / 100  -- percent to fraction
    end

    -- Battery temperature: 35183, I16 × 0.1C
    local ok_btemp, btemp_regs = pcall(host.modbus_read, 35183, 1, "holding")
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

    -- Meter total power: 35140-35141, I32 BE, W
    -- GoodWe: positive = export from grid perspective, negate for our convention (positive=import)
    local ok_mw, mw_regs = pcall(host.modbus_read, 35140, 2, "holding")
    local meter_w = 0
    if ok_mw then
        meter_w = -host.decode_i32(mw_regs[1], mw_regs[2])
    end

    -- Per-phase meter power: L1=35132, L2=35134, L3=35136, I32 BE each pair
    local ok_l1w, l1w_regs = pcall(host.modbus_read, 35132, 2, "holding")
    local l1_w = 0
    if ok_l1w then
        l1_w = -host.decode_i32(l1w_regs[1], l1w_regs[2])
    end

    local ok_l2w, l2w_regs = pcall(host.modbus_read, 35134, 2, "holding")
    local l2_w = 0
    if ok_l2w then
        l2_w = -host.decode_i32(l2w_regs[1], l2w_regs[2])
    end

    local ok_l3w, l3w_regs = pcall(host.modbus_read, 35136, 2, "holding")
    local l3_w = 0
    if ok_l3w then
        l3_w = -host.decode_i32(l3w_regs[1], l3w_regs[2])
    end

    -- Grid voltages: L1=35121, L2=35123, L3=35125, U16 × 0.1V
    local ok_lv1, lv1_regs = pcall(host.modbus_read, 35121, 1, "holding")
    local l1_v = 0
    if ok_lv1 then
        l1_v = lv1_regs[1] * 0.1
    end

    local ok_lv2, lv2_regs = pcall(host.modbus_read, 35123, 1, "holding")
    local l2_v = 0
    if ok_lv2 then
        l2_v = lv2_regs[1] * 0.1
    end

    local ok_lv3, lv3_regs = pcall(host.modbus_read, 35125, 1, "holding")
    local l3_v = 0
    if ok_lv3 then
        l3_v = lv3_regs[1] * 0.1
    end

    -- Grid currents: L1=35122, L2=35124, L3=35126, U16 × 0.1A
    local ok_la1, la1_regs = pcall(host.modbus_read, 35122, 1, "holding")
    local l1_a = 0
    if ok_la1 then
        l1_a = la1_regs[1] * 0.1
    end

    local ok_la2, la2_regs = pcall(host.modbus_read, 35124, 1, "holding")
    local l2_a = 0
    if ok_la2 then
        l2_a = la2_regs[1] * 0.1
    end

    local ok_la3, la3_regs = pcall(host.modbus_read, 35126, 1, "holding")
    local l3_a = 0
    if ok_la3 then
        l3_a = la3_regs[1] * 0.1
    end

    -- Total import energy: 35195-35196, U32 BE × 0.1 kWh
    local ok_imp, imp_regs = pcall(host.modbus_read, 35195, 2, "holding")
    local import_wh = 0
    if ok_imp then
        import_wh = host.decode_u32(imp_regs[1], imp_regs[2]) * 0.1 * 1000
    end

    -- Total export energy: 35199-35200, U32 BE × 0.1 kWh
    local ok_exp, exp_regs = pcall(host.modbus_read, 35199, 2, "holding")
    local export_wh = 0
    if ok_exp then
        export_wh = host.decode_u32(exp_regs[1], exp_regs[2]) * 0.1 * 1000
    end

    -- Emit Meter telemetry
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
    host.log("GoodWe control not yet implemented: " .. action)
    return false
end

function driver_default_mode()
end

function driver_cleanup()
    -- nothing to clean up
end
