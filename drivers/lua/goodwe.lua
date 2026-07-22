-- GoodWe read-only inverter driver.
--
-- Register type: holding registers (Modbus FC03).
-- Multi-register values use the high word first.
--
-- The gw8kn-et-hk3000 profile is based on the MIT-licensed field profile in
-- srcfl/hugin-drivers@3125960a80b5237e3a5ac609963ddb1302367938. frekes81
-- contributed that profile from a GW8KN-ET with an HK3000 meter. FTW hardware
-- approval still needs the pilot in packages/v1/goodwe/PILOT.md.

DRIVER = {
    id = "goodwe",
    name = "GoodWe inverter",
    manufacturer = "GoodWe",
    version = "1.0.2",
    host_api_min = 1,
    host_api_max = 1,
    protocols = { "modbus" },
    capabilities = { "pv", "battery", "meter" },
    description = "GoodWe telemetry with explicit register-map profiles.",
    authors = { "frekes81", "Sourceful contributors" },
    tested_models = {},
    verification_status = "experimental",
    verification_notes = "GW8KN-ET and HK3000 need the documented FTW hardware pilot before stable use.",
    read_only = true,
    connection_defaults = {
        port = 502,
        unit_id = 1,
    },
}

PROTOCOL = "modbus"

local profile = nil

local function holding(address, count)
    local ok, registers = pcall(host.modbus_read, address, count, "holding")
    if not ok then
        error("GoodWe holding read failed at " .. address)
    end
    if type(registers) ~= "table" or #registers < count then
        error("GoodWe holding read at " .. address .. " returned fewer than " .. count .. " registers")
    end
    return registers
end

local function nonnegative_i16(raw, address)
    local value = host.decode_i16(raw)
    if value < 0 then
        error("GoodWe holding register " .. address .. " returned an invalid negative power")
    end
    return value
end

local function emit_battery(w, soc, v, a, temp_c)
    if v > 0 or soc > 0 or w ~= 0 then
        host.emit("battery", {
            w = w,
            soc = soc,
            v = v,
            a = a,
            temp_c = temp_c,
        })
    end
end

local function poll_community_v1()
    -- Keep the 1.0.1 read boundaries until this profile has its own raw
    -- fixture and hardware test. Read all 22 fields before the first emit.
    local pv_total = holding(35105, 2)
    local mppt1 = holding(35103, 2)
    local mppt2 = holding(35109, 2)
    local frequency = holding(35113, 1)
    local pv_energy = holding(35191, 2)
    local battery_voltage = holding(35178, 1)
    local battery_current = holding(35179, 1)
    local battery_power = holding(35180, 1)
    local battery_soc = holding(35182, 1)
    local battery_temp = holding(35183, 1)
    local meter_total = holding(35140, 2)
    local meter_l1_power = holding(35132, 2)
    local meter_l2_power = holding(35134, 2)
    local meter_l3_power = holding(35136, 2)
    local meter_l1_voltage = holding(35121, 1)
    local meter_l2_voltage = holding(35123, 1)
    local meter_l3_voltage = holding(35125, 1)
    local meter_l1_current = holding(35122, 1)
    local meter_l2_current = holding(35124, 1)
    local meter_l3_current = holding(35126, 1)
    local import_energy = holding(35195, 2)
    local export_energy = holding(35199, 2)

    local pv_w = host.decode_u32_be(pv_total[1], pv_total[2]) * 0.1
    host.emit("pv", {
        w = -pv_w,
        mppt1_v = mppt1[1] * 0.1,
        mppt1_a = mppt1[2] * 0.1,
        mppt2_v = mppt2[1] * 0.1,
        mppt2_a = mppt2[2] * 0.1,
        lifetime_wh = host.decode_u32_be(pv_energy[1], pv_energy[2]) * 100,
    })

    local bat_w = host.decode_i16(battery_power[1])
    local bat_soc = battery_soc[1] / 100
    emit_battery(
        bat_w,
        bat_soc,
        battery_voltage[1] * 0.1,
        host.decode_i16(battery_current[1]) * 0.1,
        host.decode_i16(battery_temp[1]) * 0.1
    )

    host.emit("meter", {
        w = -host.decode_i32_be(meter_total[1], meter_total[2]),
        l1_w = -host.decode_i32_be(meter_l1_power[1], meter_l1_power[2]),
        l2_w = -host.decode_i32_be(meter_l2_power[1], meter_l2_power[2]),
        l3_w = -host.decode_i32_be(meter_l3_power[1], meter_l3_power[2]),
        l1_v = meter_l1_voltage[1] * 0.1,
        l2_v = meter_l2_voltage[1] * 0.1,
        l3_v = meter_l3_voltage[1] * 0.1,
        l1_a = meter_l1_current[1] * 0.1,
        l2_a = meter_l2_current[1] * 0.1,
        l3_a = meter_l3_current[1] * 0.1,
        hz = frequency[1] * 0.01,
        import_wh = host.decode_u32_be(import_energy[1], import_energy[2]) * 100,
        export_wh = host.decode_u32_be(export_energy[1], export_energy[2]) * 100,
    })

    return 5000
