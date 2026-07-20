-- Mennekes AMTRON EV Charger Driver (community, untested)
-- Emits: V2X Charger
-- Register type: HOLDING (FC 0x03)
-- Values use 0.1 scaling for current and voltage

PROTOCOL = "modbus"

function driver_init(config)
    host.set_make("Mennekes")
end

function driver_poll()
    -- Charger state: 100 (U16: 0=idle, 1=connected, 2=charging)
    local ok_st, st_regs = pcall(host.modbus_read, 100, 1, "holding")
    local raw_state = 0
    local state = 0
    if ok_st then
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
    local ok_a1, a1_regs = pcall(host.modbus_read, 200, 1, "holding")
    local l1_a = 0
    if ok_a1 then
        l1_a = a1_regs[1] * 0.1
    end

    local ok_a2, a2_regs = pcall(host.modbus_read, 202, 1, "holding")
    local l2_a = 0
    if ok_a2 then
        l2_a = a2_regs[1] * 0.1
    end

    local ok_a3, a3_regs = pcall(host.modbus_read, 204, 1, "holding")
    local l3_a = 0
    if ok_a3 then
        l3_a = a3_regs[1] * 0.1
    end

    -- L1 voltage: 206 (U16, 0.1V), L2: 208, L3: 210
    local ok_v1, v1_regs = pcall(host.modbus_read, 206, 1, "holding")
    local l1_v = 0
    if ok_v1 then
        l1_v = v1_regs[1] * 0.1
    end

    local ok_v2, v2_regs = pcall(host.modbus_read, 208, 1, "holding")
    local l2_v = 0
    if ok_v2 then
        l2_v = v2_regs[1] * 0.1
    end

    local ok_v3, v3_regs = pcall(host.modbus_read, 210, 1, "holding")
    local l3_v = 0
    if ok_v3 then
        l3_v = v3_regs[1] * 0.1
    end

    -- Active power: 212 (U32, W)
    local ok_w, w_regs = pcall(host.modbus_read, 212, 2, "holding")
    local power_w = 0
    if ok_w then
        power_w = host.decode_u32(w_regs[1], w_regs[2])
    end

    -- Session energy: 216 (U32, Wh)
    local ok_se, se_regs = pcall(host.modbus_read, 216, 2, "holding")
    local session_wh = 0
    if ok_se then
        session_wh = host.decode_u32(se_regs[1], se_regs[2])
    end

    -- Max current: 300 (U16, 0.1A) -- writable
    local ok_mc, mc_regs = pcall(host.modbus_read, 300, 1, "holding")
    local max_a = 0
    if ok_mc then
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
