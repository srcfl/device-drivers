-- Circutor CEM-C/CVM Three-Phase Meter Driver
-- Emits: Meter only
-- Register type: HOLDING (FC 0x03)
-- All values are F32 Big-Endian
-- Default port 502

PROTOCOL = "modbus"

function driver_init(config)
    host.set_make("Circutor")
end

function driver_poll()
    -- Per-phase voltage: 0-1, 2-3, 4-5 (F32, V)
    local ok_v, v_regs = pcall(host.modbus_read, 0, 6, "holding")
    local l1_v, l2_v, l3_v = 0, 0, 0
    if ok_v then
        l1_v = host.decode_f32(v_regs[1], v_regs[2])
        l2_v = host.decode_f32(v_regs[3], v_regs[4])
        l3_v = host.decode_f32(v_regs[5], v_regs[6])
    end

    -- Per-phase current: 6-7, 8-9, 10-11 (F32, A)
    local ok_a, a_regs = pcall(host.modbus_read, 6, 6, "holding")
    local l1_a, l2_a, l3_a = 0, 0, 0
    if ok_a then
        l1_a = host.decode_f32(a_regs[1], a_regs[2])
        l2_a = host.decode_f32(a_regs[3], a_regs[4])
        l3_a = host.decode_f32(a_regs[5], a_regs[6])
    end

    -- Per-phase power: 12-13, 14-15, 16-17 (F32, W)
    local ok_w, w_regs = pcall(host.modbus_read, 12, 6, "holding")
    local l1_w, l2_w, l3_w = 0, 0, 0
    if ok_w then
        l1_w = host.decode_f32(w_regs[1], w_regs[2])
        l2_w = host.decode_f32(w_regs[3], w_regs[4])
        l3_w = host.decode_f32(w_regs[5], w_regs[6])
    end

    -- Total power: 18-19 (F32, W)
    local ok_tw, tw_regs = pcall(host.modbus_read, 18, 2, "holding")
    local total_w = 0
    if ok_tw then
        total_w = host.decode_f32(tw_regs[1], tw_regs[2])
    end

    -- Frequency: 36-37 (F32, Hz)
    local ok_hz, hz_regs = pcall(host.modbus_read, 36, 2, "holding")
    local hz = 0
    if ok_hz then
        hz = host.decode_f32(hz_regs[1], hz_regs[2])
    end

    -- Import energy: 40-41 (F32, kWh -> Wh)
    local ok_imp, imp_regs = pcall(host.modbus_read, 40, 2, "holding")
    local import_wh = 0
    if ok_imp then
        import_wh = host.decode_f32(imp_regs[1], imp_regs[2]) * 1000
    end

    -- Export energy: 42-43 (F32, kWh -> Wh)
    local ok_exp, exp_regs = pcall(host.modbus_read, 42, 2, "holding")
    local export_wh = 0
    if ok_exp then
        export_wh = host.decode_f32(exp_regs[1], exp_regs[2]) * 1000
    end

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
