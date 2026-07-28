-- Mennekes AMTRON EV Charger Driver (community, untested)
-- Emits: V2X Charger
-- Register type: HOLDING (FC 0x03)
-- Values use 0.1 scaling for current and voltage

PROTOCOL = "modbus"

-- The host counts every failed modbus_read against the poll whether or not
-- Lua caught it, so a register this wallbox does not answer -- a single-phase
-- AMTRON has no L2/L3 block -- costs a failed read on every poll forever and
-- the stale-telemetry watchdog takes the site offline. Ask three times, since
-- one miss can just be a slow link, then leave the register alone. A restart
-- re-probes.
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
            "Mennekes: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

function driver_init(config)
    host.set_make("Mennekes")
end

function driver_poll()
    -- Charger state: 100 (U16: 0=idle, 1=connected, 2=charging)
    local st_regs = probe_read(100, 1, "holding")
    local raw_state = 0
    local state = 0
    if st_regs then
        raw_state = st_regs[1]
        -- Map Mennekes states to standard: 0=idle, 1=connected, 2=charging, 3=error
        if raw_state == 0 then
            state = 0      -- idle -> idle
        elseif raw_state == 1 then
            state = 1      -- connected -> connected
        elseif raw_state == 2 then
            state = 2      -- charging -> charging
        end
    end

    -- L1 current: 200 (U16, 0.1A), L2: 202, L3: 204
    local a1_regs = probe_read(200, 1, "holding")
    local l1_a = 0
    if a1_regs then
        l1_a = a1_regs[1] * 0.1
    end

    local a2_regs = probe_read(202, 1, "holding")
    local l2_a = 0
    if a2_regs then
        l2_a = a2_regs[1] * 0.1
    end

    local a3_regs = probe_read(204, 1, "holding")
    local l3_a = 0
    if a3_regs then
        l3_a = a3_regs[1] * 0.1
    end

    -- L1 voltage: 206 (U16, 0.1V), L2: 208, L3: 210
    local v1_regs = probe_read(206, 1, "holding")
    local l1_v = 0
    if v1_regs then
        l1_v = v1_regs[1] * 0.1
    end

    local v2_regs = probe_read(208, 1, "holding")
    local l2_v = 0
    if v2_regs then
        l2_v = v2_regs[1] * 0.1
    end

    local v3_regs = probe_read(210, 1, "holding")
    local l3_v = 0
    if v3_regs then
        l3_v = v3_regs[1] * 0.1
    end

    -- Active power: 212 (U32, W)
    local w_regs = probe_read(212, 2, "holding")
    local power_w = 0
    if w_regs then
        power_w = host.decode_u32_be(w_regs[1], w_regs[2])
    end

    -- Session energy: 216 (U32, Wh)
    local se_regs = probe_read(216, 2, "holding")
    local session_wh = 0
    if se_regs then
        session_wh = host.decode_u32_be(se_regs[1], se_regs[2])
    end

    -- Max current: 300 (U16, 0.1A) -- writable
    local mc_regs = probe_read(300, 1, "holding")
    local max_a = 0
    if mc_regs then
        max_a = mc_regs[1] * 0.1
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
