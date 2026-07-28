-- SolaX X1/X3 Hybrid Series Inverter Driver
-- Emits: PV, Battery, Meter
-- Register type: INPUT (FC 0x04)
-- Byte order: Big-Endian for multi-register values
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
            "SolaX: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

function driver_init(config)
    host.set_make("SolaX")
end

function driver_poll()
    -- ---- PV ----

    -- PV1: voltage=0 (U16 × 0.1V), current=1 (U16 × 0.1A), power=2 (U16, W)
    local pv1_regs = probe_read(0, 3, "input")
    local mppt1_v, mppt1_a, pv1_w = 0, 0, 0
    if pv1_regs then
        mppt1_v = pv1_regs[1] * 0.1
        mppt1_a = pv1_regs[2] * 0.1
        pv1_w   = pv1_regs[3]
    end

    -- PV2: voltage=3 (U16 × 0.1V), current=4 (U16 × 0.1A), power=5 (U16, W)
    local pv2_regs = probe_read(3, 3, "input")
    local mppt2_v, mppt2_a, pv2_w = 0, 0, 0
    if pv2_regs then
        mppt2_v = pv2_regs[1] * 0.1
        mppt2_a = pv2_regs[2] * 0.1
        pv2_w   = pv2_regs[3]
    end

    local pv_w = pv1_w + pv2_w

    -- Grid frequency: 7, U16 × 0.01Hz
    local hz_regs = probe_read(7, 1, "input")
    local hz = 0
    if hz_regs then
        hz = hz_regs[1] * 0.01
    end

    -- Total PV energy: 68-69, U32 BE × 0.1 kWh
    local pvgen_regs = probe_read(68, 2, "input")
    local pv_gen_wh = 0
    if pvgen_regs then
        pv_gen_wh = host.decode_u32_be(pvgen_regs[1], pvgen_regs[2]) * 0.1 * 1000
    end

    -- Emit PV telemetry (W always negative for generation)
    host.emit("pv", {
        W           = -pv_w,
        mppt1_v     = mppt1_v,
        mppt1_a     = mppt1_a,
        mppt2_v     = mppt2_v,
        mppt2_a     = mppt2_a,
        total_generation_Wh = pv_gen_wh,
    })

    -- ---- Battery ----

    -- Battery voltage: 20, U16 × 0.1V
    local bv_regs = probe_read(20, 1, "input")
    local bat_v = 0
    if bv_regs then
        bat_v = bv_regs[1] * 0.1
    end

    -- Battery current: 21, I16 × 0.1A
    local ba_regs = probe_read(21, 1, "input")
    local bat_a = 0
    if ba_regs then
        bat_a = host.decode_i16(ba_regs[1]) * 0.1
    end

    -- Battery power: 22, I16, W (positive=charge, negative=discharge)
    local bw_regs = probe_read(22, 1, "input")
    local bat_w = 0
    if bw_regs then
        bat_w = host.decode_i16(bw_regs[1])
    end

    -- Battery temperature: 24, I16 × 0.1C
    local btemp_regs = probe_read(24, 1, "input")
    local bat_temp = 0
    if btemp_regs then
        bat_temp = host.decode_i16(btemp_regs[1]) * 0.1
    end

    -- Battery SoC: 28, U16, %
    local bsoc_regs = probe_read(28, 1, "input")
    local bat_soc = 0
    if bsoc_regs then
        bat_soc = bsoc_regs[1] / 100  -- percent to fraction
    end

    -- Emit Battery telemetry
    host.emit("battery", {
        W      = bat_w,
        V      = bat_v,
        A      = bat_a,
        SoC_nom_fract    = bat_soc,
        temperature_C = bat_temp,
    })

    -- ---- Meter ----

    -- Grid power (meter): 70-71, I32 BE, W (positive=import)
    local mw_regs = probe_read(70, 2, "input")
    local meter_w = 0
    if mw_regs then
        meter_w = host.decode_i32_be(mw_regs[1], mw_regs[2])
    end

    -- Feed-in (export) energy: 72-73, U32 BE × 0.01 kWh
    local exp_regs = probe_read(72, 2, "input")
    local export_wh = 0
    if exp_regs then
        export_wh = host.decode_u32_be(exp_regs[1], exp_regs[2]) * 0.01 * 1000
    end

    -- Consumed (import) energy: 74-75, U32 BE × 0.01 kWh
    local imp_regs = probe_read(74, 2, "input")
    local import_wh = 0
    if imp_regs then
        import_wh = host.decode_u32_be(imp_regs[1], imp_regs[2]) * 0.01 * 1000
    end

    -- Emit Meter telemetry
    host.emit("meter", {
        W         = meter_w,
        Hz        = hz,
        total_import_Wh = import_wh,
        total_export_Wh = export_wh,
    })

    return 5000
end

function driver_command(action, power_w, cmd)
    host.log("SolaX control not yet implemented: " .. action)
    return false
end

function driver_default_mode()
end

function driver_cleanup()
    -- nothing to clean up
end
