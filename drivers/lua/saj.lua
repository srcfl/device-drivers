-- SAJ H2/HS2/AS2 Series Inverter Driver
-- Emits: PV, Battery, Meter
-- Register type: INPUT (FC 0x04)
-- Port: 502
-- Community tier (untested)
-- Hex addresses converted to decimal

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
            "SAJ: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

function driver_init(config)
    host.set_make("SAJ")
end

function driver_poll()
    -- ---- PV ----

    -- PV1 voltage: 0x1058=4184, U16 × 0.1V
    -- PV1 current: 0x1059=4185, U16 × 0.01A
    local pv1_regs = probe_read(4184, 2, "input")
    local mppt1_v, mppt1_a = 0, 0
    if pv1_regs then
        mppt1_v = pv1_regs[1] * 0.1
        mppt1_a = pv1_regs[2] * 0.01
    end

    -- PV2 voltage: 0x105C=4188, U16 × 0.1V
    -- PV2 current: 0x105D=4189, U16 × 0.01A
    local pv2_regs = probe_read(4188, 2, "input")
    local mppt2_v, mppt2_a = 0, 0
    if pv2_regs then
        mppt2_v = pv2_regs[1] * 0.1
        mppt2_a = pv2_regs[2] * 0.01
    end

    -- PV power: 0x1062-0x1063=4194-4195, U32 BE, W
    local pvw_regs = probe_read(4194, 2, "input")
    local pv_w = 0
    if pvw_regs then
        pv_w = host.decode_u32_be(pvw_regs[1], pvw_regs[2])
    end

    -- Grid frequency: 0x104F=4175, U16 × 0.01Hz
    local hz_regs = probe_read(4175, 1, "input")
    local hz = 0
    if hz_regs then
        hz = hz_regs[1] * 0.01
    end

    -- Emit PV telemetry (W always negative for generation)
    host.emit("pv", {
        W       = -pv_w,
        mppt1_v = mppt1_v,
        mppt1_a = mppt1_a,
        mppt2_v = mppt2_v,
        mppt2_a = mppt2_a,
    })

    -- ---- Battery ----

    -- Battery power: 0x1096=4246, I16, W (positive=charge, negative=discharge)
    local bw_regs = probe_read(4246, 1, "input")
    local bat_w = 0
    if bw_regs then
        bat_w = host.decode_i16(bw_regs[1])
    end

    -- Battery SoC: 0x1098=4248, U16, %
    local bsoc_regs = probe_read(4248, 1, "input")
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

    -- Grid power: 0x1072-0x1073=4210-4211, I32 BE, W (positive=import)
    local mw_regs = probe_read(4210, 2, "input")
    local meter_w = 0
    if mw_regs then
        meter_w = host.decode_i32_be(mw_regs[1], mw_regs[2])
    end

    -- Phase voltages: 0x1048=4168 (L1), 0x104A=4170 (L2), 0x104C=4172 (L3), U16 × 0.1V
    local lv1_regs = probe_read(4168, 1, "input")
    local l1_v = 0
    if lv1_regs then
        l1_v = lv1_regs[1] * 0.1
    end

    local lv2_regs = probe_read(4170, 1, "input")
    local l2_v = 0
    if lv2_regs then
        l2_v = lv2_regs[1] * 0.1
    end

    local lv3_regs = probe_read(4172, 1, "input")
    local l3_v = 0
    if lv3_regs then
        l3_v = lv3_regs[1] * 0.1
    end

    -- Phase currents: 0x1049=4169 (L1), 0x104B=4171 (L2), 0x104D=4173 (L3), U16 × 0.01A
    local la1_regs = probe_read(4169, 1, "input")
    local l1_a = 0
    if la1_regs then
        l1_a = la1_regs[1] * 0.01
    end

    local la2_regs = probe_read(4171, 1, "input")
    local l2_a = 0
    if la2_regs then
        l2_a = la2_regs[1] * 0.01
    end

    local la3_regs = probe_read(4173, 1, "input")
    local l3_a = 0
    if la3_regs then
        l3_a = la3_regs[1] * 0.01
    end

    -- Emit Meter telemetry
    host.emit("meter", {
        W    = meter_w,
        L1_V = l1_v,
        L2_V = l2_v,
        L3_V = l3_v,
        L1_A = l1_a,
        L2_A = l2_a,
        L3_A = l3_a,
        Hz   = hz,
    })

    return 5000
end

function driver_command(action, power_w, cmd)
    host.log("SAJ control not yet implemented: " .. action)
    return false
end

function driver_default_mode()
end

function driver_cleanup()
    -- nothing to clean up
end
