-- Chint DDSU666/DTSU666 Meter Driver
-- Emits: Meter only
-- Register type: HOLDING (FC 0x03)
-- All values are F32 Big-Endian
-- DDSU666 is single-phase; DTSU666 is three-phase
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
    host.set_make("Chint")
end

function driver_poll()
    -- Per-phase voltage: 8192(0x2000), 8194(0x2002) (F32, V)
    -- DDSU666 is single-phase (L1 only); DTSU666 has L1+L2
    local ok_v, v_regs = pcall(host.modbus_read, 8192, 4, "holding")
    local l1_v, l2_v, l3_v = 0, 0, 0
    if ok_v then
        l1_v = decode_f32_be(v_regs[1], v_regs[2])
        l2_v = decode_f32_be(v_regs[3], v_regs[4])
    end

    -- Total power: 8196(0x2004) (F32, W)
    local ok_tw, tw_regs = pcall(host.modbus_read, 8196, 2, "holding")
    local total_w = 0
    if ok_tw then
        total_w = decode_f32_be(tw_regs[1], tw_regs[2])
    end

    -- Per-phase current: 8198(0x2006) (F32, A)
    local ok_a, a_regs = pcall(host.modbus_read, 8198, 2, "holding")
    local l1_a, l2_a, l3_a = 0, 0, 0
    if ok_a then
        l1_a = decode_f32_be(a_regs[1], a_regs[2])
    end

    -- Frequency: 8206(0x200E) (F32, Hz)
    local ok_hz, hz_regs = pcall(host.modbus_read, 8206, 2, "holding")
    local hz = 0
    if ok_hz then
        hz = decode_f32_be(hz_regs[1], hz_regs[2])
    end

    -- Import energy: 16384(0x4000) (F32, kWh -> Wh)
    local ok_imp, imp_regs = pcall(host.modbus_read, 16384, 2, "holding")
    local import_wh = 0
    if ok_imp then
        import_wh = decode_f32_be(imp_regs[1], imp_regs[2]) * 1000
    end

    -- Export energy: 16394(0x400A) (F32, kWh -> Wh)
    local ok_exp, exp_regs = pcall(host.modbus_read, 16394, 2, "holding")
    local export_wh = 0
    if ok_exp then
        export_wh = decode_f32_be(exp_regs[1], exp_regs[2]) * 1000
    end

    host.emit("meter", {
        W         = total_w,
        L1_W      = total_w,
        L2_W      = 0,
        L3_W      = 0,
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
