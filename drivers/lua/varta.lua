-- VARTA Storage Driver (Battery + Meter only)
-- Emits: Battery, Meter
-- Register type: HOLDING (FC 0x03)
-- Unit ID: 255
-- Port: 502
-- Community tier (untested)

PROTOCOL = "modbus"

-- The host counts every failed modbus_read against the poll whether or not
-- Lua caught it, so a register this unit does not answer costs a failed read
-- on every poll forever and the stale-telemetry watchdog takes the site
-- offline. Ask three times -- one miss can just be a slow link -- then leave
-- the register alone. A restart re-probes.
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
            "VARTA: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

function driver_init(config)
    host.set_make("VARTA")
end

function driver_poll()
    -- ---- Battery ----

    -- Battery power: 1066, I16, W (positive=charge, negative=discharge)
    local bw_regs = probe_read(1066, 1, "holding")
    local bat_w = 0
    if bw_regs then
        bat_w = host.decode_i16(bw_regs[1])
    end

    -- Battery SoC: 1068, U16, %
    local bsoc_regs = probe_read(1068, 1, "holding")
    local bat_soc = 0
    if bsoc_regs then
        bat_soc = bsoc_regs[1] / 100  -- percent to fraction
    end

    -- Emit Battery telemetry
    host.emit("battery", {
        W          = bat_w,
        SoC_nom_fract        = bat_soc,
    })

    -- ---- Meter ----

    -- Grid power: 1078, I16, W (positive=import)
    local mw_regs = probe_read(1078, 1, "holding")
    local meter_w = 0
    if mw_regs then
        meter_w = host.decode_i16(mw_regs[1])
    end

    -- Phase 1 voltage: 1080, U16 × 0.1V
    local lv_regs = probe_read(1080, 1, "holding")
    local l1_v = 0
    if lv_regs then
        l1_v = lv_regs[1] * 0.1
    end

    -- Phase 1 current: 1081, U16 × 0.1A
    local la_regs = probe_read(1081, 1, "holding")
    local l1_a = 0
    if la_regs then
        l1_a = la_regs[1] * 0.1
    end

    -- Emit Meter telemetry
    host.emit("meter", {
        W    = meter_w,
        L1_V = l1_v,
        L1_A = l1_a,
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
