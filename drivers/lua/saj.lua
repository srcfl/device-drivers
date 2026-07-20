-- SAJ H2/HS2/AS2 Series Inverter Driver
-- Emits: PV, Battery, Meter
-- Register type: INPUT (FC 0x04)
-- Port: 502
-- Community tier (untested)
-- Hex addresses converted to decimal

PROTOCOL = "modbus"

function driver_init(config)
    host.set_make("SAJ")
end

function driver_poll()
    -- ---- PV ----

    -- PV1 voltage: 0x1058=4184, U16 × 0.1V
    -- PV1 current: 0x1059=4185, U16 × 0.01A
    local ok_pv1, pv1_regs = pcall(host.modbus_read, 4184, 2, "input")
    local mppt1_v, mppt1_a = 0, 0
    if ok_pv1 then
        mppt1_v = pv1_regs[1] * 0.1
        mppt1_a = pv1_regs[2] * 0.01
    end

    -- PV2 voltage: 0x105C=4188, U16 × 0.1V
    -- PV2 current: 0x105D=4189, U16 × 0.01A
    local ok_pv2, pv2_regs = pcall(host.modbus_read, 4188, 2, "input")
    local mppt2_v, mppt2_a = 0, 0
    if ok_pv2 then
        mppt2_v = pv2_regs[1] * 0.1
        mppt2_a = pv2_regs[2] * 0.01
    end

    -- PV power: 0x1062-0x1063=4194-4195, U32 BE, W
    local ok_pvw, pvw_regs = pcall(host.modbus_read, 4194, 2, "input")
    local pv_w = 0
    if ok_pvw then
        pv_w = host.decode_u32(pvw_regs[1], pvw_regs[2])
    end

    -- Grid frequency: 0x104F=4175, U16 × 0.01Hz
    local ok_hz, hz_regs = pcall(host.modbus_read, 4175, 1, "input")
    local hz = 0
    if ok_hz then
        hz = hz_regs[1] * 0.01
    end

    -- Emit PV telemetry (W always negative for generation)
    host.emit("pv", {
        w       = -pv_w,
        mppt1_v = mppt1_v,
        mppt1_a = mppt1_a,
        mppt2_v = mppt2_v,
        mppt2_a = mppt2_a,
    })

    -- ---- Battery ----

    -- Battery power: 0x1096=4246, I16, W (positive=charge, negative=discharge)
    local ok_bw, bw_regs = pcall(host.modbus_read, 4246, 1, "input")
    local bat_w = 0
    if ok_bw then
        bat_w = host.decode_i16(bw_regs[1])
    end

    -- Battery SoC: 0x1098=4248, U16, %
    local ok_bsoc, bsoc_regs = pcall(host.modbus_read, 4248, 1, "input")
    local bat_soc = 0
    if ok_bsoc then
        bat_soc = bsoc_regs[1] / 100  -- percent to fraction
    end

    -- Emit Battery telemetry
    host.emit("battery", {
        w   = bat_w,
        soc = bat_soc,
    })

    -- ---- Meter ----

    -- Grid power: 0x1072-0x1073=4210-4211, I32 BE, W (positive=import)
    local ok_mw, mw_regs = pcall(host.modbus_read, 4210, 2, "input")
    local meter_w = 0
    if ok_mw then
        meter_w = host.decode_i32(mw_regs[1], mw_regs[2])
    end

    -- Phase voltages: 0x1048=4168 (L1), 0x104A=4170 (L2), 0x104C=4172 (L3), U16 × 0.1V
    local ok_lv1, lv1_regs = pcall(host.modbus_read, 4168, 1, "input")
    local l1_v = 0
    if ok_lv1 then
        l1_v = lv1_regs[1] * 0.1
    end

    local ok_lv2, lv2_regs = pcall(host.modbus_read, 4170, 1, "input")
    local l2_v = 0
    if ok_lv2 then
        l2_v = lv2_regs[1] * 0.1
    end

    local ok_lv3, lv3_regs = pcall(host.modbus_read, 4172, 1, "input")
    local l3_v = 0
    if ok_lv3 then
        l3_v = lv3_regs[1] * 0.1
    end

    -- Phase currents: 0x1049=4169 (L1), 0x104B=4171 (L2), 0x104D=4173 (L3), U16 × 0.01A
    local ok_la1, la1_regs = pcall(host.modbus_read, 4169, 1, "input")
    local l1_a = 0
    if ok_la1 then
        l1_a = la1_regs[1] * 0.01
    end

    local ok_la2, la2_regs = pcall(host.modbus_read, 4171, 1, "input")
    local l2_a = 0
    if ok_la2 then
        l2_a = la2_regs[1] * 0.01
    end

    local ok_la3, la3_regs = pcall(host.modbus_read, 4173, 1, "input")
    local l3_a = 0
    if ok_la3 then
        l3_a = la3_regs[1] * 0.01
    end

    -- Emit Meter telemetry
    host.emit("meter", {
        w    = meter_w,
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
    host.log("SAJ control not yet implemented: " .. action)
    return false
end

function driver_default_mode()
end

function driver_cleanup()
    -- nothing to clean up
end
