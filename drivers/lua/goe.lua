-- go-e Charger Gemini Driver (community, untested)
-- Emits: V2X Charger
-- Register type: HOLDING (FC 0x03)
-- Modbus TCP interface

PROTOCOL = "modbus"

function driver_init(config)
    host.set_make("go-e")
end

function driver_poll()
    -- Charger state: 0 (U16: 1=ready, 2=charging, 3=waiting, 4=complete)
    local ok_st, st_regs = pcall(host.modbus_read, 0, 1, "holding")
    local raw_state = 0
    local state = 0
    if ok_st then
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
    local ok_mc, mc_regs = pcall(host.modbus_read, 3, 1, "holding")
    local max_a = 0
    if ok_mc then
        max_a = mc_regs[1] * 0.1
    end

    -- L1 current: 6 (U16, 0.001A), L2: 7, L3: 8
    local ok_a, a_regs = pcall(host.modbus_read, 6, 3, "holding")
    local l1_a, l2_a, l3_a = 0, 0, 0
    if ok_a then
        l1_a = a_regs[1] * 0.001
        l2_a = a_regs[2] * 0.001
        l3_a = a_regs[3] * 0.001
    end

    -- L1 voltage: 9 (U16, V), L2: 10, L3: 11
    local ok_v, v_regs = pcall(host.modbus_read, 9, 3, "holding")
    local l1_v, l2_v, l3_v = 0, 0, 0
    if ok_v then
        l1_v = v_regs[1]
        l2_v = v_regs[2]
        l3_v = v_regs[3]
    end

    -- Session energy: 12-13 (U32, Wh)
    local ok_se, se_regs = pcall(host.modbus_read, 12, 2, "holding")
    local session_wh = 0
    if ok_se then
        session_wh = host.decode_u32(se_regs[1], se_regs[2])
    end

    -- Active power: 14-15 (U32, 0.01W)
    local ok_w, w_regs = pcall(host.modbus_read, 14, 2, "holding")
    local power_w = 0
    if ok_w then
        power_w = host.decode_u32(w_regs[1], w_regs[2]) * 0.01
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
