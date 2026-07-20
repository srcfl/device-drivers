-- Easee Home/Charge EV Charger Driver (community, untested)
-- Emits: V2X Charger
-- Register type: HOLDING (FC 0x03)
-- Modbus TCP interface, port 502
-- Note: Easee uses F32 for power/energy, U16 for state

PROTOCOL = "modbus"

function driver_init(config)
    host.set_make("Easee")
end

function driver_poll()
    -- L1 current: 0 (F32, A), L2: 2
    local ok_a, a_regs = pcall(host.modbus_read, 0, 4, "holding")
    local l1_a, l2_a = 0, 0
    if ok_a then
        l1_a = host.decode_f32(a_regs[1], a_regs[2])
        l2_a = host.decode_f32(a_regs[3], a_regs[4])
    end

    -- Active power: 4 (F32, W)
    local ok_w, w_regs = pcall(host.modbus_read, 4, 2, "holding")
    local power_w = 0
    if ok_w then
        power_w = host.decode_f32(w_regs[1], w_regs[2])
    end

    -- Session energy: 8 (F32, Wh)
    local ok_se, se_regs = pcall(host.modbus_read, 8, 2, "holding")
    local session_wh = 0
    if ok_se then
        session_wh = host.decode_f32(se_regs[1], se_regs[2])
    end

    -- Charger state: 10 (U16: 1=disconnected, 2=awaiting, 3=charging, 4=completed, 5=error)
    local ok_st, st_regs = pcall(host.modbus_read, 10, 1, "holding")
    local raw_state = 0
    local state = 0
    if ok_st then
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
