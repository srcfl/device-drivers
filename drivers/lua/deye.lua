-- Deye Hybrid Inverter Driver
-- Emits: PV, Battery, Meter
-- Register type: ALL HOLDING
-- Byte order: Little-Endian for multi-register values
-- Supports LV and HV models (detected via register 0)

PROTOCOL = "modbus"

local is_hv = false

function driver_init(config)
    host.set_make("Deye")
end

function driver_poll()
    -- Detect HV mode from register 0
    local ok_mode, mode_regs = pcall(host.modbus_read, 0, 1, "holding")
    if ok_mode then
        local val = mode_regs[1]
        -- Lua 5.1 compatible: check high byte (val >> 8) without bitwise ops
        is_hv = (val == 6) or (math.floor(val / 256) == 6)
    end

    -- ---- PV ----

    -- PV1-PV4 power: 672-675, U16 each (×1 LV, ×10 HV)
    local ok_pvw, pvw_regs = pcall(host.modbus_read, 672, 4, "holding")
    local pv_total_w = 0
    if ok_pvw then
        local pv_scale = is_hv and 10 or 1
        for i = 1, 4 do
            pv_total_w = pv_total_w + pvw_regs[i] * pv_scale
        end
    end

    -- MPPT1 V/A: 676-677, U16 × 0.1 each
    local ok_m1, m1_regs = pcall(host.modbus_read, 676, 2, "holding")
    local mppt1_v, mppt1_a = 0, 0
    if ok_m1 then
        mppt1_v = m1_regs[1] * 0.1
        mppt1_a = m1_regs[2] * 0.1
    end

    -- MPPT2 V/A: 678-679, U16 × 0.1 each
    local ok_m2, m2_regs = pcall(host.modbus_read, 678, 2, "holding")
    local mppt2_v, mppt2_a = 0, 0
    if ok_m2 then
        mppt2_v = m2_regs[1] * 0.1
        mppt2_a = m2_regs[2] * 0.1
    end

    -- Total generation: 534-535, U32 LE × 0.1 kWh
    local ok_gen, gen_regs = pcall(host.modbus_read, 534, 2, "holding")
    local pv_gen_wh = 0
    if ok_gen then
        pv_gen_wh = host.decode_u32_le(gen_regs[1], gen_regs[2]) * 0.1 * 1000
    end

    -- Rated power: 20-21, U32 LE × 0.1 kW
    local ok_rated, rated_regs = pcall(host.modbus_read, 20, 2, "holding")
    local rated_w = 0
    if ok_rated then
        rated_w = host.decode_u32_le(rated_regs[1], rated_regs[2]) * 0.1 * 1000
    end

    -- Heatsink temperature: 541, U16 × 0.1 C
    local ok_temp, temp_regs = pcall(host.modbus_read, 541, 1, "holding")
    local heatsink_c = 0
    if ok_temp then
        heatsink_c = temp_regs[1] * 0.1
    end

    -- Emit PV telemetry (W always negative for generation)
    host.emit("pv", {
        w           = -pv_total_w,
        mppt1_v     = mppt1_v,
        mppt1_a     = mppt1_a,
        mppt2_v     = mppt2_v,
        mppt2_a     = mppt2_a,
        lifetime_wh = pv_gen_wh,
        rated_w     = rated_w,
        temp_c      = heatsink_c,
    })

    -- ---- Battery ----

    -- Battery voltage: 587, U16 (×0.01 LV, ×0.1 HV)
    local ok_bv, bv_regs = pcall(host.modbus_read, 587, 1, "holding")
    local bat_v = 0
    if ok_bv then
        bat_v = bv_regs[1] * (is_hv and 0.1 or 0.01)
    end

    -- Battery SoC: 588, U16, percent
    local ok_bsoc, bsoc_regs = pcall(host.modbus_read, 588, 1, "holding")
    local bat_soc = 0
    if ok_bsoc then
        bat_soc = bsoc_regs[1] / 100  -- percent to fraction
    end

    -- Battery power: 590, I16 (×1 LV, ×10 HV)
    local ok_bw, bw_regs = pcall(host.modbus_read, 590, 1, "holding")
    local bat_w = 0
    if ok_bw then
        local bat_scale = is_hv and 10 or 1
        bat_w = host.decode_i16(bw_regs[1]) * bat_scale
    end

    -- Battery current: 591, I16 × 0.01 A
    local ok_ba, ba_regs = pcall(host.modbus_read, 591, 1, "holding")
    local bat_a = 0
    if ok_ba then
        bat_a = host.decode_i16(ba_regs[1]) * 0.01
    end

    -- Battery temperature: 217, U16, temp = (val - 1000) / 10
    local ok_btemp, btemp_regs = pcall(host.modbus_read, 217, 1, "holding")
    local bat_temp = 0
    if ok_btemp then
        bat_temp = (btemp_regs[1] - 1000) / 10
    end

    -- Battery charge energy: 516-517, U16 × 0.1 kWh, LE pair
    local ok_bchg, bchg_regs = pcall(host.modbus_read, 516, 2, "holding")
    local bat_charge_wh = 0
    if ok_bchg then
        bat_charge_wh = host.decode_u32_le(bchg_regs[1], bchg_regs[2]) * 0.1 * 1000
    end

    -- Battery discharge energy: 518-519, U16 × 0.1 kWh, LE pair
    local ok_bdis, bdis_regs = pcall(host.modbus_read, 518, 2, "holding")
    local bat_discharge_wh = 0
    if ok_bdis then
        bat_discharge_wh = host.decode_u32_le(bdis_regs[1], bdis_regs[2]) * 0.1 * 1000
    end

    -- Emit Battery telemetry (negate W for sign convention)
    host.emit("battery", {
        w            = -bat_w,
        v            = bat_v,
        a            = bat_a,
        soc          = bat_soc,
        temp_c       = bat_temp,
        charge_wh    = bat_charge_wh,
        discharge_wh = bat_discharge_wh,
    })

    -- ---- Meter ----

    -- Per-phase voltage: 598-600, U16 × 0.1 each
    local ok_lv, lv_regs = pcall(host.modbus_read, 598, 3, "holding")
    local l1_v, l2_v, l3_v = 0, 0, 0
    if ok_lv then
        l1_v = lv_regs[1] * 0.1
        l2_v = lv_regs[2] * 0.1
        l3_v = lv_regs[3] * 0.1
    end

    -- Frequency: 609, U16 × 0.01 Hz
    local ok_hz, hz_regs = pcall(host.modbus_read, 609, 1, "holding")
    local hz = 0
    if ok_hz then
        hz = hz_regs[1] * 0.01
    end

    -- Per-phase current: 610-612, I16 × 0.01 each
    local ok_la, la_regs = pcall(host.modbus_read, 610, 3, "holding")
    local l1_a, l2_a, l3_a = 0, 0, 0
    if ok_la then
        l1_a = host.decode_i16(la_regs[1]) * 0.01
        l2_a = host.decode_i16(la_regs[2]) * 0.01
        l3_a = host.decode_i16(la_regs[3]) * 0.01
    end

    -- Total meter power: 619, I16, watts
    local ok_tw, tw_regs = pcall(host.modbus_read, 619, 1, "holding")
    local meter_w = 0
    if ok_tw then
        meter_w = host.decode_i16(tw_regs[1])
    end

    -- Per-phase power: 622-624, I16 each, watts
    local ok_lw, lw_regs = pcall(host.modbus_read, 622, 3, "holding")
    local l1_w, l2_w, l3_w = 0, 0, 0
    if ok_lw then
        l1_w = host.decode_i16(lw_regs[1])
        l2_w = host.decode_i16(lw_regs[2])
        l3_w = host.decode_i16(lw_regs[3])
    end

    -- Import energy: 522-523, U16 × 0.1 kWh, LE pair
    local ok_imp, imp_regs = pcall(host.modbus_read, 522, 2, "holding")
    local import_wh = 0
    if ok_imp then
        import_wh = host.decode_u32_le(imp_regs[1], imp_regs[2]) * 0.1 * 1000
    end

    -- Export energy: 524-525, U16 × 0.1 kWh, LE pair
    local ok_exp, exp_regs = pcall(host.modbus_read, 524, 2, "holding")
    local export_wh = 0
    if ok_exp then
        export_wh = host.decode_u32_le(exp_regs[1], exp_regs[2]) * 0.1 * 1000
    end

    -- Emit Meter telemetry
    host.emit("meter", {
        w         = meter_w,
        l1_w      = l1_w,
        l2_w      = l2_w,
        l3_w      = l3_w,
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
    host.log("Deye control not yet implemented: " .. action)
    return false
end

function driver_default_mode()
end

function driver_cleanup()
    -- nothing to clean up
end
