-- VARTA Storage Driver (Battery + Meter only)
-- Emits: Battery, Meter
-- Register type: HOLDING (FC 0x03)
-- Unit ID: 255
-- Port: 502
-- Community tier (untested)

PROTOCOL = "modbus"

function driver_init(config)
    host.set_make("VARTA")
end

function driver_poll()
    -- ---- Battery ----

    -- Battery power: 1066, I16, W (positive=charge, negative=discharge)
    local ok_bw, bw_regs = pcall(host.modbus_read, 1066, 1, "holding")
    local bat_w = 0
    if ok_bw then
        bat_w = host.decode_i16(bw_regs[1])
    end

    -- Battery SoC: 1068, U16, %
    local ok_bsoc, bsoc_regs = pcall(host.modbus_read, 1068, 1, "holding")
    local bat_soc = 0
    if ok_bsoc then
        bat_soc = bsoc_regs[1] / 100  -- percent to fraction
    end

    -- Emit Battery telemetry
    host.emit("battery", {
        w          = bat_w,
        soc        = bat_soc,
    })

    -- ---- Meter ----

    -- Grid power: 1078, I16, W (positive=import)
    local ok_mw, mw_regs = pcall(host.modbus_read, 1078, 1, "holding")
    local meter_w = 0
    if ok_mw then
        meter_w = host.decode_i16(mw_regs[1])
    end

    -- Phase 1 voltage: 1080, U16 × 0.1V
    local ok_lv, lv_regs = pcall(host.modbus_read, 1080, 1, "holding")
    local l1_v = 0
    if ok_lv then
        l1_v = lv_regs[1] * 0.1
    end

    -- Phase 1 current: 1081, U16 × 0.1A
    local ok_la, la_regs = pcall(host.modbus_read, 1081, 1, "holding")
    local l1_a = 0
    if ok_la then
        l1_a = la_regs[1] * 0.1
    end

    -- Emit Meter telemetry
    host.emit("meter", {
        w    = meter_w,
        l1_v = l1_v,
        l1_a = l1_a,
    })

    return 5000
end

function driver_command(action, power_w, cmd)
    host.log("VARTA control not yet implemented: " .. action)
    return false
end

function driver_default_mode()
end

function driver_cleanup()
    -- nothing to clean up
end
