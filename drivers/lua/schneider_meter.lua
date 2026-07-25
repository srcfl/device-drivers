-- Schneider Electric iEM3xxx/PM5xxx Meter Driver
-- Emits: Meter only
-- Register type: HOLDING (FC 0x03)
-- Float32 for analog values, U32 for energy counters
-- Default port 502, unit ID 1

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
    host.set_make("Schneider Electric")
end

function driver_poll()
    -- Per-phase current: 2999-3000, 3001-3002, 3003-3004 (F32, A)
    local ok_a, a_regs = pcall(host.modbus_read, 2999, 6, "holding")
    local l1_a, l2_a, l3_a = 0, 0, 0
    if ok_a then
        l1_a = decode_f32_be(a_regs[1], a_regs[2])
        l2_a = decode_f32_be(a_regs[3], a_regs[4])
        l3_a = decode_f32_be(a_regs[5], a_regs[6])
    end

    -- Per-phase voltage L-N: 3027-3028, 3029-3030, 3031-3032 (F32, V)
    local ok_v, v_regs = pcall(host.modbus_read, 3027, 6, "holding")
    local l1_v, l2_v, l3_v = 0, 0, 0
    if ok_v then
        l1_v = decode_f32_be(v_regs[1], v_regs[2])
        l2_v = decode_f32_be(v_regs[3], v_regs[4])
        l3_v = decode_f32_be(v_regs[5], v_regs[6])
    end

    -- Per-phase power: 3053-3054, 3055-3056, 3057-3058 (F32, W)
    local ok_w, w_regs = pcall(host.modbus_read, 3053, 6, "holding")
    local l1_w, l2_w, l3_w = 0, 0, 0
    if ok_w then
        l1_w = decode_f32_be(w_regs[1], w_regs[2])
        l2_w = decode_f32_be(w_regs[3], w_regs[4])
        l3_w = decode_f32_be(w_regs[5], w_regs[6])
    end

    -- Total active power: 3059-3060 (F32, W)
    local ok_tw, tw_regs = pcall(host.modbus_read, 3059, 2, "holding")
    local total_w = 0
    if ok_tw then
        total_w = decode_f32_be(tw_regs[1], tw_regs[2])
    end

    -- Frequency: 3109-3110 (F32, Hz)
    local ok_hz, hz_regs = pcall(host.modbus_read, 3109, 2, "holding")
    local hz = 0
    if ok_hz then
        hz = decode_f32_be(hz_regs[1], hz_regs[2])
    end

    -- Import active energy: 3203-3204 (I64, Wh — read high U32 pair)
    local ok_imp, imp_regs = pcall(host.modbus_read, 3203, 4, "holding")
    local import_wh = 0
    if ok_imp then
        import_wh = host.decode_u32_be(imp_regs[1], imp_regs[2])
    end

    -- Export active energy: 3207-3208 (I64, Wh — read high U32 pair)
    local ok_exp, exp_regs = pcall(host.modbus_read, 3207, 4, "holding")
    local export_wh = 0
    if ok_exp then
        export_wh = host.decode_u32_be(exp_regs[1], exp_regs[2])
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
