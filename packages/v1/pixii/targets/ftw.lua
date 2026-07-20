-- Pixii PowerShaper FTW target
-- Emits: Battery, Meter
-- Protocol: Modbus TCP, SunSpec holding registers
--
-- The telemetry and control paths come from the FTW community driver. The
-- calibration fault handling was contributed by Tommy Lindgren in srcfl/ftw#600.

DRIVER = {
    host_api_min = 2,
    host_api_max = 2,
    id = "pixii",
    name = "Pixii PowerShaper",
    manufacturer = "Pixii",
    version = "1.2.1",
    protocols = {"modbus"},
    capabilities = {"battery", "meter"},
    description = "Pixii PowerShaper commercial battery storage via Modbus TCP.",
    authors = {"Tommy Lindgren", "Sourceful contributors"},
    verification_status = "experimental",
    verification_notes = "FTW v2 control stays disabled until runtime isolation and physical HIL pass.",
    connection_defaults = {
        port = 502,
        unit_id = 1,
    },
}

PROTOCOL = "modbus"

local REG_HEARTBEAT = 39903
local REG_SETPOINT_HI = 39905
local REG_BATTERY_CHARGE_STATUS = 40137

local heartbeat = 0
local serial_read = false
local last_calibrating = nil

local function scale(value, factor)
    if factor == 0 then return value end
    return value * (10 ^ factor)
end

local function read_scale_factor(address)
    local ok, registers = pcall(host.modbus_read, address, 1, "holding")
    if ok and registers and registers[1] ~= nil then
        return host.decode_i16(registers[1])
    end
    return 0
end

local function decode_ascii(registers, count)
    local value = ""
    for i = 1, count do
        local hi = math.floor(registers[i] / 256)
        local lo = registers[i] % 256
        if hi == 0 and lo == 0 then break end
        if hi > 32 and hi < 127 then value = value .. string.char(hi) end
        if lo > 32 and lo < 127 then value = value .. string.char(lo) end
    end
    return value
end

local function read_charge_status()
    local ok, registers = pcall(host.modbus_read, REG_BATTERY_CHARGE_STATUS, 1, "holding")
    if not ok or not registers or registers[1] == nil then
        return nil
    end
    return registers[1]
end

local function update_calibration_fault(charge_status)
    if charge_status == nil then
        return
    end

    local calibrating = charge_status == 7
    host.set_device_fault(
        calibrating,
        calibrating and "Pixii battery calibrating/testing (SunSpec ChaSt=testing)" or ""
    )

    if calibrating ~= last_calibrating then
        if calibrating then
            host.log("warn", "Pixii: charge status is TESTING; excluding from dispatch until calibration finishes")
        elseif last_calibrating == true then
            host.log("info", "Pixii: calibration finished; dispatch may resume")
        end
        last_calibrating = calibrating
    end
end

function driver_init(config)
    host.set_make("Pixii")
end

