-- Sigenergy Hybrid Inverter Driver
-- Emits: PV, Battery, Meter
-- Protocol: Modbus TCP/RTU
-- Reads plant-level data via slave address 247 (FC 0x04 input registers)
-- Control via holding registers (FC 0x06/0x10)
-- Reference: Sigenergy Modbus Protocol V2.5

PROTOCOL = "modbus"

local function write_u32(addr, val)
    val = math.floor(math.abs(val))
    local hi = math.floor(val / 65536)
    local lo = val % 65536
    host.modbus_write_multiple(addr, {hi, lo})
end

function driver_init(config)
    host.set_make("Sigenergy")
end

function driver_poll()
    -- =====================
    -- PV Telemetry
    -- =====================

    -- PV Power: 30035-30036, S32, kW, gain 1000 (raw = watts)
    local ok_pvw, pvw_regs = pcall(host.modbus_read, 30035, 2, "input")
    local pv_w = 0
    if ok_pvw then
        pv_w = math.abs(host.decode_i32(pvw_regs[1], pvw_regs[2]))
    end

    host.emit("pv", {
        w = -pv_w,
    })

    -- =====================
    -- Battery Telemetry
    -- =====================

    -- ESS Power: 30037-30038, S32, kW, gain 1000 (raw = watts)
    -- Sigenergy: >0 charging, <0 discharging → matches our convention
    local ok_bat, bat_regs = pcall(host.modbus_read, 30037, 2, "input")
    local bat_w = 0
    if ok_bat then
        bat_w = host.decode_i32(bat_regs[1], bat_regs[2])
    end

    -- ESS SOC: 30014, U16, %, gain 10
    local ok_soc, soc_regs = pcall(host.modbus_read, 30014, 1, "input")
    local bat_soc = 0
    if ok_soc then
        bat_soc = soc_regs[1] / 1000  -- gain 10 → percent, / 100 → fraction
    end

    -- ESS SOH: 30087, U16, %, gain 10
    local ok_soh, soh_regs = pcall(host.modbus_read, 30087, 1, "input")

    host.emit("battery", {
        w   = bat_w,
        soc = bat_soc,
    })

    -- =====================
    -- Meter Telemetry
    -- =====================

    -- Grid Active Power: 30005-30006, S32, kW, gain 1000 (raw = watts)
    -- Sigenergy: >0 buy from grid (import), <0 sell to grid (export)
    -- Our convention: positive=import → matches directly
    local ok_gw, gw_regs = pcall(host.modbus_read, 30005, 2, "input")
    local meter_w = 0
    if ok_gw then
        meter_w = host.decode_i32(gw_regs[1], gw_regs[2])
    end

    -- Grid per-phase active power: 30052-30057 (3 x S32, kW, gain 1000)
    local ok_gp, gp_regs = pcall(host.modbus_read, 30052, 6, "input")
    local l1_w, l2_w, l3_w = 0, 0, 0
    if ok_gp then
        l1_w = host.decode_i32(gp_regs[1], gp_regs[2])
        l2_w = host.decode_i32(gp_regs[3], gp_regs[4])
        l3_w = host.decode_i32(gp_regs[5], gp_regs[6])
    end

    host.emit("meter", {
        w    = meter_w,
        l1_w = l1_w,
        l2_w = l2_w,
        l3_w = l3_w,
    })

    return 5000
end

function driver_command(action, power_w, cmd)
    if action == "init" then
        -- Enable Remote EMS
        host.modbus_write(40029, 1)
        return true
    elseif action == "battery" then
        if power_w > 0 then
            -- Command charging (PV first)
            host.modbus_write(40031, 4)
            write_u32(40032, power_w)
        elseif power_w < 0 then
            -- Command discharging (ESS first)
            host.modbus_write(40031, 6)
            write_u32(40034, math.abs(power_w))
        else
            -- Max self-consumption
            host.modbus_write(40031, 2)
        end
        return true
    elseif action == "curtail" then
        -- Limit PV output
        write_u32(40036, math.abs(power_w))
        return true
    elseif action == "curtail_disable" then
        -- Remove PV limit (set to max)
        write_u32(40036, 4294967294)
        return true
    elseif action == "deinit" then
        -- Disable Remote EMS, return to local control
        host.modbus_write(40029, 0)
        return true
    end
    return false
end

function driver_default_mode()
    host.modbus_write(40029, 0)
end

function driver_cleanup()
    -- nothing to clean up
end
