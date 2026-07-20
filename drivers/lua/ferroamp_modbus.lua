-- ferroamp_modbus.lua
-- Ferroamp EnergyHub Modbus TCP driver
-- Emits: PV, Battery, Meter telemetry
--
-- Port: 502, Unit ID: 1 (default)
-- Float format: IEEE 754, word-swapped (low word at lower address)
-- Register map: Ferroamp proprietary (not SunSpec)
--
-- Sign convention:
--   PV W: always negative (generation)
--   Battery W: positive = charging, negative = discharging
--   Meter W: positive = import, negative = export

PROTOCOL = "modbus"

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

-- Decode word-swapped float32: Ferroamp stores low word first, high word second.
-- host.decode_f32 expects big-endian (hi, lo), so we swap.
local function decode_f32_ws(regs)
    return host.decode_f32(regs[2], regs[1])
end

-- Encode float32 to word-swapped uint16 pair for Modbus holding register writes.
-- Returns {lo_word, hi_word} suitable for host.modbus_write_multiple.
local function encode_f32_ws(value)
    if value == 0 then return {0, 0} end

    local sign = 0
    if value < 0 then
        sign = 0x80000000
        value = -value
    end

    local exp = 127
    if value >= 2 then
        while value >= 2 do
            value = value / 2
            exp = exp + 1
        end
    elseif value < 1 then
        while value < 1 do
            value = value * 2
            exp = exp - 1
        end
    end

    local mantissa = math.floor((value - 1) * 0x800000 + 0.5)
    local bits = sign + exp * 0x800000 + mantissa
    local hi = math.floor(bits / 0x10000)
    local lo = bits % 0x10000

    return {lo, hi}
end

----------------------------------------------------------------------------
-- Driver interface
----------------------------------------------------------------------------

function driver_init(config)
    host.set_make("Ferroamp")
end

