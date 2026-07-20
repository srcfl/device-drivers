-- Acrel DTSD1352 Three-Phase Meter Driver
-- Emits: Meter only
-- Register type: HOLDING (FC 0x03)
-- U16 for voltage/current/frequency, I32 for power, U32 for energy
-- Default port 502

PROTOCOL = "modbus"

function driver_init(config)
    host.set_make("Acrel")
end

function driver_poll()
    -- Per-phase voltage: 96(0x60), 97, 98 (U16, 0.1V)
    local ok_v, v_regs = pcall(host.modbus_read, 96, 3, "holding")
    local l1_v, l2_v, l3_v = 0, 0, 0
    if ok_v then
        l1_v = v_regs[1] * 0.1
        l2_v = v_regs[2] * 0.1
        l3_v = v_regs[3] * 0.1
    end

    -- Per-phase current: 99(0x63), 100, 101 (U16, 0.001A)
    local ok_a, a_regs = pcall(host.modbus_read, 99, 3, "holding")
    local l1_a, l2_a, l3_a = 0, 0, 0
    if ok_a then
        l1_a = a_regs[1] * 0.001
        l2_a = a_regs[2] * 0.001
        l3_a = a_regs[3] * 0.001
    end

    -- Total active power: 102(0x66) (I32, W)
    local ok_tw, tw_regs = pcall(host.modbus_read, 102, 2, "holding")
    local total_w = 0
    if ok_tw then
        total_w = host.decode_i32(tw_regs[1], tw_regs[2])
    end

    -- Frequency: 110(0x6E) (U16, 0.01Hz)
    local ok_hz, hz_regs = pcall(host.modbus_read, 110, 1, "holding")
    local hz = 0
    if ok_hz then
        hz = hz_regs[1] * 0.01
    end

    -- Import energy: 0(0x00) (U32, 0.01kWh -> Wh)
    local ok_imp, imp_regs = pcall(host.modbus_read, 0, 2, "holding")
    local import_wh = 0
    if ok_imp then
        import_wh = host.decode_u32(imp_regs[1], imp_regs[2]) * 10
    end

    -- Export energy: 8(0x08) (U32, 0.01kWh -> Wh)
    local ok_exp, exp_regs = pcall(host.modbus_read, 8, 2, "holding")
    local export_wh = 0
    if ok_exp then
        export_wh = host.decode_u32(exp_regs[1], exp_regs[2]) * 10
    end

    -- Derive per-phase power from voltage * current (no per-phase power registers)
    local l1_w = l1_v * l1_a
    local l2_w = l2_v * l2_a
    local l3_w = l3_v * l3_a

    host.emit("meter", {
        w         = total_w,
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

function driver_cleanup()
    -- nothing to clean up
end
