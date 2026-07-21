-- ferroamp_dc2_v2x.lua
-- Ferroamp DC2 V2X 20 kW Charger MQTT driver
-- Emits: V2X Charger telemetry
--
-- The DC2 V2X is a bidirectional DC charger (CCS2) connected to a Ferroamp
-- EnergyHub's 760V DC nanogrid. It uses a Vector vSECC controller with
-- Ferroamp-customized MQTT topics under the "dc2/" prefix.
--
-- MQTT broker: runs on the DC2 charger itself, port 1883, requires auth.
--
-- Subscribes to:
--   dc2/connector/1/#  - charger data (vSECC standard topics, dc2 prefix)
--   dc2/ui/#           - Ferroamp UI/control state
--
-- Control:
--   dc2/ui/control     - power setpoint in kW (positive=charge, negative=discharge)
--   Manual mode must be active on the charger for external MQTT control.
--
-- Sign convention:
--   V2X W: positive = charging (grid→car), negative = discharging (car→grid)

PROTOCOL = "mqtt"

-- Cached state from individual topic updates
local state = {}

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

-- Safe tonumber, returns 0 for nil/unparseable
local function num(v)
    return tonumber(v) or 0
end

-- Get numeric value from state
local function snum(key)
    return num(state[key])
end

-- Map a topic to a flat state key.
-- dc2/connector/1/ev/soc → "ev/soc"
-- dc2/connector/1/pe/measured_voltage → "pe/measured_voltage"
-- dc2/ui/control → "ui/control"
local function topic_to_key(topic)
    -- Strip "dc2/connector/1/" prefix → remainder is the key
    local key = string.match(topic, "^dc2/connector/%d+/(.*)")
    if key then return key end
    -- Strip "dc2/" prefix for non-connector topics
    key = string.match(topic, "^dc2/(.*)")
    return key
end

----------------------------------------------------------------------------
-- Driver interface
----------------------------------------------------------------------------

function driver_init(config)
    host.set_make("Ferroamp")

    host.mqtt_subscribe("dc2/connector/1/#")
    host.mqtt_subscribe("dc2/ui/#")
end

function driver_poll()
    local messages = host.mqtt_messages()
    if not messages or #messages == 0 then return 1000 end

    local fresh_power = false

    for _, msg in ipairs(messages) do
        local key = topic_to_key(msg.topic)
        if key and msg.payload ~= "" then
            local nval = tonumber(msg.payload)
            if nval then
                state[key] = nval
            else
                state[key] = msg.payload
            end
            if key == "pe/measured_voltage" or key == "pe/measured_current" then
                fresh_power = true
            end
        end
    end

    -- Only emit if we have some charger data
    if not fresh_power or (not state["pe/measured_voltage"] and not state["pe/measured_current"]) then
        return 1000
    end

    --------------------------------------------------------------------------
    -- V2X Charger telemetry
    --------------------------------------------------------------------------
    local charger = {}

    -- DC measurements from power electronics
    local dc_v = snum("pe/measured_voltage")
    local dc_a = snum("pe/measured_current")
    charger.dc_V = dc_v
    charger.dc_A = dc_a
    charger.dc_W = dc_v * dc_a

    -- Total power (DC charger, no AC side)
    charger.W = charger.dc_W

    -- Vehicle SoC: reported as integer percentage, convert to fraction
    if state["ev/soc"] then
        local soc_pct = num(state["ev/soc"])
        charger.vehicle_soc_fract = soc_pct / 100
    end

    -- Session transferred energy (kWh from vSECC, convert to Wh)
    if state["em/transferred_energy"] then
        local kwh = num(state["em/transferred_energy"])
        -- transferred_energy is cumulative for session; positive = delivered to EV
        if charger.dc_W >= 0 then
            charger.session_charge_Wh = kwh * 1000
        else
            charger.session_discharge_Wh = kwh * 1000
        end
    end

    -- EV limits from ISO 15118 negotiation
    charger.charge_power_max_W = snum("ev/limits/max_power")
    charger.charge_power_min_W = snum("ev/limits/min_power")
    charger.discharge_power_max_W = snum("ev/limits/max_discharge_power")

    -- Rated power: 20 kW charge/discharge
    charger.rated_power_W = 20000

    -- Plug connected: inferred from CP state or ID state
    if state["ev/id_state"] then
        local id = state["ev/id_state"]
        if id == "mated" or id == "mated_ev_aux" or id == "mated_evse_aux" then
            charger.plug_connected = 1
        else
            charger.plug_connected = 0
        end
    end

    host.emit("v2x_charger", charger)

    return 1000
end

-- Control: power setpoint via Ferroamp custom topic dc2/ui/control
-- The charger must be in Manual mode for external MQTT control to work.
-- Power is in kW: positive = charge, negative = discharge
function driver_command(action, power_w, cmd)
    if action == "init" then
        return true
    elseif action == "battery" then
        -- Convert W to kW for DC2 control topic
        local power_kw = power_w / 1000
        return host.mqtt_publish("dc2/ui/control", string.format("%.2f", power_kw))
    elseif action == "curtail" then
        -- Limit charge power
        local power_kw = math.abs(power_w) / 1000
        return host.mqtt_publish("dc2/ui/control", string.format("%.2f", power_kw))
    elseif action == "curtail_disable" then
        -- Set to max charge power (20 kW)
        return host.mqtt_publish("dc2/ui/control", "20.00")
    elseif action == "deinit" then
        -- Set to 0 to stop active control
        return host.mqtt_publish("dc2/ui/control", "0.00")
    end
    return false
end

function driver_default_mode()
    host.mqtt_publish("dc2/ui/control", "0.00")
end

function driver_cleanup()
    state = {}
end
