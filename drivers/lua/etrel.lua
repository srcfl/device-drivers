-- Etrel INCH EV Charger Driver (community, untested)
-- Emits: V2X Charger
-- Register type: HOLDING (FC 0x03)
-- Modbus TCP interface, port 502
-- Note: Currents and voltages are U16 with 0.1 scaling factor

PROTOCOL = "modbus"

function driver_init(config)
    host.set_make("Etrel")
end

function driver_poll()
    -- Active power: 300 (U32, W)
    local ok_w, w_regs = pcall(host.modbus_read, 300, 2, "holding")
    local power_w = 0
    if ok_w then
        power_w = host.decode_u32(w_regs[1], w_regs[2])
    end

    -- Session energy: 304 (U32, Wh)
    local ok_se, se_regs = pcall(host.modbus_read, 304, 2, "holding")
    local session_wh = 0
    if ok_se then
        session_wh = host.decode_u32(se_regs[1], se_regs[2])
    end

    -- L1 current: 306 (U16, 0.1A), L2: 307, L3: 308
    local ok_a, a_regs = pcall(host.modbus_read, 306, 3, "holding")
    local l1_a, l2_a, l3_a = 0, 0, 0
    if ok_a then
        l1_a = a_regs[1] * 0.1
        l2_a = a_regs[2] * 0.1
        l3_a = a_regs[3] * 0.1
    end

    -- L1 voltage: 309 (U16, 0.1V), L2: 310, L3: 311
    local ok_v, v_regs = pcall(host.modbus_read, 309, 3, "holding")
    local l1_v, l2_v, l3_v = 0, 0, 0
    if ok_v then
        l1_v = v_regs[1] * 0.1
        l2_v = v_regs[2] * 0.1
        l3_v = v_regs[3] * 0.1
    end

    -- Charger state: 312 (U16: 0=idle, 1=connected, 2=charging, 3=error)
    local ok_st, st_regs = pcall(host.modbus_read, 312, 1, "holding")
    local raw_state = 0
    local state = 0
    if ok_st then
        raw_state = st_regs[1]
        -- Map Etrel states to standard: 0=idle, 1=connected, 2=charging, 3=error
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
