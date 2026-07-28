-- ATMOCE Gateway Driver (MC100-T / MC100 / MG100)
-- Emits: PV, Battery, Meter
-- Protocol: Modbus TCP, port 502, FC 0x03 (holding registers)
-- Byte order: Big-Endian
-- Reference: Atmoce Gateway Modbus Protocol Interface V1.2

PROTOCOL = "modbus"

-- uint64 from four big-endian registers. Kept in Lua: arithmetic, not I/O.
local function decode_u64(w1, w2, w3, w4)
    return ((w1 * 65536 + w2) * 65536 + w3) * 65536 + w4
end

local function write_u32(addr, val)
    val = math.floor(math.abs(val))
    local hi = math.floor(val / 65536)
    local lo = val % 65536
    host.write_registers(addr, {hi, lo})
end

----------------------------------------------------------------------------
-- Absent-register guard
----------------------------------------------------------------------------
-- The host counts every failed modbus_read against the poll whether or not
-- Lua caught it. So a register this driver can live without must stop being
-- read once the device has made clear it will not answer — otherwise the
-- poll keeps failing, the stale-telemetry watchdog marks the gateway
-- offline, and the site reports nothing at all instead of one field less.
--
-- Three strikes rather than one: a single miss is more often a slow link
-- than a missing register. A restart re-probes.
--
-- Poll reads only. The control path below writes and never reads, so a
-- register the poll gave up on cannot veto a later setpoint.
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
            "ATMOCE: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

function driver_init(config)
    host.set_make("ATMOCE")
end

function driver_poll()
    -- =====================
    -- PV Telemetry
    -- =====================

    -- PV Power Output: 60069-60070, U32, kW, gain 1000 (raw = watts)
    local pvw_regs = probe_read(60069, 2, "holding")
    local pv_w = 0
    if pvw_regs then
        pv_w = host.decode_u32_be(pvw_regs[1], pvw_regs[2])
    end

    -- Cumulative PV Generation: 60100-60103, U64, kWh, gain 100
    local pvgen_regs = probe_read(60100, 4, "holding")
    local pv_gen_wh = 0
    if pvgen_regs then
        pv_gen_wh = decode_u64(pvgen_regs[1], pvgen_regs[2], pvgen_regs[3], pvgen_regs[4]) * 10
    end

    host.emit("pv", {
        W           = -pv_w,
        total_generation_Wh = pv_gen_wh,
    })

    -- =====================
    -- Battery Telemetry
    -- =====================

    -- ESS Charging/Discharging Power: 60071-60072, I32, kW, gain 1000 (raw = watts)
    local bat_regs = probe_read(60071, 2, "holding")
    local bat_w = 0
    if bat_regs then
        bat_w = math.abs(host.decode_i32_be(bat_regs[1], bat_regs[2]))
    end

    -- ESS Status: 60067, U16 (1=Charging, 2=Discharging, 99=idle)
    local bst_regs = probe_read(60067, 1, "holding")
    local ess_status = 99
    if bst_regs then
        ess_status = bst_regs[1]
    end

    -- Enforce sign: positive=charging, negative=discharging
    if ess_status == 2 then
        bat_w = -bat_w
    elseif ess_status ~= 1 then
        bat_w = 0
    end

    -- ESS SOC: 60095, U16, %, gain 1 (0-100)
    local soc_regs = probe_read(60095, 1, "holding")
    local bat_soc = 0
    if soc_regs then
        bat_soc = soc_regs[1] / 100  -- percent to fraction
    end

    host.emit("battery", {
        W   = bat_w,
        SoC_nom_fract = bat_soc,
    })

    -- =====================
    -- Meter Telemetry
    -- =====================

    -- Grid Active Power: 60073-60074, I32, kW, gain 1000 (raw = watts)
    -- ATMOCE: positive=import, negative=export → matches our convention
    local gw_regs = probe_read(60073, 2, "holding")
    local meter_w = 0
    if gw_regs then
        meter_w = host.decode_i32_be(gw_regs[1], gw_regs[2])
    end

    -- Phase V/A: 60089-60094
    -- A_V(U16 g10), A_I(I16 g100), B_V, B_I, C_V, C_I
    local va_regs = probe_read(60089, 6, "holding")
    local l1_v, l1_a, l2_v, l2_a, l3_v, l3_a = 0, 0, 0, 0, 0, 0
    if va_regs then
        l1_v = va_regs[1] * 0.1
        l1_a = host.decode_i16(va_regs[2]) * 0.01
        l2_v = va_regs[3] * 0.1
        l2_a = host.decode_i16(va_regs[4]) * 0.01
        l3_v = va_regs[5] * 0.1
        l3_a = host.decode_i16(va_regs[6]) * 0.01
    end

    -- Cumulative Sales (export): 60178-60181, U64, kWh, gain 100
    local exp_regs = probe_read(60178, 4, "holding")
    local export_wh = 0
    if exp_regs then
        export_wh = decode_u64(exp_regs[1], exp_regs[2], exp_regs[3], exp_regs[4]) * 10
    end

    -- Cumulative Purchase (import): 60184-60187, U64, kWh, gain 100
    local imp_regs = probe_read(60184, 4, "holding")
    local import_wh = 0
    if imp_regs then
        import_wh = decode_u64(imp_regs[1], imp_regs[2], imp_regs[3], imp_regs[4]) * 10
    end

    host.emit("meter", {
        W         = meter_w,
        L1_V      = l1_v,
        L2_V      = l2_v,
        L3_V      = l3_v,
        L1_A      = l1_a,
        L2_A      = l2_a,
        L3_A      = l3_a,
        total_import_Wh = import_wh,
        total_export_Wh = export_wh,
    })

    return 5000
end

function driver_command(action, power_w, cmd)
    if action == "init" then
        -- Enable remote communication control
        host.write(60301, 1)
        return true
    elseif action == "battery" then
        if power_w > 0 then
            -- Forced charging
            host.write(60310, 0)
            write_u32(60314, power_w)
        elseif power_w < 0 then
            -- Forced discharging
            host.write(60310, 1)
            write_u32(60314, math.abs(power_w))
        else
            -- Exit forced mode
            host.write(60310, 2)
        end
        return true
    elseif action == "curtail" then
        -- Force charge to absorb excess PV
        host.write(60310, 0)
        write_u32(60314, math.abs(power_w))
        return true
    elseif action == "curtail_disable" then
        host.write(60310, 2)
        return true
    elseif action == "deinit" then
        -- Exit forced mode and return to local control
        host.write(60310, 2)
        host.write(60301, 0)
        return true
    end
    return false
end

function driver_default_mode()
    host.write(60310, 2)
    host.write(60301, 0)
end

function driver_cleanup()
    -- nothing to clean up
end
