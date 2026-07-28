-- Carlo Gavazzi EM24/EM340 Three-Phase Meter Driver
-- Emits: Meter only
-- Register type: HOLDING (FC 0x03)
-- All values are F32 Big-Endian
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

-- A register the meter never answers costs a failed read on every poll for as
-- long as the driver keeps asking. The host counts those failures against the
-- poll whether or not the pcall caught them, so a driver that keeps reporting
-- telemetry while permanently failing one read gets the whole site marked
-- offline. Give a register three chances, then leave it alone until restart.
-- Three rather than one: a single failure is not proof, the link may just
-- have been slow.
local GIVE_UP_AFTER = 3
local read_failures = {}

local function probe_read(addr, count, kind)
    if (read_failures[addr] or 0) >= GIVE_UP_AFTER then return nil end
    local ok, regs = pcall(host.modbus_read, addr, count, kind)
    if ok and regs and regs[1] ~= nil then
        read_failures[addr] = nil
        return regs
    end
    local failures = (read_failures[addr] or 0) + 1
    read_failures[addr] = failures
    if failures == GIVE_UP_AFTER then
        host.log("info", string.format(
            "Carlo Gavazzi: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

function driver_init(config)
    host.set_make("Carlo Gavazzi")
end

function driver_poll()
    -- Per-phase voltage: 0-1, 2-3, 4-5 (F32, V)
    local v_regs = probe_read(0, 6, "holding")
    local l1_v, l2_v, l3_v = 0, 0, 0
    if v_regs then
        l1_v = decode_f32_be(v_regs[1], v_regs[2])
        l2_v = decode_f32_be(v_regs[3], v_regs[4])
        l3_v = decode_f32_be(v_regs[5], v_regs[6])
    end

    -- Per-phase current: 6-7, 8-9, 10-11 (F32, A)
    local a_regs = probe_read(6, 6, "holding")
    local l1_a, l2_a, l3_a = 0, 0, 0
    if a_regs then
        l1_a = decode_f32_be(a_regs[1], a_regs[2])
        l2_a = decode_f32_be(a_regs[3], a_regs[4])
        l3_a = decode_f32_be(a_regs[5], a_regs[6])
    end

    -- Per-phase power: 12-13, 14-15, 16-17 (F32, W)
    local w_regs = probe_read(12, 6, "holding")
    local l1_w, l2_w, l3_w = 0, 0, 0
    if w_regs then
        l1_w = decode_f32_be(w_regs[1], w_regs[2])
        l2_w = decode_f32_be(w_regs[3], w_regs[4])
        l3_w = decode_f32_be(w_regs[5], w_regs[6])
    end

    -- Total power: 40-41 (F32, W)
    local tw_regs = probe_read(40, 2, "holding")
    local total_w = 0
    if tw_regs then
        total_w = decode_f32_be(tw_regs[1], tw_regs[2])
    end

    -- Frequency: 46-47 (F32, Hz)
    local hz_regs = probe_read(46, 2, "holding")
    local hz = 0
    if hz_regs then
        hz = decode_f32_be(hz_regs[1], hz_regs[2])
    end

    -- Import energy: 52-53 (F32, kWh -> Wh)
    local imp_regs = probe_read(52, 2, "holding")
    local import_wh = 0
    if imp_regs then
        import_wh = decode_f32_be(imp_regs[1], imp_regs[2]) * 1000
    end

    -- Export energy: 78-79 (F32, kWh -> Wh)
    local exp_regs = probe_read(78, 2, "holding")
    local export_wh = 0
    if exp_regs then
        export_wh = decode_f32_be(exp_regs[1], exp_regs[2]) * 1000
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
