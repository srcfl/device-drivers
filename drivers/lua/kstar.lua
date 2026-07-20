-- KSTAR KSE Series Inverter Driver
-- Emits: PV, Battery, Meter
-- Register type: HOLDING (FC 0x03)
-- Port: 502
-- Community tier (untested)

PROTOCOL = "modbus"

function driver_init(config)
    host.set_make("KSTAR")
end

function driver_poll()
    -- ---- PV ----

    -- PV1 voltage: 28, U16 × 0.1V; PV1 current: 29, U16 × 0.1A
    local ok_pv1, pv1_regs = pcall(host.modbus_read, 28, 2, "holding")
    local mppt1_v, mppt1_a = 0, 0
    if ok_pv1 then
        mppt1_v = pv1_regs[1] * 0.1
        mppt1_a = pv1_regs[2] * 0.1
    end

    -- PV power: 30, U16, W
    local ok_pvw, pvw_regs = pcall(host.modbus_read, 30, 1, "holding")
    local pv_w = 0
    if ok_pvw then
        pv_w = pvw_regs[1]
    end

    -- Grid frequency: 18, U16 × 0.01Hz
    local ok_hz, hz_regs = pcall(host.modbus_read, 18, 1, "holding")
    local hz = 0
    if ok_hz then
        hz = hz_regs[1] * 0.01
    end

    -- Emit PV telemetry (W always negative for generation)
    host.emit("pv", {
        w       = -pv_w,
        mppt1_v = mppt1_v,
        mppt1_a = mppt1_a,
    })

    -- ---- Battery ----

    -- Battery power: 50, I16, W (positive=charge, negative=discharge)
    local ok_bw, bw_regs = pcall(host.modbus_read, 50, 1, "holding")
    local bat_w = 0
    if ok_bw then
        bat_w = host.decode_i16(bw_regs[1])
    end

    -- Battery SoC: 54, U16, %
    local ok_bsoc, bsoc_regs = pcall(host.modbus_read, 54, 1, "holding")
    local bat_soc = 0
    if ok_bsoc then
        bat_soc = bsoc_regs[1] / 100  -- percent to fraction
    end

    -- Emit Battery telemetry
    host.emit("battery", {
        w   = bat_w,
        soc = bat_soc,
    })

    -- ---- Meter ----

    -- Grid power: 22, I16, W (positive=import)
    local ok_mw, mw_regs = pcall(host.modbus_read, 22, 1, "holding")
    local meter_w = 0
    if ok_mw then
        meter_w = host.decode_i16(mw_regs[1])
    end

    -- Phase voltage: 10, U16 × 0.1V
    local ok_lv, lv_regs = pcall(host.modbus_read, 10, 1, "holding")
    local l1_v = 0
    if ok_lv then
        l1_v = lv_regs[1] * 0.1
    end

    -- Phase current: 11, U16 × 0.1A
    local ok_la, la_regs = pcall(host.modbus_read, 11, 1, "holding")
    local l1_a = 0
    if ok_la then
        l1_a = la_regs[1] * 0.1
    end

    -- Emit Meter telemetry
    host.emit("meter", {
        w    = meter_w,
        l1_v = l1_v,
        l1_a = l1_a,
        hz   = hz,
    })

    return 5000
end

function driver_command(action, power_w, cmd)
    host.log("KSTAR control not yet implemented: " .. action)
    return false
end

function driver_default_mode()
end

function driver_cleanup()
    -- nothing to clean up
end
