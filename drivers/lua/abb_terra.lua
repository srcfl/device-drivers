-- ABB Terra AC EV Charger Driver (community, untested)
-- Emits: V2X Charger
-- Register type: HOLDING (FC 0x03)
-- All values are U16 or U32 with scaling factors

PROTOCOL = "modbus"

function driver_init(config)
    host.set_make("ABB")
end

function driver_poll()
    -- Charger state: 1000 (U16: 0=not connected, 1=connected, 2=charging, 3=error)
    local ok_st, st_regs = pcall(host.modbus_read, 1000, 1, "holding")
    local raw_state = 0
    local state = 0
    if ok_st then
        raw_state = st_regs[1]
        -- Map ABB states to standard: 0=idle, 1=connected, 2=charging, 3=error
        if raw_state == 0 then
            state = 0      -- not connected -> idle
        elseif raw_state == 1 then
            state = 1      -- connected -> connected
        elseif raw_state == 2 then
            state = 2      -- charging -> charging
        elseif raw_state == 3 then
            state = 3      -- error -> error
        end
    end

    -- Max current: 1001 (U16, 0.001A) -- writable for control
    local ok_mc, mc_regs = pcall(host.modbus_read, 1001, 1, "holding")
    local max_a = 0
    if ok_mc then
        max_a = mc_regs[1] * 0.001
    end

    -- Active power: 1025 (U16, W)
    local ok_w, w_regs = pcall(host.modbus_read, 1025, 1, "holding")
    local power_w = 0
    if ok_w then
        power_w = w_regs[1]
    end

    -- L1 voltage: 1026 (U16, 0.1V), L2: 1027, L3: 1028
    local ok_v, v_regs = pcall(host.modbus_read, 1026, 3, "holding")
    local l1_v, l2_v, l3_v = 0, 0, 0
    if ok_v then
        l1_v = v_regs[1] * 0.1
        l2_v = v_regs[2] * 0.1
        l3_v = v_regs[3] * 0.1
    end

    -- L1 current: 1029 (U16, 0.001A), L2: 1030, L3: 1031
    local ok_a, a_regs = pcall(host.modbus_read, 1029, 3, "holding")
    local l1_a, l2_a, l3_a = 0, 0, 0
    if ok_a then
        l1_a = a_regs[1] * 0.001
        l2_a = a_regs[2] * 0.001
        l3_a = a_regs[3] * 0.001
    end

    -- Session energy: 1036 (U32, Wh)
    local ok_se, se_regs = pcall(host.modbus_read, 1036, 2, "holding")
    local session_wh = 0
    if ok_se then
        session_wh = host.decode_u32(se_regs[1], se_regs[2])
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
