-- Easee Home/Charge EV Charger Driver (community, untested)
-- Emits: V2X Charger
-- Register type: HOLDING (FC 0x03)
-- Modbus TCP interface, port 502
-- Note: Easee uses F32 for power/energy, U16 for state

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

-- Reading a register the charger does not have costs a failed read on every
-- poll forever, and the host counts those against the poll whether or not Lua
-- caught the error. Enough of them and the site is marked offline and reports
-- nothing at all, which is worse than reporting one field less. So stop asking
-- once a register has proved it is not there. Three tries, because one failure
-- proves nothing -- the link may just have been slow.
--
-- Safe to bound every read here: this driver has no driver_command, so no read
-- below is on a control path where giving up could veto a later command.
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
            "Easee: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

function driver_init(config)
    host.set_make("Easee")
end

function driver_poll()
    -- L1 current: 0 (F32, A), L2: 2
    local a_regs = probe_read(0, 4, "holding")
    local l1_a, l2_a = 0, 0
    if a_regs then
        l1_a = decode_f32_be(a_regs[1], a_regs[2])
        l2_a = decode_f32_be(a_regs[3], a_regs[4])
    end

    -- Active power: 4 (F32, W)
    local w_regs = probe_read(4, 2, "holding")
    local power_w = 0
    if w_regs then
        power_w = decode_f32_be(w_regs[1], w_regs[2])
    end

    -- Session energy: 8 (F32, Wh)
    local se_regs = probe_read(8, 2, "holding")
    local session_wh = 0
    if se_regs then
        session_wh = decode_f32_be(se_regs[1], se_regs[2])
    end

    -- Charger state: 10 (U16: 1=disconnected, 2=awaiting, 3=charging, 4=completed, 5=error)
    local st_regs = probe_read(10, 1, "holding")
    local raw_state = 0
    local state = 0
    if st_regs then
        raw_state = st_regs[1]
        -- Map Easee states to standard: 0=idle, 1=connected, 2=charging, 3=error
        if raw_state == 1 then
            state = 0      -- disconnected -> idle
        elseif raw_state == 2 then
            state = 1      -- awaiting -> connected
        elseif raw_state == 3 then
            state = 2      -- charging -> charging
        elseif raw_state == 4 then
            state = 0      -- completed -> idle
        elseif raw_state == 5 then
            state = 3      -- error -> error
        end
    end

    -- Emit V2X charger telemetry
    host.emit("v2x_charger", {
        w                = power_w,
        session_charge_wh = session_wh,
        l1_a             = l1_a,
        l2_a             = l2_a,
    })

    return 5000
end

function driver_cleanup()
end
