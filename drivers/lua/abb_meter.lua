-- ABB B23/B24/M4M Three-Phase Meter Driver
-- Emits: Meter only
-- Register type: HOLDING (FC 0x03)
-- U32/I32 with scaling, U16 for frequency
-- Default port 502

PROTOCOL = "modbus"

function driver_init(config)
    host.set_make("ABB")
end

function driver_poll()
    -- Per-phase voltage: 23296(0x5B00), 23298, 23300 (U32, 0.1V)
    local ok_v, v_regs = pcall(host.modbus_read, 23296, 6, "holding")
    local l1_v, l2_v, l3_v = 0, 0, 0
    if ok_v then
        l1_v = host.decode_u32(v_regs[1], v_regs[2]) * 0.1
        l2_v = host.decode_u32(v_regs[3], v_regs[4]) * 0.1
        l3_v = host.decode_u32(v_regs[5], v_regs[6]) * 0.1
    end

    -- Per-phase current: 23308(0x5B0C), 23310, 23312 (U32, 0.01A)
    local ok_a, a_regs = pcall(host.modbus_read, 23308, 6, "holding")
    local l1_a, l2_a, l3_a = 0, 0, 0
    if ok_a then
        l1_a = host.decode_u32(a_regs[1], a_regs[2]) * 0.01
        l2_a = host.decode_u32(a_regs[3], a_regs[4]) * 0.01
        l3_a = host.decode_u32(a_regs[5], a_regs[6]) * 0.01
    end

    -- Total active power: 23316(0x5B14) (I32, 0.01W)
    local ok_tw, tw_regs = pcall(host.modbus_read, 23316, 2, "holding")
    local total_w = 0
    if ok_tw then
        total_w = host.decode_i32(tw_regs[1], tw_regs[2]) * 0.01
    end

    -- Per-phase power: 23318(0x5B16), 23320, 23322 (I32, 0.01W)
    local ok_w, w_regs = pcall(host.modbus_read, 23318, 6, "holding")
    local l1_w, l2_w, l3_w = 0, 0, 0
    if ok_w then
        l1_w = host.decode_i32(w_regs[1], w_regs[2]) * 0.01
        l2_w = host.decode_i32(w_regs[3], w_regs[4]) * 0.01
        l3_w = host.decode_i32(w_regs[5], w_regs[6]) * 0.01
    end

    -- Frequency: 23340(0x5B2C) (U16, 0.01Hz)
    local ok_hz, hz_regs = pcall(host.modbus_read, 23340, 1, "holding")
    local hz = 0
    if ok_hz then
        hz = hz_regs[1] * 0.01
    end

    -- Import energy: 20480(0x5000) (U64 -> use high U32, 0.01kWh -> Wh)
    local ok_imp, imp_regs = pcall(host.modbus_read, 20480, 4, "holding")
    local import_wh = 0
    if ok_imp then
        import_wh = host.decode_u32(imp_regs[1], imp_regs[2]) * 10
    end

    -- Export energy: 20484(0x5004) (U64 -> use high U32, 0.01kWh -> Wh)
    local ok_exp, exp_regs = pcall(host.modbus_read, 20484, 4, "holding")
    local export_wh = 0
    if ok_exp then
        export_wh = host.decode_u32(exp_regs[1], exp_regs[2]) * 10
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
