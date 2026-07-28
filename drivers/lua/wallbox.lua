-- Wallbox Commander 2 EV Charger Driver (community, untested)
-- Emits: V2X Charger
-- Register type: HOLDING (FC 0x03)
-- Note: Limited register set -- no per-phase voltage/current available

PROTOCOL = "modbus"

-- Bounded register probe.
-- The host counts every failed host.modbus_read against the poll, even one
-- pcall caught here. A driver that keeps emitting while a register keeps
-- failing is marked offline by the stale-telemetry watchdog, and the site
-- then reports nothing at all. So: three tries, then leave the register
-- alone. Three rather than one because a single failure is not proof the
-- register is missing -- the link may just have been slow.
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
            "Wallbox: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

function driver_init(config)
    host.set_make("Wallbox")
end

function driver_poll()
    -- Charger state: 0 (U16: 0=ready, 1=charging, 2=waiting, 3=disconnected)
    local st_regs = probe_read(0, 1, "holding")
    local raw_state = 0
    local state = 0
    if st_regs then
        raw_state = st_regs[1]
        -- Map Wallbox states to standard: 0=idle, 1=connected, 2=charging, 3=error
        if raw_state == 0 then
            state = 1      -- ready -> connected
        elseif raw_state == 1 then
            state = 2      -- charging -> charging
        elseif raw_state == 2 then
            state = 1      -- waiting -> connected
        elseif raw_state == 3 then
            state = 0      -- disconnected -> idle
        end
    end

    -- Active power: 4-5 (U32, W)
    local w_regs = probe_read(4, 2, "holding")
    local power_w = 0
    if w_regs then
        power_w = host.decode_u32_be(w_regs[1], w_regs[2])
    end

    -- Session energy: 7 (U32, Wh)
    local se_regs = probe_read(7, 2, "holding")
    local session_wh = 0
    if se_regs then
        session_wh = host.decode_u32_be(se_regs[1], se_regs[2])
    end

    -- Max current: 9 (U16, A) -- writable
    local mc_regs = probe_read(9, 1, "holding")
    local max_a = 0
    if mc_regs then
        max_a = mc_regs[1]
    end

    -- Emit V2X charger telemetry
    host.emit("v2x_charger", {
        w                = power_w,
        session_charge_wh = session_wh,
    })

    return 5000
end

function driver_cleanup()
end
