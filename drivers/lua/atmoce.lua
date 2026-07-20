-- ATMOCE Gateway Driver (MC100-T / MC100 / MG100)
-- Emits: PV, Battery, Meter
-- Protocol: Modbus TCP, port 502, FC 0x03 (holding registers)
-- Byte order: Big-Endian
-- Reference: Atmoce Gateway Modbus Protocol Interface V1.2

PROTOCOL = "modbus"

local function write_u32(addr, val)
    val = math.floor(math.abs(val))
    local hi = math.floor(val / 65536)
    local lo = val % 65536
    host.modbus_write_multiple(addr, {hi, lo})
end

function driver_init(config)
    host.set_make("ATMOCE")
end

function driver_poll()
    -- =====================
    -- PV Telemetry
    -- =====================

    -- PV Power Output: 60069-60070, U32, kW, gain 1000 (raw = watts)
    local ok_pvw, pvw_regs = pcall(host.modbus_read, 60069, 2, "holding")
    local pv_w = 0
    if ok_pvw then
        pv_w = host.decode_u32(pvw_regs[1], pvw_regs[2])
    end

    -- Cumulative PV Generation: 60100-60103, U64, kWh, gain 100
    local ok_pvgen, pvgen_regs = pcall(host.modbus_read, 60100, 4, "holding")
    local pv_gen_wh = 0
    if ok_pvgen then
        pv_gen_wh = host.decode_u64(pvgen_regs[1], pvgen_regs[2], pvgen_regs[3], pvgen_regs[4]) * 10
    end

    host.emit("pv", {
        w           = -pv_w,
        lifetime_wh = pv_gen_wh,
    })

    -- =====================
    -- Battery Telemetry
    -- =====================

    -- ESS Charging/Discharging Power: 60071-60072, I32, kW, gain 1000 (raw = watts)
    local ok_bat, bat_regs = pcall(host.modbus_read, 60071, 2, "holding")
    local bat_w = 0
    if ok_bat then
        bat_w = math.abs(host.decode_i32(bat_regs[1], bat_regs[2]))
    end

    -- ESS Status: 60067, U16 (1=Charging, 2=Discharging, 99=idle)
    local ok_bst, bst_regs = pcall(host.modbus_read, 60067, 1, "holding")
    local ess_status = 99
    if ok_bst then
        ess_status = bst_regs[1]
    end

    -- Enforce sign: positive=charging, negative=discharging
    if ess_status == 2 then
        bat_w = -bat_w
    elseif ess_status ~= 1 then
        bat_w = 0
    end

    -- ESS SOC: 60095, U16, %, gain 1 (0-100)
    local ok_soc, soc_regs = pcall(host.modbus_read, 60095, 1, "holding")
    local bat_soc = 0
    if ok_soc then
        bat_soc = soc_regs[1] / 100  -- percent to fraction
    end

    host.emit("battery", {
        w   = bat_w,
        soc = bat_soc,
    })

    -- =====================
    -- Meter Telemetry
    -- =====================

    -- Grid Active Power: 60073-60074, I32, kW, gain 1000 (raw = watts)
    -- ATMOCE: positive=import, negative=export → matches our convention
    local ok_gw, gw_regs = pcall(host.modbus_read, 60073, 2, "holding")
    local meter_w = 0
    if ok_gw then
        meter_w = host.decode_i32(gw_regs[1], gw_regs[2])
    end

    -- Phase V/A: 60089-60094
    -- A_V(U16 g10), A_I(I16 g100), B_V, B_I, C_V, C_I
    local ok_va, va_regs = pcall(host.modbus_read, 60089, 6, "holding")
    local l1_v, l1_a, l2_v, l2_a, l3_v, l3_a = 0, 0, 0, 0, 0, 0
    if ok_va then
        l1_v = va_regs[1] * 0.1
        l1_a = host.decode_i16(va_regs[2]) * 0.01
        l2_v = va_regs[3] * 0.1
        l2_a = host.decode_i16(va_regs[4]) * 0.01
        l3_v = va_regs[5] * 0.1
        l3_a = host.decode_i16(va_regs[6]) * 0.01
    end

    -- Cumulative Sales (export): 60178-60181, U64, kWh, gain 100
    local ok_exp, exp_regs = pcall(host.modbus_read, 60178, 4, "holding")
    local export_wh = 0
    if ok_exp then
        export_wh = host.decode_u64(exp_regs[1], exp_regs[2], exp_regs[3], exp_regs[4]) * 10
    end

    -- Cumulative Purchase (import): 60184-60187, U64, kWh, gain 100
    local ok_imp, imp_regs = pcall(host.modbus_read, 60184, 4, "holding")
    local import_wh = 0
    if ok_imp then
        import_wh = host.decode_u64(imp_regs[1], imp_regs[2], imp_regs[3], imp_regs[4]) * 10
    end

    host.emit("meter", {
        w         = meter_w,
        l1_v      = l1_v,
        l2_v      = l2_v,
        l3_v      = l3_v,
        l1_a      = l1_a,
        l2_a      = l2_a,
        l3_a      = l3_a,
        import_wh = import_wh,
        export_wh = export_wh,
    })

    return 5000
end

function driver_command(action, power_w, cmd)
    if action == "init" then
        -- Enable remote communication control
        host.modbus_write(60301, 1)
        return true
    elseif action == "battery" then
        if power_w > 0 then
            -- Forced charging
            host.modbus_write(60310, 0)
            write_u32(60314, power_w)
        elseif power_w < 0 then
            -- Forced discharging
            host.modbus_write(60310, 1)
            write_u32(60314, math.abs(power_w))
        else
            -- Exit forced mode
            host.modbus_write(60310, 2)
        end
        return true
    elseif action == "curtail" then
        -- Force charge to absorb excess PV
        host.modbus_write(60310, 0)
        write_u32(60314, math.abs(power_w))
        return true
    elseif action == "curtail_disable" then
        host.modbus_write(60310, 2)
        return true
    elseif action == "deinit" then
        -- Exit forced mode and return to local control
        host.modbus_write(60310, 2)
        host.modbus_write(60301, 0)
        return true
    end
    return false
end

function driver_default_mode()
    host.modbus_write(60310, 2)
    host.modbus_write(60301, 0)
end

function driver_cleanup()
    -- nothing to clean up
end
