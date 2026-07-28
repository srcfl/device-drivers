-- Keba KeContact P30 EV Charger Driver (community, untested)
-- Emits: V2X Charger
-- Register type: HOLDING (FC 0x03)
-- Keba Modbus TCP interface
-- Note: Most values are U32 in milliunit format

PROTOCOL = "modbus"

----------------------------------------------------------------------------
-- Absent-register guard
----------------------------------------------------------------------------
-- The host counts every failed modbus_read against the poll whether or not
-- Lua caught it. So a register this driver can live without must stop being
-- read once the device has made clear it will not answer — otherwise the
-- poll keeps failing, the stale-telemetry watchdog marks the charger
-- offline, and the site reports nothing at all instead of one field less.
--
-- Three strikes rather than one: a single miss is more often a slow link
-- than a missing register. A restart re-probes.
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
            "Keba: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

function driver_init(config)
    host.set_make("Keba")
end

function driver_poll()
    -- Charger state: 1000 (U32: 0=startup, 1=not ready, 2=ready, 3=charging, 4=error, 5=suspended)
    local st_regs = probe_read(1000, 2, "holding")
    local raw_state = 0
    local state = 0
    if st_regs then
        raw_state = host.decode_u32_be(st_regs[1], st_regs[2])
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
    local a1_regs = probe_read(1006, 2, "holding")
    local l1_a = 0
    if a1_regs then
        l1_a = host.decode_u32_be(a1_regs[1], a1_regs[2]) * 0.001
    end

    local a2_regs = probe_read(1008, 2, "holding")
    local l2_a = 0
    if a2_regs then
        l2_a = host.decode_u32_be(a2_regs[1], a2_regs[2]) * 0.001
    end

    local a3_regs = probe_read(1010, 2, "holding")
    local l3_a = 0
    if a3_regs then
        l3_a = host.decode_u32_be(a3_regs[1], a3_regs[2]) * 0.001
    end

    -- L1 voltage: 1012 (U32, mV), L2: 1014, L3: 1016
    local v1_regs = probe_read(1012, 2, "holding")
    local l1_v = 0
    if v1_regs then
        l1_v = host.decode_u32_be(v1_regs[1], v1_regs[2]) * 0.001
    end

    local v2_regs = probe_read(1014, 2, "holding")
    local l2_v = 0
    if v2_regs then
        l2_v = host.decode_u32_be(v2_regs[1], v2_regs[2]) * 0.001
    end

    local v3_regs = probe_read(1016, 2, "holding")
    local l3_v = 0
    if v3_regs then
        l3_v = host.decode_u32_be(v3_regs[1], v3_regs[2]) * 0.001
    end

    -- Active power: 1020 (U32, mW)
    local w_regs = probe_read(1020, 2, "holding")
    local power_w = 0
    if w_regs then
        power_w = host.decode_u32_be(w_regs[1], w_regs[2]) * 0.001
    end

    -- Session energy: 1036 (U32, 0.1Wh)
    local se_regs = probe_read(1036, 2, "holding")
    local session_wh = 0
    if se_regs then
        session_wh = host.decode_u32_be(se_regs[1], se_regs[2]) * 0.1
    end

    -- Max current: 5004 (U16, mA) -- read/write register
    local mc_regs = probe_read(5004, 1, "holding")
    local max_a = 0
    if mc_regs then
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
