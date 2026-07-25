-- Alfen Eve NG9xx EV Charger Driver (community, untested)
-- Emits: V2X Charger
-- Register type: HOLDING (FC 0x03)
-- All multi-register values are F32 BE unless noted

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
    host.set_make("Alfen")
end

function driver_poll()
    -- L1 current: 320 (F32, A), L2: 322, L3: 324
    local ok_a, a_regs = pcall(host.modbus_read, 320, 6, "holding")
    local l1_a, l2_a, l3_a = 0, 0, 0
    if ok_a then
        l1_a = decode_f32_be(a_regs[1], a_regs[2])
        l2_a = decode_f32_be(a_regs[3], a_regs[4])
        l3_a = decode_f32_be(a_regs[5], a_regs[6])
    end

    -- L1 voltage: 326 (F32, V), L2: 328, L3: 330
    local ok_v, v_regs = pcall(host.modbus_read, 326, 6, "holding")
    local l1_v, l2_v, l3_v = 0, 0, 0
    if ok_v then
        l1_v = decode_f32_be(v_regs[1], v_regs[2])
        l2_v = decode_f32_be(v_regs[3], v_regs[4])
        l3_v = decode_f32_be(v_regs[5], v_regs[6])
    end

    -- Active power: 344 (F32, W)
    local ok_w, w_regs = pcall(host.modbus_read, 344, 2, "holding")
    local power_w = 0
    if ok_w then
        power_w = decode_f32_be(w_regs[1], w_regs[2])
    end

    -- Session energy: 346 (F32, Wh)
    local ok_se, se_regs = pcall(host.modbus_read, 346, 2, "holding")
    local session_wh = 0
    if ok_se then
        session_wh = decode_f32_be(se_regs[1], se_regs[2])
    end

    -- Charger state: 1201 (U16: 0=unavailable, 1=available, 2=occupied, 3=charging)
    local ok_st, st_regs = pcall(host.modbus_read, 1201, 1, "holding")
    local raw_state = 0
    local state = 0
    if ok_st then
        raw_state = st_regs[1]
        -- Map Alfen states to standard: 0=idle, 1=connected, 2=charging, 3=error
        if raw_state == 0 then
            state = 3      -- unavailable -> error
        elseif raw_state == 1 then
            state = 0      -- available -> idle
        elseif raw_state == 2 then
            state = 1      -- occupied -> connected
        elseif raw_state == 3 then
            state = 2      -- charging -> charging
        end
    end

    -- Max current: 1210 (F32, A)
    local ok_mc, mc_regs = pcall(host.modbus_read, 1210, 2, "holding")
    local max_a = 0
    if ok_mc then
        max_a = decode_f32_be(mc_regs[1], mc_regs[2])
    end

    -- Emit V2X charger telemetry
    host.emit("v2x_charger", {
        w                = power_w,
        session_charge_wh = session_wh,
        l1_v             = l1_v,
        l2_v             = l2_v,
        l3_v             = l3_v,
        l1_a             = l1_a,
        l2_a             = l2_a,
        l3_a             = l3_a,
    })

    return 5000
end

function driver_cleanup()
end