function driver_poll()
    if not serial_read then
        local ok, registers = pcall(host.modbus_read, 40052, 16, "holding")
        if ok and registers then
            local serial = decode_ascii(registers, 16)
            if string.len(serial) > 0 then
                host.set_sn(serial)
                serial_read = true
            end
        end
    end

    local ac_w_factor = read_scale_factor(40084)
    local hz_factor = read_scale_factor(40086)
    local temp_factor = read_scale_factor(40106)
    local soc_factor = read_scale_factor(40177)
    local battery_v_factor = read_scale_factor(40180)
    local battery_a_factor = read_scale_factor(40182)
    local battery_w_factor = read_scale_factor(40184)
    local meter_a_factor = read_scale_factor(40240)
    local meter_v_factor = read_scale_factor(40249)
    local meter_hz_factor = read_scale_factor(40251)
    local meter_w_factor = read_scale_factor(40256)
    local meter_energy_factor = read_scale_factor(40288)

    local ok_ac_w, ac_w_registers = pcall(host.modbus_read, 40083, 1, "holding")
    local ac_w = 0
    if ok_ac_w and ac_w_registers then
        ac_w = scale(host.decode_i16(ac_w_registers[1]), ac_w_factor)
    end

    local ok_hz, hz_registers = pcall(host.modbus_read, 40085, 1, "holding")
    local inverter_hz = 0
    if ok_hz and hz_registers then
        inverter_hz = scale(hz_registers[1], hz_factor)
    end

    local ok_temp, temp_registers = pcall(host.modbus_read, 40102, 1, "holding")
    local temp_c = 0
    if ok_temp and temp_registers then
        temp_c = scale(host.decode_i16(temp_registers[1]), temp_factor)
    end

    local ok_soc, soc_registers = pcall(host.modbus_read, 40132, 1, "holding")
    local battery_soc = nil
    if ok_soc and soc_registers then
        local candidate = scale(soc_registers[1], soc_factor) / 100
        if candidate >= 0 and candidate <= 1 then
            battery_soc = candidate
        end
    end

    local ok_battery_v, battery_v_registers = pcall(host.modbus_read, 40155, 1, "holding")
    local battery_v = 0
    if ok_battery_v and battery_v_registers then
        battery_v = scale(host.decode_i16(battery_v_registers[1]), battery_v_factor)
    end

    local ok_battery_a, battery_a_registers = pcall(host.modbus_read, 40165, 1, "holding")
    local battery_a = 0
    if ok_battery_a and battery_a_registers then
        battery_a = scale(host.decode_i16(battery_a_registers[1]), battery_a_factor)
    end

    local ok_battery_w, battery_w_registers = pcall(host.modbus_read, 40168, 1, "holding")
    local battery_w = 0
    if ok_battery_w and battery_w_registers then
        battery_w = scale(host.decode_i16(battery_w_registers[1]), battery_w_factor)
    end

    local ok_energy, energy_registers = pcall(host.modbus_read, 39958, 4, "holding")
    local charge_wh, discharge_wh = 0, 0
    if ok_energy and energy_registers then
        charge_wh = host.decode_i32_be(energy_registers[1], energy_registers[2]) * 1000
        discharge_wh = host.decode_i32_be(energy_registers[3], energy_registers[4]) * 1000
    end

    local charge_status = read_charge_status()
    update_calibration_fault(charge_status)

    local battery = {
        w = battery_w,
        v = battery_v,
        a = battery_a,
        temp_c = temp_c,
        charge_wh = charge_wh,
        discharge_wh = discharge_wh,
        charge_status = charge_status,
    }
    if battery_soc ~= nil then battery.soc = battery_soc end
    host.emit("battery", battery)

    local ok_meter_a, meter_a_registers = pcall(host.modbus_read, 40237, 3, "holding")
    local l1_a, l2_a, l3_a = 0, 0, 0
    if ok_meter_a and meter_a_registers then
        l1_a = scale(host.decode_i16(meter_a_registers[1]), meter_a_factor)
        l2_a = scale(host.decode_i16(meter_a_registers[2]), meter_a_factor)
        l3_a = scale(host.decode_i16(meter_a_registers[3]), meter_a_factor)
    end

    local ok_meter_v, meter_v_registers = pcall(host.modbus_read, 40242, 3, "holding")
    local l1_v, l2_v, l3_v = 0, 0, 0
    if ok_meter_v and meter_v_registers then
        l1_v = scale(host.decode_i16(meter_v_registers[1]), meter_v_factor)
        l2_v = scale(host.decode_i16(meter_v_registers[2]), meter_v_factor)
        l3_v = scale(host.decode_i16(meter_v_registers[3]), meter_v_factor)
    end

    local ok_meter_hz, meter_hz_registers = pcall(host.modbus_read, 40250, 1, "holding")
    local meter_hz = 0
    if ok_meter_hz and meter_hz_registers then
        meter_hz = scale(meter_hz_registers[1], meter_hz_factor)
    end

    local ok_meter_w, meter_w_registers = pcall(host.modbus_read, 40252, 1, "holding")
    local meter_w = 0
    if ok_meter_w and meter_w_registers then
        meter_w = scale(host.decode_i16(meter_w_registers[1]), meter_w_factor)
    end

    local ok_phase_w, phase_w_registers = pcall(host.modbus_read, 40253, 3, "holding")
    local l1_w, l2_w, l3_w = 0, 0, 0
    if ok_phase_w and phase_w_registers then
        l1_w = scale(host.decode_i16(phase_w_registers[1]), meter_w_factor)
        l2_w = scale(host.decode_i16(phase_w_registers[2]), meter_w_factor)
        l3_w = scale(host.decode_i16(phase_w_registers[3]), meter_w_factor)
    end

    local ok_export, export_registers = pcall(host.modbus_read, 40272, 4, "holding")
    local export_wh = 0
    if ok_export and export_registers then
        export_wh = scale(host.decode_u32_be(export_registers[1], export_registers[2]), meter_energy_factor)
    end

    local ok_import, import_registers = pcall(host.modbus_read, 40280, 4, "holding")
    local import_wh = 0
    if ok_import and import_registers then
        import_wh = scale(host.decode_u32_be(import_registers[1], import_registers[2]), meter_energy_factor)
    end

    host.emit("meter", {
        w = meter_w,
        l1_w = l1_w,
        l2_w = l2_w,
        l3_w = l3_w,
        l1_v = l1_v,
        l2_v = l2_v,
        l3_v = l3_v,
        l1_a = l1_a,
        l2_a = l2_a,
        l3_a = l3_a,
        hz = meter_hz,
        import_wh = import_wh,
        export_wh = export_wh,
    })

    return 5000
