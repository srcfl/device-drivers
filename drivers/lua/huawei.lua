-- Huawei Hybrid Inverter Driver
-- Emits: PV, Battery, Meter
-- Register type: ALL HOLDING
-- Byte order: Big-Endian

PROTOCOL = "modbus"

local function write_u32(addr, val)
    val = math.floor(math.abs(val))
    local hi = math.floor(val / 65536)
    local lo = val % 65536
    host.modbus_write_multiple(addr, {hi, lo})
end

function driver_init(config)
    host.set_make("Huawei")
end

function driver_poll()
    -- ---- PV ----

    -- PV1 V/A: 32016-32017, I16 × 0.1 V, I16 × 0.01 A
    local ok_pv1, pv1_regs = pcall(host.modbus_read, 32016, 2, "holding")
    local pv1_v, pv1_a = 0, 0
    if ok_pv1 then
        pv1_v = host.decode_i16(pv1_regs[1]) * 0.1
        pv1_a = host.decode_i16(pv1_regs[2]) * 0.01
    end

    -- PV2 V/A: 32018-32019, I16 × 0.1 V, I16 × 0.01 A
    local ok_pv2, pv2_regs = pcall(host.modbus_read, 32018, 2, "holding")
    local pv2_v, pv2_a = 0, 0
    if ok_pv2 then
        pv2_v = host.decode_i16(pv2_regs[1]) * 0.1
        pv2_a = host.decode_i16(pv2_regs[2]) * 0.01
    end

    -- Input power (PV total): 32064-32065, I32 BE × 0.001 kW -> multiply by 1000 for watts
    local ok_pvw, pvw_regs = pcall(host.modbus_read, 32064, 2, "holding")
    local pv_w = 0
    if ok_pvw then
        pv_w = host.decode_i32(pvw_regs[1], pvw_regs[2]) * 0.001 * 1000  -- kW to W
    end

    -- Inverter temperature: 32087, I16 × 0.1 C
    local ok_itemp, itemp_regs = pcall(host.modbus_read, 32087, 1, "holding")
    local inv_temp = 0
    if ok_itemp then
        inv_temp = host.decode_i16(itemp_regs[1]) * 0.1
    end

    -- PV yield: 32106-32107, U32 BE × 0.01 kWh -> ×1000 for Wh
    local ok_yield, yield_regs = pcall(host.modbus_read, 32106, 2, "holding")
    local pv_gen_wh = 0
    if ok_yield then
        pv_gen_wh = host.decode_u32(yield_regs[1], yield_regs[2]) * 0.01 * 1000
    end

    -- Emit PV telemetry (W always negative for generation)
    host.emit("pv", {
        w           = -pv_w,
        mppt1_v     = pv1_v,
        mppt1_a     = pv1_a,
        mppt2_v     = pv2_v,
        mppt2_a     = pv2_a,
        lifetime_wh = pv_gen_wh,
        temp_c      = inv_temp,
    })

    -- ---- Battery ----

    -- Battery power: 37001-37002, I32 BE, watts (positive=charging, negative=discharging)
    local ok_bw, bw_regs = pcall(host.modbus_read, 37001, 2, "holding")
    local bat_w = 0
    if ok_bw then
        bat_w = host.decode_i32(bw_regs[1], bw_regs[2])
    end

    -- Battery bus voltage: 37003, U16 × 0.1 V
    local ok_bv, bv_regs = pcall(host.modbus_read, 37003, 1, "holding")
    local bat_v = 0
    if ok_bv then
        bat_v = bv_regs[1] * 0.1
    end

    -- Battery SoC: 37004, U16 × 0.1 percent
    local ok_bsoc, bsoc_regs = pcall(host.modbus_read, 37004, 1, "holding")
    local bat_soc = 0
    if ok_bsoc then
        bat_soc = bsoc_regs[1] * 0.1 / 100  -- percent to fraction
    end

    -- Battery current: 37021, I16 × 0.1 A
    local ok_ba, ba_regs = pcall(host.modbus_read, 37021, 1, "holding")
    local bat_a = 0
    if ok_ba then
        bat_a = host.decode_i16(ba_regs[1]) * 0.1
    end

    -- Battery temperature: 37022, I16 × 0.1 C
    local ok_btemp, btemp_regs = pcall(host.modbus_read, 37022, 1, "holding")
    local bat_temp = 0
    if ok_btemp then
        bat_temp = host.decode_i16(btemp_regs[1]) * 0.1
    end

    -- Battery charge/discharge energy: 37066-37069, U32 BE × 0.01 kWh pairs
    local ok_benergy, benergy_regs = pcall(host.modbus_read, 37066, 4, "holding")
    local bat_charge_wh, bat_discharge_wh = 0, 0
    if ok_benergy then
        bat_charge_wh    = host.decode_u32(benergy_regs[1], benergy_regs[2]) * 0.01 * 1000
        bat_discharge_wh = host.decode_u32(benergy_regs[3], benergy_regs[4]) * 0.01 * 1000
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

    -- ---- Meter ----

    -- Per-phase voltage: 37101-37106, I32 BE × 0.1 pairs (L1 V, L2 V, L3 V)
    local ok_lv, lv_regs = pcall(host.modbus_read, 37101, 6, "holding")
    local l1_v, l2_v, l3_v = 0, 0, 0
    if ok_lv then
        l1_v = host.decode_i32(lv_regs[1], lv_regs[2]) * 0.1
        l2_v = host.decode_i32(lv_regs[3], lv_regs[4]) * 0.1
        l3_v = host.decode_i32(lv_regs[5], lv_regs[6]) * 0.1
    end

    -- Per-phase current: 37107-37112, I32 BE × 0.01 pairs (L1 A, L2 A, L3 A)
    local ok_la, la_regs = pcall(host.modbus_read, 37107, 6, "holding")
    local l1_a, l2_a, l3_a = 0, 0, 0
    if ok_la then
        l1_a = host.decode_i32(la_regs[1], la_regs[2]) * 0.01
        l2_a = host.decode_i32(la_regs[3], la_regs[4]) * 0.01
        l3_a = host.decode_i32(la_regs[5], la_regs[6]) * 0.01
    end

    -- Meter total power: 37113-37114, I32 BE, watts
    local ok_mw, mw_regs = pcall(host.modbus_read, 37113, 2, "holding")
    local meter_w = 0
    if ok_mw then
        meter_w = host.decode_i32(mw_regs[1], mw_regs[2])
    end

    -- Frequency: 37118, I16 × 0.01 Hz
    local ok_hz, hz_regs = pcall(host.modbus_read, 37118, 1, "holding")
    local hz = 0
    if ok_hz then
        hz = host.decode_i16(hz_regs[1]) * 0.01
    end

    -- Export/Import energy: 37119-37122, I32 BE × 0.01 kWh pairs
    local ok_energy, energy_regs = pcall(host.modbus_read, 37119, 4, "holding")
    local export_wh, import_wh = 0, 0
    if ok_energy then
        export_wh = host.decode_i32(energy_regs[1], energy_regs[2]) * 0.01 * 1000
        import_wh = host.decode_i32(energy_regs[3], energy_regs[4]) * 0.01 * 1000
    end

    -- Per-phase power: 37132-37137, I32 BE pairs, watts
    local ok_lpw, lpw_regs = pcall(host.modbus_read, 37132, 6, "holding")
    local l1_w, l2_w, l3_w = 0, 0, 0
    if ok_lpw then
        l1_w = host.decode_i32(lpw_regs[1], lpw_regs[2])
        l2_w = host.decode_i32(lpw_regs[3], lpw_regs[4])
        l3_w = host.decode_i32(lpw_regs[5], lpw_regs[6])
    end

    -- Emit Meter telemetry (negate current and power for our convention)
    host.emit("meter", {
        w         = -meter_w,
        l1_w      = -l1_w,
        l2_w      = -l2_w,
        l3_w      = -l3_w,
        l1_v      = l1_v,
        l2_v      = l2_v,
        l3_v      = l3_v,
        l1_a      = -l1_a,
        l2_a      = -l2_a,
        l3_a      = -l3_a,
        hz        = hz,
        import_wh = import_wh,
        export_wh = export_wh,
    })

    return 5000
