-- Keba KeContact P30 EV Charger Driver (community, untested)
-- Emits: V2X Charger
-- Register type: HOLDING (FC 0x03)
-- Keba Modbus TCP interface
-- Note: Most values are U32 in milliunit format

PROTOCOL = "modbus"

function driver_init(config)
    host.set_make("Keba")
end

function driver_poll()
    -- Charger state: 1000 (U32: 0=startup, 1=not ready, 2=ready, 3=charging, 4=error, 5=suspended)
    local ok_st, st_regs = pcall(host.modbus_read, 1000, 2, "holding")
    local raw_state = 0
    local state = 0
    if ok_st then
        raw_state = host.decode_u32(st_regs[1], st_regs[2])
        -- Map Keba states to standard: 0=idle, 1=connected, 2=charging, 3=error
        if raw_state == 0 then
            state = 0      -- startup -> idle
        elseif raw_state == 1 then
            state = 0      -- not ready -> idle
        elseif raw_state == 2 then
            state = 0      -- ready -> idle
        elseif raw_state == 3 then
            state = 2      -- charging -> charging
        elseif raw_state == 4 then
            state = 3      -- error -> error
        elseif raw_state == 5 then
            state = 1      -- suspended -> connected
        end
    end

    -- L1 current: 1006 (U32, mA), L2: 1008, L3: 1010
    local ok_a1, a1_regs = pcall(host.modbus_read, 1006, 2, "holding")
    local l1_a = 0
    if ok_a1 then
        l1_a = host.decode_u32(a1_regs[1], a1_regs[2]) * 0.001
    end

    local ok_a2, a2_regs = pcall(host.modbus_read, 1008, 2, "holding")
    local l2_a = 0
    if ok_a2 then
        l2_a = host.decode_u32(a2_regs[1], a2_regs[2]) * 0.001
    end

    local ok_a3, a3_regs = pcall(host.modbus_read, 1010, 2, "holding")
    local l3_a = 0
    if ok_a3 then
        l3_a = host.decode_u32(a3_regs[1], a3_regs[2]) * 0.001
    end

    -- L1 voltage: 1012 (U32, mV), L2: 1014, L3: 1016
    local ok_v1, v1_regs = pcall(host.modbus_read, 1012, 2, "holding")
    local l1_v = 0
    if ok_v1 then
        l1_v = host.decode_u32(v1_regs[1], v1_regs[2]) * 0.001
    end

    local ok_v2, v2_regs = pcall(host.modbus_read, 1014, 2, "holding")
    local l2_v = 0
    if ok_v2 then
        l2_v = host.decode_u32(v2_regs[1], v2_regs[2]) * 0.001
    end

    local ok_v3, v3_regs = pcall(host.modbus_read, 1016, 2, "holding")
    local l3_v = 0
    if ok_v3 then
        l3_v = host.decode_u32(v3_regs[1], v3_regs[2]) * 0.001
    end

    -- Active power: 1020 (U32, mW)
    local ok_w, w_regs = pcall(host.modbus_read, 1020, 2, "holding")
    local power_w = 0
    if ok_w then
        power_w = host.decode_u32(w_regs[1], w_regs[2]) * 0.001
    end

    -- Session energy: 1036 (U32, 0.1Wh)
    local ok_se, se_regs = pcall(host.modbus_read, 1036, 2, "holding")
    local session_wh = 0
    if ok_se then
        session_wh = host.decode_u32(se_regs[1], se_regs[2]) * 0.1
    end

    -- Max current: 5004 (U16, mA) -- read/write register
    local ok_mc, mc_regs = pcall(host.modbus_read, 5004, 1, "holding")
    local max_a = 0
    if ok_mc then
        max_a = mc_regs[1] * 0.001
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
