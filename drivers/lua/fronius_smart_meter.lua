-- Fronius Smart Meter Driver
-- Emits: Meter only
-- Register type: ALL HOLDING
-- All values are F32 BE

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
    host.set_make("Fronius")
end

function driver_poll()
    -- Per-phase current: 40074, 40076, 40078 (F32 BE pairs)
    local ok_l1a, l1a_regs = pcall(host.modbus_read, 40074, 2, "holding")
    local l1_a = 0
    if ok_l1a then l1_a = decode_f32_be(l1a_regs[1], l1a_regs[2]) end

    local ok_l2a, l2a_regs = pcall(host.modbus_read, 40076, 2, "holding")
    local l2_a = 0
    if ok_l2a then l2_a = decode_f32_be(l2a_regs[1], l2a_regs[2]) end

    local ok_l3a, l3a_regs = pcall(host.modbus_read, 40078, 2, "holding")
    local l3_a = 0
    if ok_l3a then l3_a = decode_f32_be(l3a_regs[1], l3a_regs[2]) end

    -- Per-phase voltage: 40082, 40084, 40086 (F32 BE pairs)
    local ok_l1v, l1v_regs = pcall(host.modbus_read, 40082, 2, "holding")
    local l1_v = 0
    if ok_l1v then l1_v = decode_f32_be(l1v_regs[1], l1v_regs[2]) end

    local ok_l2v, l2v_regs = pcall(host.modbus_read, 40084, 2, "holding")
    local l2_v = 0
    if ok_l2v then l2_v = decode_f32_be(l2v_regs[1], l2v_regs[2]) end

    local ok_l3v, l3v_regs = pcall(host.modbus_read, 40086, 2, "holding")
    local l3_v = 0
    if ok_l3v then l3_v = decode_f32_be(l3v_regs[1], l3v_regs[2]) end

    -- Frequency: 40096-40097, F32 BE
    local ok_hz, hz_regs = pcall(host.modbus_read, 40096, 2, "holding")
    local hz = 0
    if ok_hz then
        hz = decode_f32_be(hz_regs[1], hz_regs[2])
    end

    -- Total power: 40098-40099, F32 BE, watts
    local ok_tw, tw_regs = pcall(host.modbus_read, 40098, 2, "holding")
    local total_w = 0
    if ok_tw then
        total_w = decode_f32_be(tw_regs[1], tw_regs[2])
    end

    -- Per-phase power: 40100, 40102, 40104 (F32 BE pairs)
    local ok_l1w, l1w_regs = pcall(host.modbus_read, 40100, 2, "holding")
    local l1_w = 0
    if ok_l1w then l1_w = decode_f32_be(l1w_regs[1], l1w_regs[2]) end

    local ok_l2w, l2w_regs = pcall(host.modbus_read, 40102, 2, "holding")
    local l2_w = 0
    if ok_l2w then l2_w = decode_f32_be(l2w_regs[1], l2w_regs[2]) end

    local ok_l3w, l3w_regs = pcall(host.modbus_read, 40104, 2, "holding")
    local l3_w = 0
    if ok_l3w then l3_w = decode_f32_be(l3w_regs[1], l3w_regs[2]) end

    -- Export energy: 40130-40131, F32 BE, Wh
    local ok_exp, exp_regs = pcall(host.modbus_read, 40130, 2, "holding")
    local export_wh = 0
    if ok_exp then
        export_wh = decode_f32_be(exp_regs[1], exp_regs[2])
    end

    -- Import energy: 40138-40139, F32 BE, Wh
    local ok_imp, imp_regs = pcall(host.modbus_read, 40138, 2, "holding")
    local import_wh = 0
    if ok_imp then
        import_wh = decode_f32_be(imp_regs[1], imp_regs[2])
    end

    -- Emit Meter telemetry (all F32 direct)
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