end

function driver_command(action, power_w, cmd)
    if action == "init" then
        -- Set forcible mode to duration-based, 24h period
        host.modbus_write(47246, 0)   -- duration mode
        host.modbus_write(47083, 1440) -- 24h period (not stored, must re-send)
        return true
    elseif action == "battery" then
        if power_w > 0 then
            -- Forcible charge: set power then trigger
            -- 47247-47248: U32, kW, gain 1000 (raw = watts)
            write_u32(47247, power_w)
            host.modbus_write(47083, 1440)
            host.modbus_write(47100, 1)  -- trigger charge
        elseif power_w < 0 then
            -- Forcible discharge: set power then trigger
            -- 47249-47250: U32, kW, gain 1000 (raw = watts)
            write_u32(47249, math.abs(power_w))
            host.modbus_write(47083, 1440)
            host.modbus_write(47100, 2)  -- trigger discharge
        else
            host.modbus_write(47100, 0)  -- stop
        end
        return true
    elseif action == "curtail" then
        -- Force charge to absorb excess PV
        write_u32(47247, math.abs(power_w))
        host.modbus_write(47083, 1440)
        host.modbus_write(47100, 1)
        return true
    elseif action == "curtail_disable" then
        host.modbus_write(47100, 0)
        return true
    elseif action == "deinit" then
        -- Stop forcible mode, return to max self-consumption
        host.modbus_write(47100, 0)
        host.modbus_write(47086, 2)  -- maximise self consumption
        return true
    end
    return false
end

function driver_default_mode()
    host.modbus_write(47100, 0)
    host.modbus_write(47086, 2)  -- maximise self consumption
end

function driver_cleanup()
    -- nothing to clean up
end
