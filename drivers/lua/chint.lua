-- Chint DDSU666/DTSU666 Meter Driver
-- Emits: Meter only
-- Register type: HOLDING (FC 0x03)
-- All values are F32 Big-Endian
-- DDSU666 is single-phase; DTSU666 is three-phase
-- Default port 502

PROTOCOL = "modbus"

function driver_init(config)
    host.set_make("Chint")
end

function driver_poll()
    -- Per-phase voltage: 8192(0x2000), 8194(0x2002) (F32, V)
    -- DDSU666 is single-phase (L1 only); DTSU666 has L1+L2
    local ok_v, v_regs = pcall(host.modbus_read, 8192, 4, "holding")
    local l1_v, l2_v, l3_v = 0, 0, 0
    if ok_v then
        l1_v = host.decode_f32(v_regs[1], v_regs[2])
        l2_v = host.decode_f32(v_regs[3], v_regs[4])
    end

    -- Total power: 8196(0x2004) (F32, W)
    local ok_tw, tw_regs = pcall(host.modbus_read, 8196, 2, "holding")
    local total_w = 0
    if ok_tw then
        total_w = host.decode_f32(tw_regs[1], tw_regs[2])
    end

    -- Per-phase current: 8198(0x2006) (F32, A)
    local ok_a, a_regs = pcall(host.modbus_read, 8198, 2, "holding")
    local l1_a, l2_a, l3_a = 0, 0, 0
    if ok_a then
        l1_a = host.decode_f32(a_regs[1], a_regs[2])
    end

    -- Frequency: 8206(0x200E) (F32, Hz)
    local ok_hz, hz_regs = pcall(host.modbus_read, 8206, 2, "holding")
    local hz = 0
    if ok_hz then
        hz = host.decode_f32(hz_regs[1], hz_regs[2])
    end

    -- Import energy: 16384(0x4000) (F32, kWh -> Wh)
    local ok_imp, imp_regs = pcall(host.modbus_read, 16384, 2, "holding")
    local import_wh = 0
    if ok_imp then
        import_wh = host.decode_f32(imp_regs[1], imp_regs[2]) * 1000
    end

    -- Export energy: 16394(0x400A) (F32, kWh -> Wh)
    local ok_exp, exp_regs = pcall(host.modbus_read, 16394, 2, "holding")
    local export_wh = 0
    if ok_exp then
        export_wh = host.decode_f32(exp_regs[1], exp_regs[2]) * 1000
    end

    host.emit("meter", {
        w         = total_w,
        l1_w      = total_w,
        l2_w      = 0,
        l3_w      = 0,
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