function driver_poll()
    -- Grid frequency: input 2016, float32, Hz
    local ok_hz, hz_regs = pcall(host.modbus_read, 2016, 2, "input")
    local hz = 0
    if ok_hz then hz = decode_f32_ws(hz_regs) end

    -- Grid voltage L1/L2/L3: input 2032/2036/2040, float32, Vrms
    -- Each float is 2 regs, followed by 2 regs integer alt = 4 regs per value
    local ok_v, v_regs = pcall(host.modbus_read, 2032, 10, "input")
    local l1_v, l2_v, l3_v = 0, 0, 0
    if ok_v then
        l1_v = decode_f32_ws({v_regs[1], v_regs[2]})     -- 2032-2033
        l2_v = decode_f32_ws({v_regs[5], v_regs[6]})     -- 2036-2037
        l3_v = decode_f32_ws({v_regs[9], v_regs[10]})    -- 2040-2041
    end

    -- Grid active power (total): input 3100, float32, kW
    local ok_gw, gw_regs = pcall(host.modbus_read, 3100, 2, "input")
    local grid_w = 0
    if ok_gw then grid_w = decode_f32_ws(gw_regs) * 1000 end

    -- Grid active current L1/L2/L3: input 3112/3116/3120, float32, Arms
    local ok_ga, ga_regs = pcall(host.modbus_read, 3112, 10, "input")
    local l1_a, l2_a, l3_a = 0, 0, 0
    if ok_ga then
        l1_a = decode_f32_ws({ga_regs[1], ga_regs[2]})   -- 3112-3113
        l2_a = decode_f32_ws({ga_regs[5], ga_regs[6]})   -- 3116-3117
        l3_a = decode_f32_ws({ga_regs[9], ga_regs[10]})  -- 3120-3121
    end

    -- Per-phase power: V * I_active (no per-phase power registers available)
    local l1_w = l1_v * l1_a
    local l2_w = l2_v * l2_a
    local l3_w = l3_v * l3_a

    -- Grid energy: export at 3064, import at 3068, float32, kWh
    local ok_ge, ge_regs = pcall(host.modbus_read, 3064, 8, "input")
    local export_wh, import_wh = 0, 0
    if ok_ge then
        export_wh = decode_f32_ws({ge_regs[1], ge_regs[2]}) * 1000  -- 3064-3065
        import_wh = decode_f32_ws({ge_regs[5], ge_regs[6]}) * 1000  -- 3068-3069
    end

    host.emit("meter", {
        w         = grid_w,
        hz        = hz,
        l1_w      = l1_w,
        l2_w      = l2_w,
        l3_w      = l3_w,
        l1_v      = l1_v,
        l2_v      = l2_v,
        l3_v      = l3_v,
        l1_a      = l1_a,
        l2_a      = l2_a,
        l3_a      = l3_a,
        import_wh = import_wh,
        export_wh = export_wh,
    })

    -- Solar power: input 5100, float32, kW (always positive from Ferroamp)
    local ok_pv, pv_regs = pcall(host.modbus_read, 5100, 2, "input")
    local pv_w = 0
    if ok_pv then pv_w = decode_f32_ws(pv_regs) * 1000 end

    -- Solar energy produced: input 5064, float32, kWh
    local ok_pe, pe_regs = pcall(host.modbus_read, 5064, 2, "input")
    local pv_lifetime_wh = 0
    if ok_pe then pv_lifetime_wh = decode_f32_ws(pe_regs) * 1000 end

    -- Emit PV (W negative for generation)
    host.emit("pv", {
        w           = -pv_w,
        lifetime_wh = pv_lifetime_wh,
    })

    -- Battery power: input 6100, float32, kW
    -- Ferroamp: positive = discharging, negative = charging
    -- Our convention: positive = charging, negative = discharging -> negate
    local ok_bw, bw_regs = pcall(host.modbus_read, 6100, 2, "input")
    local bat_w = 0
    if ok_bw then bat_w = -decode_f32_ws(bw_regs) * 1000 end

    -- Battery SoC: input 6016, float32, percent -> fraction
    local ok_soc, soc_regs = pcall(host.modbus_read, 6016, 2, "input")
    local bat_soc = 0
    if ok_soc then bat_soc = decode_f32_ws(soc_regs) / 100 end

    -- Battery energy: discharge at 6064, charge at 6068, float32, kWh
    local ok_be, be_regs = pcall(host.modbus_read, 6064, 8, "input")
    local bat_discharge_wh, bat_charge_wh = 0, 0
    if ok_be then
        bat_discharge_wh = decode_f32_ws({be_regs[1], be_regs[2]}) * 1000  -- 6064-6065
        bat_charge_wh    = decode_f32_ws({be_regs[5], be_regs[6]}) * 1000  -- 6068-6069
    end

    host.emit("battery", {
        w            = bat_w,
        soc          = bat_soc,
        charge_wh    = bat_charge_wh,
        discharge_wh = bat_discharge_wh,
    })

    return 5000
end

-- Control: Battery mode at holding 6000 (uint16), power ref at holding 6064 (float32)
-- Ferroamp: Mode 0 = default/auto, Mode 1 = power-mode
-- Power ref: negative kW = charge, positive kW = discharge
--
-- Curtailment via grid power control: export limit at holding 8010-8016
function driver_command(action, power_w, cmd)
    if action == "init" then
        return true
    elseif action == "battery" then
        -- Our convention: positive power_w = charge
        -- Ferroamp: negative kW = charge -> negate and convert W to kW
        local ref_kw = -power_w / 1000
        host.modbus_write_multiple(6064, encode_f32_ws(ref_kw))
        host.modbus_write(6000, 1)  -- power mode
        return true
    elseif action == "curtail" then
        -- Limit export to |power_w| watts
        host.modbus_write(8010, 1)  -- enable export limit
        host.modbus_write_multiple(8012, encode_f32_ws(math.abs(power_w)))
        host.modbus_write(8016, 1)  -- apply
        return true
    elseif action == "curtail_disable" then
        host.modbus_write(8010, 0)  -- disable export limit
        host.modbus_write(8016, 1)  -- apply
        return true
    elseif action == "deinit" then
        -- Restore auto mode and remove export limits
        host.modbus_write(6000, 0)
        host.modbus_write(8010, 0)
        host.modbus_write(8016, 1)
        return true
    end
    return false
end

function driver_default_mode()
    host.modbus_write(6000, 0)  -- default/auto mode
end

function driver_cleanup()
end
