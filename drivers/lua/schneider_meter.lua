-- Schneider Electric iEM3xxx/PM5xxx Meter Driver
-- Emits: Meter only
-- Register type: HOLDING (FC 0x03)
-- Float32 for analog values, U32 for energy counters
-- Default port 502, unit ID 1

PROTOCOL = "modbus"

function driver_init(config)
    host.set_make("Schneider Electric")
end

function driver_poll()
    -- Per-phase current: 2999-3000, 3001-3002, 3003-3004 (F32, A)
    local ok_a, a_regs = pcall(host.modbus_read, 2999, 6, "holding")
    local l1_a, l2_a, l3_a = 0, 0, 0
    if ok_a then
        l1_a = host.decode_f32(a_regs[1], a_regs[2])
        l2_a = host.decode_f32(a_regs[3], a_regs[4])
        l3_a = host.decode_f32(a_regs[5], a_regs[6])
    end

    -- Per-phase voltage L-N: 3027-3028, 3029-3030, 3031-3032 (F32, V)
    local ok_v, v_regs = pcall(host.modbus_read, 3027, 6, "holding")
    local l1_v, l2_v, l3_v = 0, 0, 0
    if ok_v then
        l1_v = host.decode_f32(v_regs[1], v_regs[2])
        l2_v = host.decode_f32(v_regs[3], v_regs[4])
        l3_v = host.decode_f32(v_regs[5], v_regs[6])
    end

    -- Per-phase power: 3053-3054, 3055-3056, 3057-3058 (F32, W)
    local ok_w, w_regs = pcall(host.modbus_read, 3053, 6, "holding")
    local l1_w, l2_w, l3_w = 0, 0, 0
    if ok_w then
        l1_w = host.decode_f32(w_regs[1], w_regs[2])
        l2_w = host.decode_f32(w_regs[3], w_regs[4])
        l3_w = host.decode_f32(w_regs[5], w_regs[6])
    end

    -- Total active power: 3059-3060 (F32, W)
    local ok_tw, tw_regs = pcall(host.modbus_read, 3059, 2, "holding")
    local total_w = 0
    if ok_tw then
        total_w = host.decode_f32(tw_regs[1], tw_regs[2])
    end

    -- Frequency: 3109-3110 (F32, Hz)
    local ok_hz, hz_regs = pcall(host.modbus_read, 3109, 2, "holding")
    local hz = 0
    if ok_hz then
        hz = host.decode_f32(hz_regs[1], hz_regs[2])
    end

    -- Import active energy: 3203-3204 (I64, Wh — read high U32 pair)
    local ok_imp, imp_regs = pcall(host.modbus_read, 3203, 4, "holding")
    local import_wh = 0
    if ok_imp then
        import_wh = host.decode_u32(imp_regs[1], imp_regs[2])
    end

    -- Export active energy: 3207-3208 (I64, Wh — read high U32 pair)
    local ok_exp, exp_regs = pcall(host.modbus_read, 3207, 4, "holding")
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
