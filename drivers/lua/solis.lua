-- Solis Hybrid Inverter Driver
-- Emits: PV, Battery, Meter
-- Register type: INPUT (values) + HOLDING (limits)
-- Byte order: Big-Endian

PROTOCOL = "modbus"

function driver_init(config)
    host.set_make("Solis")
end

function driver_poll()
    -- PV DC power: 33057-33058, U32 BE, watts
    local ok_pvw, pvw_regs = pcall(host.modbus_read, 33057, 2, "input")
    local pv_w = 0
    if ok_pvw then
        pv_w = host.decode_u32(pvw_regs[1], pvw_regs[2])
    end

    -- MPPT1 V/A: 33049-33050, U16 × 0.1 each
    local ok_mppt1, mppt1_regs = pcall(host.modbus_read, 33049, 2, "input")
    local mppt1_v, mppt1_a = 0, 0
    if ok_mppt1 then
        mppt1_v = mppt1_regs[1] * 0.1
        mppt1_a = mppt1_regs[2] * 0.1
    end

    -- MPPT2 V/A: 33051-33052, U16 × 0.1 each
    local ok_mppt2, mppt2_regs = pcall(host.modbus_read, 33051, 2, "input")
    local mppt2_v, mppt2_a = 0, 0
    if ok_mppt2 then
        mppt2_v = mppt2_regs[1] * 0.1
        mppt2_a = mppt2_regs[2] * 0.1
    end

    -- PV generation energy: 33029-33030, U32 BE, kWh
    local ok_pvgen, pvgen_regs = pcall(host.modbus_read, 33029, 2, "input")
    local pv_gen_wh = 0
    if ok_pvgen then
        pv_gen_wh = host.decode_u32(pvgen_regs[1], pvgen_regs[2]) * 1000
    end

    -- Inverter temperature: 33093, I16 × 0.1 C
    local ok_itemp, itemp_regs = pcall(host.modbus_read, 33093, 1, "input")
    local inv_temp = 0
    if ok_itemp then
        inv_temp = host.decode_i16(itemp_regs[1]) * 0.1
    end

    -- Emit PV telemetry (W always negative for generation)
    host.emit("pv", {
        w           = -pv_w,
        mppt1_v     = mppt1_v,
        mppt1_a     = mppt1_a,
        mppt2_v     = mppt2_v,
        mppt2_a     = mppt2_a,
        lifetime_wh = pv_gen_wh,
        temp_c      = inv_temp,
    })

    -- Battery voltage: 33133, U16 × 0.1 V
    local ok_bv, bv_regs = pcall(host.modbus_read, 33133, 1, "input")
    local bat_v = 0
    if ok_bv then
        bat_v = bv_regs[1] * 0.1
    end

    -- Battery current: 33134, I16 × 0.1 A
    local ok_ba, ba_regs = pcall(host.modbus_read, 33134, 1, "input")
    local bat_a = 0
    if ok_ba then
        bat_a = host.decode_i16(ba_regs[1]) * 0.1
    end

    -- Battery direction: 33135, U16 (0=charge, 1=discharge)
    local ok_bdir, bdir_regs = pcall(host.modbus_read, 33135, 1, "input")
    local bat_direction = 0
    if ok_bdir then
        bat_direction = bdir_regs[1]
    end

    -- Battery SoC: 33139, U16, percent
    local ok_bsoc, bsoc_regs = pcall(host.modbus_read, 33139, 1, "input")
    local bat_soc = 0
    if ok_bsoc then
        bat_soc = bsoc_regs[1] / 100  -- percent to fraction
    end

    -- Battery power: 33149-33150, I32 BE, watts
    local ok_bw, bw_regs = pcall(host.modbus_read, 33149, 2, "input")
    local bat_w = 0
    if ok_bw then
        bat_w = host.decode_i32(bw_regs[1], bw_regs[2])
    end

    -- Negate battery W if discharging
    if bat_direction == 1 then
        bat_w = -bat_w
    end

    -- Battery charge energy: 33161-33162, U32 BE, kWh
    local ok_bchg, bchg_regs = pcall(host.modbus_read, 33161, 2, "input")
    local bat_charge_wh = 0
    if ok_bchg then
        bat_charge_wh = host.decode_u32(bchg_regs[1], bchg_regs[2]) * 1000
    end

    -- Battery discharge energy: 33165-33166, U32 BE, kWh
    local ok_bdis, bdis_regs = pcall(host.modbus_read, 33165, 2, "input")
    local bat_discharge_wh = 0
    if ok_bdis then
        bat_discharge_wh = host.decode_u32(bdis_regs[1], bdis_regs[2]) * 1000
    end

    -- Battery temperature: 33096, I16 × 0.1 C
    local ok_btemp, btemp_regs = pcall(host.modbus_read, 33096, 1, "input")
    local bat_temp = 0
    if ok_btemp then
        bat_temp = host.decode_i16(btemp_regs[1]) * 0.1
    end

    -- Emit Battery telemetry
    host.emit("battery", {
        w            = bat_w,
        v            = bat_v,
        a            = bat_a,
        soc          = bat_soc,
        temp_c       = bat_temp,
        charge_wh    = bat_charge_wh,
        discharge_wh = bat_discharge_wh,
    })

    -- Per-phase V/A: 33251-33256, alternating U16 × 0.1 V / U16 × 0.01 A
    local ok_mva, mva_regs = pcall(host.modbus_read, 33251, 6, "input")
    local l1_v, l1_a, l2_v, l2_a, l3_v, l3_a = 0, 0, 0, 0, 0, 0
    if ok_mva then
        l1_v = mva_regs[1] * 0.1
        l1_a = mva_regs[2] * 0.01
        l2_v = mva_regs[3] * 0.1
        l2_a = mva_regs[4] * 0.01
        l3_v = mva_regs[5] * 0.1
        l3_a = mva_regs[6] * 0.01
    end

    -- Per-phase power: 33257-33262, I32 BE each pair, watts
    local ok_mpw, mpw_regs = pcall(host.modbus_read, 33257, 6, "input")
    local l1_w, l2_w, l3_w = 0, 0, 0
    if ok_mpw then
        l1_w = host.decode_i32(mpw_regs[1], mpw_regs[2])
        l2_w = host.decode_i32(mpw_regs[3], mpw_regs[4])
        l3_w = host.decode_i32(mpw_regs[5], mpw_regs[6])
    end

    -- Meter total W = sum of phases, negated (Solis grid convention)
    local meter_w = -(l1_w + l2_w + l3_w)

    -- Frequency: 33282, U16 × 0.01 Hz
    local ok_hz, hz_regs = pcall(host.modbus_read, 33282, 1, "input")
    local hz = 0
    if ok_hz then
        hz = hz_regs[1] * 0.01
    end

    -- Import energy: 33283-33284, U32 BE × 0.01 kWh
    local ok_imp, imp_regs = pcall(host.modbus_read, 33283, 2, "input")
    local import_wh = 0
    if ok_imp then
        import_wh = host.decode_u32(imp_regs[1], imp_regs[2]) * 0.01 * 1000
    end

    -- Export energy: 33285-33286, U32 BE × 0.01 kWh
    local ok_exp, exp_regs = pcall(host.modbus_read, 33285, 2, "input")
    local export_wh = 0
    if ok_exp then
        export_wh = host.decode_u32(exp_regs[1], exp_regs[2]) * 0.01 * 1000
    end

    -- Emit Meter telemetry (negate per-phase to match our convention)
    host.emit("meter", {
        w         = meter_w,
        l1_w      = -l1_w,
        l2_w      = -l2_w,
        l3_w      = -l3_w,
        l1_v      = l1_v,
        l2_v      = l2_v,
        l3_v      = l3_v,
        l1_a      = l1_a,
        l2_a      = l2_a,
        l3_a      = l3_a,
        hz        = hz,
        import_wh = import_wh,
        export_wh = export_wh,
    })

    return 5000
end

function driver_command(action, power_w, cmd)
    if action == "init" then
        return true
    elseif action == "battery" then
        if power_w > 0 then
            -- Charge: set limit then mode=1 (forced_charge)
            host.modbus_write(43050, power_w)
            host.modbus_write(43049, 1)
        elseif power_w < 0 then
            -- Discharge: set limit then mode=2 (forced_discharge)
            host.modbus_write(43051, math.abs(power_w))
            host.modbus_write(43049, 2)
        else
            -- Auto mode
            host.modbus_write(43049, 0)
        end
        return true
    elseif action == "curtail" then
        host.modbus_write(43050, math.abs(power_w))
        host.modbus_write(43049, 1)
        return true
    elseif action == "curtail_disable" or action == "deinit" then
        host.modbus_write(43049, 0)
        return true
    end
    return false
end

function driver_default_mode()
    host.modbus_write(43049, 0)  -- auto mode
end

function driver_cleanup()
    -- nothing to clean up
end
