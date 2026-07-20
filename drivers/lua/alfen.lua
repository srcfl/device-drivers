-- Alfen Eve NG9xx EV Charger Driver (community, untested)
-- Emits: V2X Charger
-- Register type: HOLDING (FC 0x03)
-- All multi-register values are F32 BE unless noted

PROTOCOL = "modbus"

function driver_init(config)
    host.set_make("Alfen")
end

function driver_poll()
    -- L1 current: 320 (F32, A), L2: 322, L3: 324
    local ok_a, a_regs = pcall(host.modbus_read, 320, 6, "holding")
    local l1_a, l2_a, l3_a = 0, 0, 0
    if ok_a then
        l1_a = host.decode_f32(a_regs[1], a_regs[2])
        l2_a = host.decode_f32(a_regs[3], a_regs[4])
        l3_a = host.decode_f32(a_regs[5], a_regs[6])
    end

    -- L1 voltage: 326 (F32, V), L2: 328, L3: 330
    local ok_v, v_regs = pcall(host.modbus_read, 326, 6, "holding")
    local l1_v, l2_v, l3_v = 0, 0, 0
    if ok_v then
        l1_v = host.decode_f32(v_regs[1], v_regs[2])
        l2_v = host.decode_f32(v_regs[3], v_regs[4])
        l3_v = host.decode_f32(v_regs[5], v_regs[6])
    end

    -- Active power: 344 (F32, W)
    local ok_w, w_regs = pcall(host.modbus_read, 344, 2, "holding")
    local power_w = 0
    if ok_w then
        power_w = host.decode_f32(w_regs[1], w_regs[2])
    end

    -- Session energy: 346 (F32, Wh)
    local ok_se, se_regs = pcall(host.modbus_read, 346, 2, "holding")
    local session_wh = 0
    if ok_se then
        session_wh = host.decode_f32(se_regs[1], se_regs[2])
    end

    -- Charger state: 1201 (U16: 0=unavailable, 1=available, 2=occupied, 3=charging)
    local ok_st, st_regs = pcall(host.modbus_read, 1201, 1, "holding")
    local raw_state = 0
    local state = 0
    if ok_st then
        raw_state = st_regs[1]
        -- Map Alfen states to standard: 0=idle, 1=connected, 2=charging, 3=error
        if raw_state == 0 then
            state = 3      -- unavailable -> error
        elseif raw_state == 1 then
            state = 0      -- available -> idle
        elseif raw_state == 2 then
            state = 1      -- occupied -> connected
        elseif raw_state == 3 then
            state = 2      -- charging -> charging
        end
    end

    -- Max current: 1210 (F32, A)
    local ok_mc, mc_regs = pcall(host.modbus_read, 1210, 2, "holding")
    local max_a = 0
    if ok_mc then
        max_a = host.decode_f32(mc_regs[1], mc_regs[2])
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