end

local function poll_gw8kn_et_hk3000()
    -- 35107..35110: PV1 V, A, ignored 35109 and I16 string power.
    local pv = holding(35107, 4)
    if not pv then return 5000 end

    -- 35123: grid frequency.
    local frequency = holding(35123, 1)
    if not frequency then return 5000 end

    -- 35125..35135: inverter phase power at offsets 0, 5 and 10.
    local inverter_phase = holding(35125, 11)
    if not inverter_phase then return 5000 end

    -- 35138..35140: I16 inverter total, ignored 35139 and I16 meter total.
    local ac_total = holding(35138, 3)
    if not ac_total then return 5000 end

    -- 35145..35157: phase voltage at offsets 0, 6 and 12.
    local meter_voltage = holding(35145, 13)
    if not meter_voltage then return 5000 end

    -- 35164..35168: phase load at offsets 0, 2 and 4.
    local load = holding(35164, 5)
    if not load then return 5000 end

    -- 35178..35183: battery V, ignored current, W, reserved, SoC and temp.
    local battery = holding(35178, 6)
    if not battery then return 5000 end

    -- 35195..35199: import counter, ignored 35197 and export counter.
    local energy = holding(35195, 5)
    if not energy then return 5000 end

    local l1_v = meter_voltage[1] * 0.1
    local l2_v = meter_voltage[7] * 0.1
    local l3_v = meter_voltage[13] * 0.1
    local pv_w = nonnegative_i16(ac_total[1], 35138)
    local l1_w = load[1] - host.decode_i16(inverter_phase[1])
    local l2_w = load[3] - host.decode_i16(inverter_phase[6])
    local l3_w = load[5] - host.decode_i16(inverter_phase[11])
    local l1_a = nil
    local l2_a = nil
    local l3_a = nil
    if l1_v > 0 then l1_a = l1_w / l1_v end
    if l2_v > 0 then l2_a = l2_w / l2_v end
    if l3_v > 0 then l3_a = l3_w / l3_v end

    host.emit("pv", {
        w = -pv_w,
        mppt1_v = pv[1] * 0.1,
        mppt1_a = pv[2] * 0.1,
    })

    local bat_soc = battery[5] / 100
    emit_battery(
        host.decode_i16(battery[3]),
        bat_soc,
        battery[1] * 0.1,
        nil,
        host.decode_i16(battery[6]) * 0.1
    )

    host.emit("meter", {
        w = -host.decode_i16(ac_total[3]),
        l1_w = l1_w,
        l2_w = l2_w,
        l3_w = l3_w,
        l1_v = l1_v,
        l2_v = l2_v,
        l3_v = l3_v,
        l1_a = l1_a,
        l2_a = l2_a,
        l3_a = l3_a,
        hz = frequency[1] * 0.01,
        import_wh = host.decode_u32_be(energy[1], energy[2]) * 100,
        export_wh = host.decode_u32_be(energy[4], energy[5]) * 100,
    })

    return 5000
end


function driver_init(config)
    config = config or {}
    profile = tostring(config.profile or "community-v1")
    if profile ~= "community-v1" and profile ~= "gw8kn-et-hk3000" then
        error("unsupported GoodWe register profile: " .. profile)
    end
    host.set_make("GoodWe")
end

function driver_poll()
    if profile == "gw8kn-et-hk3000" then
        return poll_gw8kn_et_hk3000()
    end
    return poll_community_v1()
end

function driver_command(action, power_w, command)
    return false
end

function driver_default_mode()
end

function driver_cleanup()
end
