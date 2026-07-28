-- Schrack i-CHARGE EV Charger Driver (community, untested)
-- Emits: V2X Charger
-- Register type: HOLDING (FC 0x03)
-- Modbus TCP interface, port 502
-- Note: Currents and voltages are U16 with 0.1 scaling factor

PROTOCOL = "modbus"

-- A register the charger never answers costs a failed read on every poll for
-- as long as the driver keeps asking. The host counts those failures against
-- the poll whether or not the pcall caught them, so a driver that keeps
-- reporting telemetry while permanently failing one read gets the whole site
-- marked offline. Give a register three chances, then leave it alone until
-- restart. Three rather than one: a single failure is not proof, the link may
-- just have been slow.
--
-- This driver is read-only — every read below is on the poll path, so none of
-- them can veto a later command.
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
            "Schrack: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

function driver_init(config)
    host.set_make("Schrack")
end

function driver_poll()
    -- Charger state: 100 (U16: 0=idle, 1=connected, 2=charging, 3=error)
    local st_regs = probe_read(100, 1, "holding")
    local raw_state = 0
    local state = 0
    if st_regs then
        raw_state = st_regs[1]
        -- Map Schrack states to standard: 0=idle, 1=connected, 2=charging, 3=error
        if raw_state == 0 then
            state = 0      -- idle -> idle
        elseif raw_state == 1 then
            state = 1      -- connected -> connected
        elseif raw_state == 2 then
            state = 2      -- charging -> charging
        elseif raw_state == 3 then
            state = 3      -- error -> error
        end
    end

    -- L1 current: 200 (U16, 0.1A), L2: 201, L3: 202
    local a_regs = probe_read(200, 3, "holding")
    local l1_a, l2_a, l3_a = 0, 0, 0
    if a_regs then
        l1_a = a_regs[1] * 0.1
        l2_a = a_regs[2] * 0.1
        l3_a = a_regs[3] * 0.1
    end

    -- L1 voltage: 203 (U16, 0.1V), L2: 204, L3: 205
    local v_regs = probe_read(203, 3, "holding")
    local l1_v, l2_v, l3_v = 0, 0, 0
    if v_regs then
        l1_v = v_regs[1] * 0.1
        l2_v = v_regs[2] * 0.1
        l3_v = v_regs[3] * 0.1
    end

    -- Active power: 206 (U32, W)
    local w_regs = probe_read(206, 2, "holding")
    local power_w = 0
    if w_regs then
        power_w = host.decode_u32_be(w_regs[1], w_regs[2])
    end

    -- Session energy: 210 (U32, Wh)
    local se_regs = probe_read(210, 2, "holding")
    local session_wh = 0
    if se_regs then
        session_wh = host.decode_u32_be(se_regs[1], se_regs[2])
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
