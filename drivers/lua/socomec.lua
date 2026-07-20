-- Socomec Diris A-10/A-20/A-40 Three-Phase Meter Driver
-- Emits: Meter only
-- Register type: HOLDING (FC 0x03)
-- U32/I32 with scaling
-- Default port 502

PROTOCOL = "modbus"

function driver_init(config)
    host.set_make("Socomec")
end

function driver_poll()
    -- Per-phase voltage: 50520(0xC558), 50522, 50524 (U32, V)
    local ok_v, v_regs = pcall(host.modbus_read, 50520, 6, "holding")
    local l1_v, l2_v, l3_v = 0, 0, 0
    if ok_v then
        l1_v = host.decode_u32(v_regs[1], v_regs[2])
        l2_v = host.decode_u32(v_regs[3], v_regs[4])
        l3_v = host.decode_u32(v_regs[5], v_regs[6])
    end

    -- Per-phase current: 50528(0xC560), 50530, 50532 (U32, mA -> A)
    local ok_a, a_regs = pcall(host.modbus_read, 50528, 6, "holding")
    local l1_a, l2_a, l3_a = 0, 0, 0
    if ok_a then
        l1_a = host.decode_u32(a_regs[1], a_regs[2]) * 0.001
        l2_a = host.decode_u32(a_regs[3], a_regs[4]) * 0.001
        l3_a = host.decode_u32(a_regs[5], a_regs[6]) * 0.001
    end

    -- Total power: 50540(0xC56C) (I32, W)
    local ok_tw, tw_regs = pcall(host.modbus_read, 50540, 2, "holding")
    local total_w = 0
    if ok_tw then
        total_w = host.decode_i32(tw_regs[1], tw_regs[2])
    end

    -- Per-phase power: 50542(0xC56E), 50544, 50546 (I32, W)
    local ok_w, w_regs = pcall(host.modbus_read, 50542, 6, "holding")
    local l1_w, l2_w, l3_w = 0, 0, 0
    if ok_w then
        l1_w = host.decode_i32(w_regs[1], w_regs[2])
        l2_w = host.decode_i32(w_regs[3], w_regs[4])
        l3_w = host.decode_i32(w_regs[5], w_regs[6])
    end

    -- Frequency: 50552(0xC578) (U32, 0.01Hz)
    local ok_hz, hz_regs = pcall(host.modbus_read, 50552, 2, "holding")
    local hz = 0
    if ok_hz then
        hz = host.decode_u32(hz_regs[1], hz_regs[2]) * 0.01
    end

    -- Import energy: 50770(0xC652) (U32+U32 -> high pair, Wh)
    local ok_imp, imp_regs = pcall(host.modbus_read, 50770, 4, "holding")
    local import_wh = 0
    if ok_imp then
        import_wh = host.decode_u32(imp_regs[1], imp_regs[2])
    end

    -- Export energy: 50782(0xC65E) (U32, Wh)
    local ok_exp, exp_regs = pcall(host.modbus_read, 50782, 2, "holding")
    local export_wh = 0
    if ok_exp then
        export_wh = host.decode_u32(exp_regs[1], exp_regs[2])
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
