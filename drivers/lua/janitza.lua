-- Janitza UMG 96/604/806 Three-Phase Meter Driver
-- Emits: Meter only
-- Register type: HOLDING (FC 0x03)
-- All values are F32 Big-Endian
-- Default port 502

PROTOCOL = "modbus"

-- IEEE-754 float32 from two big-endian registers. Kept in Lua so the driver
-- does not depend on a host helper: this is arithmetic, not I/O.
local function decode_f32_be(hi, lo)
    -- Work on the 16-bit halves. Combining them first overflows a 32-bit
    -- integer build, where 0x80000000 is negative and every value then
    -- decodes with a flipped sign.
    local sign = 1
    if hi >= 0x8000 then sign = -1; hi = hi - 0x8000 end
    local exponent = math.floor(hi / 128)
    local mantissa = (hi % 128) * 65536 + lo
    if exponent == 0 then
        if mantissa == 0 then return 0 end
        return sign * mantissa * 2^-149
    end
    -- Infinity and NaN would poison every downstream sum; report nothing.
    if exponent == 0xFF then return 0 end
    return sign * (1 + mantissa / 0x800000) * 2^(exponent - 127)
end

function driver_init(config)
    host.set_make("Janitza")
end

function driver_poll()
    -- Per-phase voltage: 19000-19001, 19002-19003, 19004-19005 (F32, V)
    local ok_v, v_regs = pcall(host.modbus_read, 19000, 6, "holding")
    local l1_v, l2_v, l3_v = 0, 0, 0
    if ok_v then
        l1_v = decode_f32_be(v_regs[1], v_regs[2])
        l2_v = decode_f32_be(v_regs[3], v_regs[4])
        l3_v = decode_f32_be(v_regs[5], v_regs[6])
    end

    -- Per-phase current: 19006-19007, 19008-19009, 19010-19011 (F32, A)
    local ok_a, a_regs = pcall(host.modbus_read, 19006, 6, "holding")
    local l1_a, l2_a, l3_a = 0, 0, 0
    if ok_a then
        l1_a = decode_f32_be(a_regs[1], a_regs[2])
        l2_a = decode_f32_be(a_regs[3], a_regs[4])
        l3_a = decode_f32_be(a_regs[5], a_regs[6])
    end

    -- Per-phase power: 19020-19021, 19022-19023, 19024-19025 (F32, W)
    local ok_w, w_regs = pcall(host.modbus_read, 19020, 6, "holding")
    local l1_w, l2_w, l3_w = 0, 0, 0
    if ok_w then
        l1_w = decode_f32_be(w_regs[1], w_regs[2])
        l2_w = decode_f32_be(w_regs[3], w_regs[4])
        l3_w = decode_f32_be(w_regs[5], w_regs[6])
    end

    -- Total power: 19026-19027 (F32, W)
    local ok_tw, tw_regs = pcall(host.modbus_read, 19026, 2, "holding")
    local total_w = 0
    if ok_tw then
        total_w = decode_f32_be(tw_regs[1], tw_regs[2])
    end

    -- Frequency: 19050-19051 (F32, Hz)
    local ok_hz, hz_regs = pcall(host.modbus_read, 19050, 2, "holding")
    local hz = 0
    if ok_hz then
        hz = decode_f32_be(hz_regs[1], hz_regs[2])
    end

    -- Import energy: 19060-19061 (F32, Wh)
    local ok_imp, imp_regs = pcall(host.modbus_read, 19060, 2, "holding")
    local import_wh = 0
    if ok_imp then
        import_wh = decode_f32_be(imp_regs[1], imp_regs[2])
    end

    -- Export energy: 19062-19063 (F32, Wh)
    local ok_exp, exp_regs = pcall(host.modbus_read, 19062, 2, "holding")
    local export_wh = 0
    if ok_exp then
        export_wh = decode_f32_be(exp_regs[1], exp_regs[2])
    end

    host.emit("meter", {
        W         = total_w,
        L1_W      = l1_w,
        L2_W      = l2_w,
        L3_W      = l3_w,
        L1_V      = l1_v,
        L2_V      = l2_v,
        L3_V      = l3_v,
        L1_A      = l1_a,
        L2_A      = l2_a,
        L3_A      = l3_a,
        Hz        = hz,
        total_import_Wh = import_wh,
        total_export_Wh = export_wh,
    })

    return 5000
end

function driver_cleanup()
    -- nothing to clean up
end
