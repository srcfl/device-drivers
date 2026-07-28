-- KSTAR KSE Series Inverter Driver
-- Emits: PV, Battery, Meter
-- Register type: HOLDING (FC 0x03)
-- Port: 502
-- Community tier (untested)

PROTOCOL = "modbus"

-- Reading a register the device does not have costs a failed read on every
-- poll forever, and the host counts those against the poll whether or not Lua
-- caught the error. Enough of them and the site is marked offline and reports
-- nothing at all, which is worse than reporting one field less. So stop asking
-- once a register has proved it is not there. Three tries, because one failure
-- proves nothing -- the link may just have been slow.
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
            "KSTAR: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

function driver_init(config)
    host.set_make("KSTAR")
end

function driver_poll()
    -- ---- PV ----

    -- PV1 voltage: 28, U16 × 0.1V; PV1 current: 29, U16 × 0.1A
    local pv1_regs = probe_read(28, 2, "holding")
    local mppt1_v, mppt1_a = 0, 0
    if pv1_regs then
        mppt1_v = pv1_regs[1] * 0.1
        mppt1_a = pv1_regs[2] * 0.1
    end

    -- PV power: 30, U16, W
    local pvw_regs = probe_read(30, 1, "holding")
    local pv_w = 0
    if pvw_regs then
        pv_w = pvw_regs[1]
    end

    -- Grid frequency: 18, U16 × 0.01Hz
    local hz_regs = probe_read(18, 1, "holding")
    local hz = 0
    if hz_regs then
        hz = hz_regs[1] * 0.01
    end

    -- Emit PV telemetry (W always negative for generation)
    host.emit("pv", {
        W       = -pv_w,
        mppt1_v = mppt1_v,
        mppt1_a = mppt1_a,
    })

    -- ---- Battery ----

    -- Battery power: 50, I16, W (positive=charge, negative=discharge)
    local bw_regs = probe_read(50, 1, "holding")
    local bat_w = 0
    if bw_regs then
        bat_w = host.decode_i16(bw_regs[1])
    end

    -- Battery SoC: 54, U16, %
    local bsoc_regs = probe_read(54, 1, "holding")
    local bat_soc = 0
    if bsoc_regs then
        bat_soc = bsoc_regs[1] / 100  -- percent to fraction
    end

    -- Emit Battery telemetry
    host.emit("battery", {
        W   = bat_w,
        SoC_nom_fract = bat_soc,
    })

    -- ---- Meter ----

    -- Grid power: 22, I16, W (positive=import)
    local mw_regs = probe_read(22, 1, "holding")
    local meter_w = 0
    if mw_regs then
        meter_w = host.decode_i16(mw_regs[1])
    end

    -- Phase voltage: 10, U16 × 0.1V
    local lv_regs = probe_read(10, 1, "holding")
    local l1_v = 0
    if lv_regs then
        l1_v = lv_regs[1] * 0.1
    end

    -- Phase current: 11, U16 × 0.1A
    local la_regs = probe_read(11, 1, "holding")
    local l1_a = 0
    if la_regs then
        l1_a = la_regs[1] * 0.1
    end

    -- Emit Meter telemetry
    host.emit("meter", {
        W    = meter_w,
        L1_V = l1_v,
        L1_A = l1_a,
        Hz   = hz,
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
