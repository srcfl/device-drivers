-- AlphaESS Smile Series Inverter Driver
-- Emits: PV, Battery, Meter
-- Register type: HOLDING (FC 0x03)
-- Port: 502
-- Community tier (untested)
-- Register map from AlphaESS Modbus protocol v1.30
-- Hex addresses converted to decimal

PROTOCOL = "modbus"

function driver_init(config)
    host.set_make("AlphaESS")
end

function driver_poll()
    -- ---- PV ----

    -- PV1 voltage: 0x0010=16, U16 × 0.1V
    -- PV1 current: 0x0011=17, U16 × 0.1A
    local ok_pv1, pv1_regs = pcall(host.modbus_read, 16, 2, "holding")
    local mppt1_v, mppt1_a = 0, 0
    if ok_pv1 then
        mppt1_v = pv1_regs[1] * 0.1
        mppt1_a = pv1_regs[2] * 0.1
    end

    -- PV total power: 0x0012=18, U16, W
    local ok_pvw, pvw_regs = pcall(host.modbus_read, 18, 1, "holding")
    local pv_w = 0
    if ok_pvw then
        pv_w = pvw_regs[1]
    end

    -- Grid frequency: 0x0022=34, U16 × 0.01Hz
    local ok_hz, hz_regs = pcall(host.modbus_read, 34, 1, "holding")
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

    -- Battery power: 0x0020=32, I16, W (positive=charge, negative=discharge)
    local ok_bw, bw_regs = pcall(host.modbus_read, 32, 1, "holding")
    local bat_w = 0
    if ok_bw then
        bat_w = host.decode_i16(bw_regs[1])
    end

    -- Battery voltage: 0x0021=33, U16 × 0.1V
    local ok_bv, bv_regs = pcall(host.modbus_read, 33, 1, "holding")
    local bat_v = 0
    if ok_bv then
        bat_v = bv_regs[1] * 0.1
    end

    -- Battery SoC: 0x0024=36, U16, %
    local ok_bsoc, bsoc_regs = pcall(host.modbus_read, 36, 1, "holding")
    local bat_soc = 0
    if ok_bsoc then
        bat_soc = bsoc_regs[1] / 100  -- percent to fraction
    end

    -- Emit Battery telemetry
    host.emit("battery", {
        w   = bat_w,
        v   = bat_v,
        soc = bat_soc,
    })

    -- ---- Meter ----

    -- Phase voltage: 0x0026=38, U16 × 0.1V
    local ok_lv, lv_regs = pcall(host.modbus_read, 38, 1, "holding")
    local l1_v = 0
    if ok_lv then
        l1_v = lv_regs[1] * 0.1
    end

    -- Phase current: 0x0027=39, U16 × 0.1A
    local ok_la, la_regs = pcall(host.modbus_read, 39, 1, "holding")
    local l1_a = 0
    if ok_la then
        l1_a = la_regs[1] * 0.1
    end

    -- Grid power: 0x0028=40, I16, W (positive=import)
    local ok_mw, mw_regs = pcall(host.modbus_read, 40, 1, "holding")
    local meter_w = 0
    if ok_mw then
        meter_w = host.decode_i16(mw_regs[1])
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
    host.log("AlphaESS control not yet implemented: " .. action)
    return false
end

function driver_default_mode()
end

function driver_cleanup()
    -- nothing to clean up
end