end

local function encode_i32_be(value)
    local rounded
    if value < 0 then
        rounded = math.ceil(value - 0.5)
    else
        rounded = math.floor(value + 0.5)
    end
    if rounded < 0 then rounded = rounded + 0x100000000 end
    return math.floor(rounded / 0x10000) % 0x10000, rounded % 0x10000
end

local function read_i32_be(address)
    local registers, err = host.modbus_read(address, 2, "holding")
    if err then return nil, tostring(err) end
    if type(registers) ~= "table" or type(registers[1]) ~= "number" or type(registers[2]) ~= "number" then
        return nil, "missing setpoint registers"
    end
    return host.decode_i32_be(registers[1], registers[2]), nil
end

local function write_setpoint(power_w)
    local pixii_w = -power_w
    local hi, lo = encode_i32_be(pixii_w)
    local write_error = host.modbus_write_multi(REG_SETPOINT_HI, {hi, lo})
    if write_error then
        return false, "setpoint write failed: " .. tostring(write_error)
    end

    heartbeat = (heartbeat + 1) % 100
    local heartbeat_error = host.modbus_write(REG_HEARTBEAT, heartbeat)
    if heartbeat_error then
        return false, "heartbeat write failed: " .. tostring(heartbeat_error)
    end

    local actual, read_error = read_i32_be(REG_SETPOINT_HI)
    if read_error then return false, "setpoint readback failed: " .. read_error end
    if actual ~= pixii_w then return false, "setpoint readback mismatch" end
    return true, nil
end

local function failed(code, message, state)
    return {
        status = "failed",
        code = code,
        message = message,
        device_state = state or "unknown",
    }
end

function driver_command_v2(command)
    if command.runtime_action ~= "battery" then
        return {status = "rejected", code = "unknown_action", device_state = "unchanged"}
    end

    local inputs = command.inputs or {}
    local power_w = inputs.power_w
    if type(power_w) ~= "number" or power_w ~= power_w or
       power_w < -2147483647 or power_w > 2147483647 then
        return {status = "rejected", code = "invalid_power", device_state = "unchanged"}
    end
    if last_calibrating == true then
        return {status = "rejected", code = "device_calibrating", device_state = "unchanged"}
    end

    local ok, err = write_setpoint(power_w)
    if not ok then return failed("setpoint_failed", err) end
    return {
        status = "applied",
        code = power_w == 0 and "default_restored" or "ok",
        device_state = power_w == 0 and "default" or "controlled",
        evidence = {"write_ack", "readback", "heartbeat_ack"},
        applied = {power_w = power_w},
    }
end

function driver_default_mode_v2(context)
    local ok, err = write_setpoint(0)
    if not ok then return failed("default_write_failed", err) end
    return {
        status = "defaulted",
        code = "default_restored",
        device_state = "default",
        evidence = {"write_ack", "readback", "heartbeat_ack"},
    }
end

function driver_cleanup()
end
