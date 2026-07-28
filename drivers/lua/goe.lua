-- go-e Charger Gemini Driver (community, untested)
-- Emits: V2X Charger
-- Register type: HOLDING (FC 0x03)
-- Modbus TCP interface

PROTOCOL = "modbus"

----------------------------------------------------------------------------
-- Absent-register guard
----------------------------------------------------------------------------
-- The host counts every failed modbus_read against the poll whether or not
-- Lua caught it. So a register this driver can live without must stop being
-- read once the device has made clear it will not answer — otherwise the
-- poll keeps failing, the stale-telemetry watchdog marks the charger
-- offline, and the site reports nothing at all instead of one field less.
--
-- Three strikes rather than one: a single miss is more often a slow link
-- than a missing register. A restart re-probes.
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
            "go-e: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

function driver_init(config)
    host.set_make("go-e")
end

function driver_poll()
    -- Charger state: 0 (U16: 1=ready, 2=charging, 3=waiting, 4=complete)
    local st_regs = probe_read(0, 1, "holding")
    local raw_state = 0
    local state = 0
    if st_regs then
        raw_state = st_regs[1]
        -- Map go-e states to standard: 0=idle, 1=connected, 2=charging, 3=error
        if raw_state == 1 then
            state = 0      -- ready -> idle
        elseif raw_state == 2 then
            state = 2      -- charging -> charging
        elseif raw_state == 3 then
            state = 1      -- waiting -> connected
        elseif raw_state == 4 then
            state = 0      -- complete -> idle
        end
    end

    -- Max current: 3 (U16, 0.1A) -- writable
    local mc_regs = probe_read(3, 1, "holding")
    local max_a = 0
    if mc_regs then
        max_a = mc_regs[1] * 0.1
    end

    -- L1 current: 6 (U16, 0.001A), L2: 7, L3: 8
    local a_regs = probe_read(6, 3, "holding")
    local l1_a, l2_a, l3_a = 0, 0, 0
    if a_regs then
        l1_a = a_regs[1] * 0.001
        l2_a = a_regs[2] * 0.001
        l3_a = a_regs[3] * 0.001
    end

    -- L1 voltage: 9 (U16, V), L2: 10, L3: 11
    local v_regs = probe_read(9, 3, "holding")
    local l1_v, l2_v, l3_v = 0, 0, 0
    if v_regs then
        l1_v = v_regs[1]
        l2_v = v_regs[2]
        l3_v = v_regs[3]
    end

    -- Session energy: 12-13 (U32, Wh)
    local se_regs = probe_read(12, 2, "holding")
    local session_wh = 0
    if se_regs then
        session_wh = host.decode_u32_be(se_regs[1], se_regs[2])
    end

    -- Active power: 14-15 (U32, 0.01W)
    local w_regs = probe_read(14, 2, "holding")
    local power_w = 0
    if w_regs then
        power_w = host.decode_u32_be(w_regs[1], w_regs[2]) * 0.01
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
