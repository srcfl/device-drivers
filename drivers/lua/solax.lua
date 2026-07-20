-- SolaX X1/X3 Hybrid Series Inverter Driver
-- Emits: PV, Battery, Meter
-- Register type: INPUT (FC 0x04)
-- Byte order: Big-Endian for multi-register values
-- Port: 502
-- Community tier (untested)

PROTOCOL = "modbus"

function driver_init(config)
    host.set_make("SolaX")
end

function driver_poll()
    -- ---- PV ----

    -- PV1: voltage=0 (U16 × 0.1V), current=1 (U16 × 0.1A), power=2 (U16, W)
    local ok_pv1, pv1_regs = pcall(host.modbus_read, 0, 3, "input")
    local mppt1_v, mppt1_a, pv1_w = 0, 0, 0
    if ok_pv1 then
        mppt1_v = pv1_regs[1] * 0.1
        mppt1_a = pv1_regs[2] * 0.1
        pv1_w   = pv1_regs[3]
    end

    -- PV2: voltage=3 (U16 × 0.1V), current=4 (U16 × 0.1A), power=5 (U16, W)
    local ok_pv2, pv2_regs = pcall(host.modbus_read, 3, 3, "input")
    local mppt2_v, mppt2_a, pv2_w = 0, 0, 0
    if ok_pv2 then
        mppt2_v = pv2_regs[1] * 0.1
        mppt2_a = pv2_regs[2] * 0.1
        pv2_w   = pv2_regs[3]
    end

    local pv_w = pv1_w + pv2_w

    -- Grid frequency: 7, U16 × 0.01Hz
    local ok_hz, hz_regs = pcall(host.modbus_read, 7, 1, "input")
    local hz = 0
    if ok_hz then
        hz = hz_regs[1] * 0.01
    end

    -- Total PV energy: 68-69, U32 BE × 0.1 kWh
    local ok_pvgen, pvgen_regs = pcall(host.modbus_read, 68, 2, "input")
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

    -- Battery voltage: 20, U16 × 0.1V
    local ok_bv, bv_regs = pcall(host.modbus_read, 20, 1, "input")
    local bat_v = 0
    if ok_bv then
        bat_v = bv_regs[1] * 0.1
    end

    -- Battery current: 21, I16 × 0.1A
    local ok_ba, ba_regs = pcall(host.modbus_read, 21, 1, "input")
    local bat_a = 0
    if ok_ba then
        bat_a = host.decode_i16(ba_regs[1]) * 0.1
    end

    -- Battery power: 22, I16, W (positive=charge, negative=discharge)
    local ok_bw, bw_regs = pcall(host.modbus_read, 22, 1, "input")
    local bat_w = 0
    if ok_bw then
        bat_w = host.decode_i16(bw_regs[1])
    end

    -- Battery temperature: 24, I16 × 0.1C
    local ok_btemp, btemp_regs = pcall(host.modbus_read, 24, 1, "input")
    local bat_temp = 0
    if ok_btemp then
        bat_temp = host.decode_i16(btemp_regs[1]) * 0.1
    end

    -- Battery SoC: 28, U16, %
    local ok_bsoc, bsoc_regs = pcall(host.modbus_read, 28, 1, "input")
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

    -- Grid power (meter): 70-71, I32 BE, W (positive=import)
    local ok_mw, mw_regs = pcall(host.modbus_read, 70, 2, "input")
    local meter_w = 0
    if ok_mw then
        meter_w = host.decode_i32(mw_regs[1], mw_regs[2])
    end

    -- Feed-in (export) energy: 72-73, U32 BE × 0.01 kWh
    local ok_exp, exp_regs = pcall(host.modbus_read, 72, 2, "input")
    local export_wh = 0
    if ok_exp then
        export_wh = host.decode_u32(exp_regs[1], exp_regs[2]) * 0.01 * 1000
    end

    -- Consumed (import) energy: 74-75, U32 BE × 0.01 kWh
    local ok_imp, imp_regs = pcall(host.modbus_read, 74, 2, "input")
    local import_wh = 0
    if ok_imp then
        import_wh = host.decode_u32(imp_regs[1], imp_regs[2]) * 0.01 * 1000
    end

    -- Emit Meter telemetry
    host.emit("meter", {
        w         = meter_w,
        hz        = hz,
        import_wh = import_wh,
        export_wh = export_wh,
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
