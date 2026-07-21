-- ambibox.lua
-- Ambibox V2X Charger MQTT driver
-- Emits: V2X Charger, Battery, Meter telemetry
--
-- Subscribes to:
--   device/evCharger/#  - wildcard for all charger field updates
--
-- Message format: individual field updates where the topic path encodes the
-- field name (last segment) and the payload is the raw value.
-- Example: topic "device/evCharger/0/powerAc" with payload "3500"
--
-- Sign convention:
--   Battery W: positive = charging, negative = discharging
--   Meter W: positive = import, negative = export

PROTOCOL = "mqtt"

-- Flat state table holding the latest value for each field
local state = {}

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

-- Extract the field name from a topic string (last segment after final '/').
local function field_from_topic(topic)
    local field = nil
    for segment in string.gmatch(topic, "[^/]+") do
        field = segment
    end
    return field
end

-- Safe tonumber that returns 0 for nil/unparseable values.
local function num(v)
    return tonumber(v) or 0
end

-- Get a numeric value from state, defaulting to 0.
local function snum(key)
    return num(state[key])
end

----------------------------------------------------------------------------
-- Driver interface
----------------------------------------------------------------------------

function driver_init(config)
    host.set_make("Ambibox")

    host.mqtt_subscribe("device/evCharger/#")
end

function driver_poll()
    local messages = host.mqtt_messages()
    if not messages or #messages == 0 then return 1000 end

    local fresh_ac_power = false
    local fresh_dc_power = false

    -- Process incoming messages: update flat state table
    for _, msg in ipairs(messages) do
        local field = field_from_topic(msg.topic)
        if field then
            -- Try to parse as number; keep as string if not numeric
            local nval = tonumber(msg.payload)
            if nval then
                state[field] = nval
            else
                state[field] = msg.payload
            end
            if field == "powerAc" then fresh_ac_power = true end
            if field == "powerDc" then fresh_dc_power = true end
        end
    end

    -- Only emit if we have at least some data
    if not state.powerAc and not state.powerDc then
        return 1000
    end

    --------------------------------------------------------------------------
    -- V2X Charger telemetry
    --------------------------------------------------------------------------
    local charger = {}

    -- AC side
    charger.W = snum("powerAc")
    charger.A = snum("currentAc")
    charger.V = snum("voltageAc")
    charger.Hz = snum("frequency")

    -- Per-phase AC
    charger.L1_A = snum("currentAc1")
    charger.L2_A = snum("currentAc2")
    charger.L3_A = snum("currentAc3")
    charger.L1_V = snum("voltageAc1")
    charger.L2_V = snum("voltageAc2")
    charger.L3_V = snum("voltageAc3")

    -- Per-phase power computed from V * A
    charger.L1_W = snum("voltageAc1") * snum("currentAc1")
    charger.L2_W = snum("voltageAc2") * snum("currentAc2")
    charger.L3_W = snum("voltageAc3") * snum("currentAc3")

    -- DC side
    charger.dc_W = snum("powerDc")
    charger.dc_A = snum("currentDc")
    charger.dc_V = snum("voltageDc")

    -- Vehicle SoC: if reported as percentage (>1), convert to fraction
    if state.soc then
        local soc_val = num(state.soc)
        if soc_val > 1 then
            soc_val = soc_val / 100
        end
        charger.vehicle_soc_fract = soc_val
    end

    -- Energy requests
    charger.ev_max_energy_req_Wh = snum("maxEnergyRequest")
    charger.ev_min_energy_req_Wh = snum("minEnergyRequest")

    -- Session energy
    charger.session_charge_Wh = snum("energyAcImportSession")
    charger.session_discharge_Wh = snum("energyAcExportSession")

    -- Lifetime energy
    charger.total_charge_Wh = snum("energyAcImport")
    charger.total_discharge_Wh = snum("energyAcExport")

    -- Power limits
    charger.charge_power_min_W = snum("chargePowerMin")
    charger.charge_power_max_W = snum("chargePowerMax")
    charger.discharge_power_min_W = snum("dischargePowerMin")
    charger.discharge_power_max_W = snum("dischargePowerMax")

    -- Plug connected: boolean or 0/1 string → numeric 1 or 0
    if state.evConnected ~= nil then
        local ev = state.evConnected
        if ev == true or ev == "true" or ev == 1 or ev == "1" then
            charger.plug_connected = 1
        else
            charger.plug_connected = 0
        end
    end

    if fresh_ac_power or fresh_dc_power then
        host.emit("v2x_charger", charger)
    end

    --------------------------------------------------------------------------
    -- Battery telemetry (from DC side of charger)
    --------------------------------------------------------------------------
    local battery = {}
    battery.W = snum("powerDc")
    battery.V = snum("voltageDc")
    battery.A = snum("currentDc")

    if state.soc then
        local soc_val = num(state.soc)
        if soc_val > 1 then
            soc_val = soc_val / 100
        end
        battery.SoC_nom_fract = soc_val
    end

    if fresh_dc_power then
        host.emit("battery", battery)
    end

    --------------------------------------------------------------------------
    -- Meter telemetry (from AC side of charger)
    --------------------------------------------------------------------------
    local meter = {}
    meter.W = snum("powerAc")
    meter.Hz = snum("frequency")

    -- Per-phase voltage
    meter.L1_V = snum("voltageAc1")
    meter.L2_V = snum("voltageAc2")
    meter.L3_V = snum("voltageAc3")

    -- Per-phase current
    meter.L1_A = snum("currentAc1")
    meter.L2_A = snum("currentAc2")
    meter.L3_A = snum("currentAc3")

    -- Per-phase power
    meter.L1_W = snum("voltageAc1") * snum("currentAc1")
    meter.L2_W = snum("voltageAc2") * snum("currentAc2")
    meter.L3_W = snum("voltageAc3") * snum("currentAc3")

    -- Energy totals
    meter.total_import_Wh = snum("energyAcImport")
    meter.total_export_Wh = snum("energyAcExport")

    if fresh_ac_power then
        host.emit("meter", meter)
    end

    return 1000
end

-- Control command handler for Ambibox V2X charger
function driver_command(action, power_w, cmd)
    if action == "init" then
        return host.mqtt_publish("device/evCharger/0/wakeUp", "true")
    elseif action == "battery" then
        return host.mqtt_publish("device/ess/0/targetPower", tostring(power_w))
    elseif action == "curtail" then
        return host.mqtt_publish("device/ess/0/limitChargePower", tostring(math.abs(power_w)))
    elseif action == "curtail_disable" then
        local max = state.chargePowerMax or 22000
        return host.mqtt_publish("device/ess/0/limitChargePower", tostring(max))
    elseif action == "deinit" then
        return host.mqtt_publish("device/ess/0/targetPower", "0")
    end
    return false
end

function driver_default_mode()
    host.mqtt_publish("device/ess/0/targetPower", "0")
end

function driver_cleanup()
    state = {}
end
