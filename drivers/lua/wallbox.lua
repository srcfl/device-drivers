-- Wallbox Commander 2 EV Charger Driver (community, untested)
-- Emits: V2X Charger
-- Register type: HOLDING (FC 0x03)
-- Note: Limited register set -- no per-phase voltage/current available

PROTOCOL = "modbus"

function driver_init(config)
    host.set_make("Wallbox")
end

function driver_poll()
    -- Charger state: 0 (U16: 0=ready, 1=charging, 2=waiting, 3=disconnected)
    local ok_st, st_regs = pcall(host.modbus_read, 0, 1, "holding")
    local raw_state = 0
    local state = 0
    if ok_st then
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
    local ok_w, w_regs = pcall(host.modbus_read, 4, 2, "holding")
    local power_w = 0
    if ok_w then
        power_w = host.decode_u32(w_regs[1], w_regs[2])
    end

    -- Session energy: 7 (U32, Wh)
    local ok_se, se_regs = pcall(host.modbus_read, 7, 2, "holding")
    local session_wh = 0
    if ok_se then
        session_wh = host.decode_u32(se_regs[1], se_regs[2])
    end

    -- Max current: 9 (U16, A) -- writable
    local ok_mc, mc_regs = pcall(host.modbus_read, 9, 1, "holding")
    local max_a = 0
    if ok_mc then
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
