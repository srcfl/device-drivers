-- Solinteg Hybrid Inverter Driver
-- Emits: PV, Battery, Meter
-- Protocol: Modbus TCP/RTU (all registers via FC 0x03 holding)
-- Byte order: Big-Endian
-- Covers: Gen1 (MHT/MHS) and Gen2 (M2HT/M2HS) series
-- Register reference: Solinteg Hybrid Inverter Modbus Register Table V00.22

PROTOCOL = "modbus"

local MODE_GENERAL  = 257   -- 0x0101: General Mode (self-consumption)
local MODE_EMS_BATT = 771   -- 0x0303: EMS Battery Control Mode

-- Solinteg control convention (from EMS examples):
--   Pbat negative = charge, positive = discharge
--   Pinv positive = export, negative = import
-- Our convention:
--   Battery W: positive = charge, negative = discharge
--   Meter W:   positive = import, negative = export

-- Convert signed int16 to uint16 for modbus write
local function to_u16(val)
    val = math.floor(val)
    if val < 0 then
        return val + 65536
    end
    return val
end

function driver_init(config)
    host.set_make("Solinteg")
end

function driver_poll()
    -- =====================
    -- PV Telemetry
    -- =====================

    -- Total PV Input Power: 11028-11029, U32, kW, gain 1000 (raw = watts)
    local ok_pvw, pvw_regs = pcall(host.modbus_read, 11028, 2, "holding")
    local pv_w = 0
    if ok_pvw then
        pv_w = host.decode_u32(pvw_regs[1], pvw_regs[2])
    end

    -- PV1+PV2 Voltage/Current: 11038-11041, U16, gain 10
    local ok_pv, pv_regs = pcall(host.modbus_read, 11038, 4, "holding")
    local mppt1_v, mppt1_a, mppt2_v, mppt2_a = 0, 0, 0, 0
    if ok_pv then
        mppt1_v = pv_regs[1] * 0.1
        mppt1_a = pv_regs[2] * 0.1
        mppt2_v = pv_regs[3] * 0.1
        mppt2_a = pv_regs[4] * 0.1
    end

    -- Module temperature: 11032, I16, C, gain 10
    local ok_temp, temp_regs = pcall(host.modbus_read, 11032, 1, "holding")
    local inv_temp = 0
    if ok_temp then
        inv_temp = host.decode_i16(temp_regs[1]) * 0.1
    end

    -- Total PV Generation: 31112-31113, U32, kWh, gain 10
    local ok_pvgen, pvgen_regs = pcall(host.modbus_read, 31112, 2, "holding")
    local pv_gen_wh = 0
    if ok_pvgen then
        pv_gen_wh = host.decode_u32(pvgen_regs[1], pvgen_regs[2]) * 100
    end

    host.emit("pv", {
        w           = -pv_w,
        mppt1_v     = mppt1_v,
        mppt1_a     = mppt1_a,
        mppt2_v     = mppt2_v,
        mppt2_a     = mppt2_a,
        lifetime_wh = pv_gen_wh,
        temp_c      = inv_temp,
    })

    -- =====================
    -- Battery Telemetry
    -- =====================

    -- 30254: Battery_V (U16, V, gain 10)
    -- 30255: Battery_I (I16, A, gain 10)
    -- 30256: Battery_Mode (U16: 0=discharge, 1=charge)
    -- 30257: (padding)
    -- 30258-30259: Battery_P (I32, kW, gain 1000 = raw watts)
    local ok_bat, bat_regs = pcall(host.modbus_read, 30254, 6, "holding")
    local bat_v, bat_a, bat_mode, bat_w = 0, 0, 0, 0
    if ok_bat then
        bat_v    = bat_regs[1] * 0.1
        bat_a    = host.decode_i16(bat_regs[2]) * 0.1
        bat_mode = bat_regs[3]
        bat_w    = math.abs(host.decode_i32(bat_regs[5], bat_regs[6]))
    end

    -- Enforce our sign convention using Battery_Mode
    -- positive = charging, negative = discharging
    if bat_mode == 0 then
        bat_w = -bat_w
    end

    -- SOC: 33000, U16, %, gain 100 (raw 9500 = 95.00%)
    local ok_soc, soc_regs = pcall(host.modbus_read, 33000, 1, "holding")
    local bat_soc = 0
    if ok_soc then
        bat_soc = soc_regs[1] / 10000  -- percent to fraction
    end

    -- BMS Pack Temperature: 33003, I16, C, gain 10
    local ok_btemp, btemp_regs = pcall(host.modbus_read, 33003, 1, "holding")
    local bat_temp = 0
    if ok_btemp then
        bat_temp = host.decode_i16(btemp_regs[1]) * 0.1
    end

    -- Battery charge energy: 31108-31109, U32, kWh, gain 10
    local ok_bchg, bchg_regs = pcall(host.modbus_read, 31108, 2, "holding")
    local bat_charge_wh = 0
    if ok_bchg then
        bat_charge_wh = host.decode_u32(bchg_regs[1], bchg_regs[2]) * 100
    end

    -- Battery discharge energy: 31110-31111, U32, kWh, gain 10
    local ok_bdis, bdis_regs = pcall(host.modbus_read, 31110, 2, "holding")
    local bat_discharge_wh = 0
    if ok_bdis then
        bat_discharge_wh = host.decode_u32(bdis_regs[1], bdis_regs[2]) * 100
    end

    host.emit("battery", {
        w            = bat_w,
        v            = bat_v,
        a            = bat_a,
        soc          = bat_soc,
        temp_c       = bat_temp,
        charge_wh    = bat_charge_wh,
        discharge_wh = bat_discharge_wh,
    })

    -- =====================
    -- Meter Telemetry
    -- =====================

    -- Phase currents: 10983-10985, U16, A, gain 10
    local ok_mc, mc_regs = pcall(host.modbus_read, 10983, 3, "holding")
    local l1_a, l2_a, l3_a = 0, 0, 0
    if ok_mc then
        l1_a = mc_regs[1] * 0.1
        l2_a = mc_regs[2] * 0.1
        l3_a = mc_regs[3] * 0.1
    end

    -- Per-phase + total active power: 10994-11001 (I32 pairs, kW, gain 1000 = raw W)
    local ok_mp, mp_regs = pcall(host.modbus_read, 10994, 8, "holding")
    local l1_w, l2_w, l3_w, meter_w = 0, 0, 0, 0
    if ok_mp then
        l1_w    = host.decode_i32(mp_regs[1], mp_regs[2])
        l2_w    = host.decode_i32(mp_regs[3], mp_regs[4])
        l3_w    = host.decode_i32(mp_regs[5], mp_regs[6])
        meter_w = host.decode_i32(mp_regs[7], mp_regs[8])
    end

    -- AC side voltages + frequency: 11009-11015
    -- Phase A V, A I, Phase B V, B I, Phase C V, C I, Freq
    local ok_mv, mv_regs = pcall(host.modbus_read, 11009, 7, "holding")
    local l1_v, l2_v, l3_v, hz = 0, 0, 0, 0
    if ok_mv then
        l1_v = mv_regs[1] * 0.1   -- U16, V, gain 10
        l2_v = mv_regs[3] * 0.1
        l3_v = mv_regs[5] * 0.1
        hz   = mv_regs[7] * 0.01  -- U16, Hz, gain 100
    end

    -- Grid energy: 11002-11005
    -- 11002-11003: Export/injection energy, U32, kWh, gain 100
    -- 11004-11005: Import/purchasing energy, U32, kWh, gain 100
    local ok_me, me_regs = pcall(host.modbus_read, 11002, 4, "holding")
    local export_wh, import_wh = 0, 0
    if ok_me then
        export_wh = host.decode_u32(me_regs[1], me_regs[2]) * 10
        import_wh = host.decode_u32(me_regs[3], me_regs[4]) * 10
    end

    -- Solinteg Pmeter: positive=export, negative=import
    -- Our convention: positive=import, negative=export
    host.emit("meter", {
        w         = -meter_w,
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
        host.modbus_write(50000, MODE_EMS_BATT)
        return true
    elseif action == "battery" then
        -- Solinteg 50207: negative=charge, positive=discharge
        -- Our power_w: positive=charge, negative=discharge
        -- Register unit: kW * 100 = W / 10
        local reg_val = to_u16(math.floor(-power_w / 10))
        host.modbus_write(50207, reg_val)
        host.modbus_write(50210, 0)  -- PV priority
        return true
    elseif action == "curtail" then
        -- Absorb excess PV by force-charging battery
        local charge_reg = to_u16(math.floor(-math.abs(power_w) / 10))
        host.modbus_write(50207, charge_reg)
        host.modbus_write(50210, 0)
        return true
    elseif action == "curtail_disable" then
        -- Stop forced charging, idle battery
        host.modbus_write(50207, 0)
        return true
    elseif action == "deinit" then
        host.modbus_write(50000, MODE_GENERAL)
        return true
    end
    return false
end

function driver_default_mode()
    host.modbus_write(50000, MODE_GENERAL)
end

function driver_cleanup()
    -- nothing to clean up
end
