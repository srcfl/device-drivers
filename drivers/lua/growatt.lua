-- Growatt SPH/MIN/MOD/MAX Series Inverter Driver
-- Emits: PV, Battery, Meter
-- Register type: INPUT (FC 0x04)
-- Byte order: Big-Endian for multi-register values
-- Port: 502
-- Community tier (untested)

PROTOCOL = "modbus"

function driver_init(config)
    host.set_make("Growatt")
end

function driver_poll()
    -- ---- PV ----

    -- PV total power: 1-2, U32 BE × 0.1W
    local ok_pvw, pvw_regs = pcall(host.modbus_read, 1, 2, "input")
    local pv_w = 0
    if ok_pvw then
        pv_w = host.decode_u32(pvw_regs[1], pvw_regs[2]) * 0.1
    end

    -- PV1 voltage: 3, U16 × 0.1V; PV1 current: 4, U16 × 0.1A
    local ok_m1, m1_regs = pcall(host.modbus_read, 3, 2, "input")
    local mppt1_v, mppt1_a = 0, 0
    if ok_m1 then
        mppt1_v = m1_regs[1] * 0.1
        mppt1_a = m1_regs[2] * 0.1
    end

    -- PV2 voltage: 7, U16 × 0.1V; PV2 current: 8, U16 × 0.1A
    local ok_m2, m2_regs = pcall(host.modbus_read, 7, 2, "input")
    local mppt2_v, mppt2_a = 0, 0
    if ok_m2 then
        mppt2_v = m2_regs[1] * 0.1
        mppt2_a = m2_regs[2] * 0.1
    end

    -- Grid frequency: 37, U16 × 0.01Hz
    local ok_hz, hz_regs = pcall(host.modbus_read, 37, 1, "input")
    local hz = 0
    if ok_hz then
        hz = hz_regs[1] * 0.01
    end

    -- Total PV energy: 91-92, U32 BE × 0.1 kWh
    local ok_pvgen, pvgen_regs = pcall(host.modbus_read, 91, 2, "input")
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

    -- Battery charge power: 1009-1010, U32 BE × 0.1W
    local ok_bchgw, bchgw_regs = pcall(host.modbus_read, 1009, 2, "input")
    local bat_charge_w = 0
    if ok_bchgw then
        bat_charge_w = host.decode_u32(bchgw_regs[1], bchgw_regs[2]) * 0.1
    end

    -- Battery discharge power: 1011-1012, U32 BE × 0.1W
    local ok_bdisw, bdisw_regs = pcall(host.modbus_read, 1011, 2, "input")
    local bat_discharge_w = 0
    if ok_bdisw then
        bat_discharge_w = host.decode_u32(bdisw_regs[1], bdisw_regs[2]) * 0.1
    end

    -- Net battery power: positive=charge, negative=discharge
    local bat_w = bat_charge_w - bat_discharge_w

    -- Battery voltage: 1013, U16 × 0.1V
    local ok_bv, bv_regs = pcall(host.modbus_read, 1013, 1, "input")
    local bat_v = 0
    if ok_bv then
        bat_v = bv_regs[1] * 0.1
    end

    -- Battery SoC: 1014, U16, %
    local ok_bsoc, bsoc_regs = pcall(host.modbus_read, 1014, 1, "input")
    local bat_soc = 0
    if ok_bsoc then
        bat_soc = bsoc_regs[1] / 100  -- percent to fraction
    end

    -- Battery temperature: 1040, U16 × 0.1C
    local ok_btemp, btemp_regs = pcall(host.modbus_read, 1040, 1, "input")
    local bat_temp = 0
    if ok_btemp then
        bat_temp = btemp_regs[1] * 0.1
    end

    -- Emit Battery telemetry
    host.emit("battery", {
        w      = bat_w,
        v      = bat_v,
        soc    = bat_soc,
        temp_c = bat_temp,
    })

    -- ---- Meter ----

    -- Meter power: 1015-1016, I32 BE × 0.1W (positive=import)
    local ok_mw, mw_regs = pcall(host.modbus_read, 1015, 2, "input")
    local meter_w = 0
    if ok_mw then
        meter_w = host.decode_i32(mw_regs[1], mw_regs[2]) * 0.1
    end

    -- Phase voltages: L1=38, L2=42, L3=46, U16 × 0.1V
    local ok_lv1, lv1_regs = pcall(host.modbus_read, 38, 1, "input")
    local l1_v = 0
    if ok_lv1 then
        l1_v = lv1_regs[1] * 0.1
    end

    local ok_lv2, lv2_regs = pcall(host.modbus_read, 42, 1, "input")
    local l2_v = 0
    if ok_lv2 then
        l2_v = lv2_regs[1] * 0.1
    end

    local ok_lv3, lv3_regs = pcall(host.modbus_read, 46, 1, "input")
    local l3_v = 0
    if ok_lv3 then
        l3_v = lv3_regs[1] * 0.1
    end

    -- Phase currents: L1=39, L2=43, L3=47, U16 × 0.1A
    local ok_la1, la1_regs = pcall(host.modbus_read, 39, 1, "input")
    local l1_a = 0
    if ok_la1 then
        l1_a = la1_regs[1] * 0.1
    end

    local ok_la2, la2_regs = pcall(host.modbus_read, 43, 1, "input")
    local l2_a = 0
    if ok_la2 then
        l2_a = la2_regs[1] * 0.1
    end

    local ok_la3, la3_regs = pcall(host.modbus_read, 47, 1, "input")
    local l3_a = 0
    if ok_la3 then
        l3_a = la3_regs[1] * 0.1
    end

    -- Total import energy: 1021-1022, U32 BE × 0.1 kWh
    local ok_imp, imp_regs = pcall(host.modbus_read, 1021, 2, "input")
    local import_wh = 0
    if ok_imp then
        import_wh = host.decode_u32(imp_regs[1], imp_regs[2]) * 0.1 * 1000
    end

    -- Total export energy: 1029-1030, U32 BE × 0.1 kWh
    local ok_exp, exp_regs = pcall(host.modbus_read, 1029, 2, "input")
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
    host.log("Growatt control not yet implemented: " .. action)
    return false
end

function driver_default_mode()
end

function driver_cleanup()
    -- nothing to clean up
end
