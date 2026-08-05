-- Sigenergy Hybrid Inverter Driver
-- Emits: PV, Battery, Meter
-- Protocol: Modbus TCP/RTU
-- Reads plant-level data via slave address 247 (FC 0x04 input registers)
-- Control via holding registers (FC 0x06/0x10)
-- Reference: Sigenergy Modbus Protocol V2.5

PROTOCOL = "modbus"

-- Bounded register probe.
-- The host counts every failed host.modbus_read against the poll, even one
-- pcall caught here. A driver that keeps emitting while a register keeps
-- failing is marked offline by the stale-telemetry watchdog, and the site
-- then reports nothing at all. So: three tries, then leave the register
-- alone. Three rather than one because a single failure is not proof the
-- register is missing -- the link may just have been slow.
local GIVE_UP_AFTER = 3
local read_failures = {}

local function probe_read(addr, count, kind)
    if (read_failures[addr] or 0) >= GIVE_UP_AFTER then return nil end
    local ok, regs = pcall(host.modbus_read, addr, count, kind)
    if ok and regs and regs[1] ~= nil then
        read_failures[addr] = nil
        return regs
    end
    local failures = (read_failures[addr] or 0) + 1
    read_failures[addr] = failures
    if failures == GIVE_UP_AFTER then
        host.log("info", string.format(
            "Sigenergy: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

local function write_u32(addr, val)
    val = math.floor(math.abs(val))
    local hi = math.floor(val / 65536)
    local lo = val % 65536
    host.write_registers(addr, {hi, lo})
end

function driver_init(config)
    host.set_make("Sigenergy")
end

function driver_poll()
    -- =====================
    -- PV Telemetry
    -- =====================

    -- PV Power: 30035-30036, S32, kW, gain 1000 (raw = watts)
    local pvw_regs = probe_read(30035, 2, "input")
    local pv_w = 0
    if pvw_regs then
        pv_w = math.abs(host.decode_i32_be(pvw_regs[1], pvw_regs[2]))
    end

    host.emit("pv", {
        W = -pv_w,
    })

    -- =====================
    -- Battery Telemetry
    -- =====================
    --
    -- The ESS registers are the only ones here a Sigenergy plant can lack.
    -- Every hybrid model in the range is sold without storage as well as with
    -- it -- a Sigen PV M1-HYA commissioned PV-only is the case this was found
    -- on -- and on such a plant 30014 and 30037 never answer.
    --
    -- Filling the fields with zero there does not report "no battery", it
    -- reports an empty one: a pack sitting at 0% that can absorb charge. The
    -- planner can then dispatch against storage that is not installed, and
    -- driver_command("battery", ...) writes 40032/40034, which a plant with no
    -- ESS does not implement. Zero is also indistinguishable from a real pack
    -- that has just run flat, so nothing downstream can tell the two apart.
    --
    -- So each field is filled only from a register that answered, and the DER
    -- is emitted only when at least one of them did. A plant with storage is
    -- unaffected; a plant without one stops claiming a battery.

    local battery = {}

    -- ESS Power: 30037-30038, S32, kW, gain 1000 (raw = watts)
    -- Sigenergy: >0 charging, <0 discharging → matches our convention
    local bat_regs = probe_read(30037, 2, "input")
    if bat_regs then
        battery.W = host.decode_i32_be(bat_regs[1], bat_regs[2])
    end

    -- ESS SOC: 30014, U16, %, gain 10
    local soc_regs = probe_read(30014, 1, "input")
    if soc_regs then
        battery.SoC_nom_fract = soc_regs[1] / 1000  -- gain 10 → percent, / 100 → fraction
    end

    if bat_regs or soc_regs then
        host.emit("battery", battery)
    end

    -- =====================
    -- Meter Telemetry
    -- =====================

    -- Grid Active Power: 30005-30006, S32, kW, gain 1000 (raw = watts)
    -- Sigenergy: >0 buy from grid (import), <0 sell to grid (export)
    -- Our convention: positive=import → matches directly
    local gw_regs = probe_read(30005, 2, "input")
    local meter_w = 0
    if gw_regs then
        meter_w = host.decode_i32_be(gw_regs[1], gw_regs[2])
    end

    -- Grid per-phase active power: 30052-30057 (3 x S32, kW, gain 1000)
    local gp_regs = probe_read(30052, 6, "input")
    local l1_w, l2_w, l3_w = 0, 0, 0
    if gp_regs then
        l1_w = host.decode_i32_be(gp_regs[1], gp_regs[2])
        l2_w = host.decode_i32_be(gp_regs[3], gp_regs[4])
        l3_w = host.decode_i32_be(gp_regs[5], gp_regs[6])
    end

    host.emit("meter", {
        W    = meter_w,
        L1_W = l1_w,
        L2_W = l2_w,
        L3_W = l3_w,
    })

    return 5000
end

function driver_command(action, power_w, cmd)
    if action == "init" then
        -- Enable Remote EMS
        host.write(40029, 1)
        return true
    elseif action == "battery" then
        if power_w > 0 then
            -- Command charging (PV first)
            host.write(40031, 4)
            write_u32(40032, power_w)
        elseif power_w < 0 then
            -- Command discharging (ESS first)
            host.write(40031, 6)
            write_u32(40034, math.abs(power_w))
        else
            -- Max self-consumption
            host.write(40031, 2)
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
        host.write(40029, 0)
        return true
    end
    return false
end

function driver_default_mode()
    host.write(40029, 0)
end

function driver_cleanup()
    -- nothing to clean up
end
