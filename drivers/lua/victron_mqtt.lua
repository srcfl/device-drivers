-- Victron Energy Venus OS MQTT Driver (community, untested)
-- Emits: PV, Battery, Meter
-- Subscribes to N/+/system/0/... topics on the Venus OS MQTT broker
-- Values come as JSON: {"value": 123.4}
--
-- Sign convention:
--   PV W: negative (generation)
--   Battery W: positive = charging, negative = discharging
--   Meter W: positive = import, negative = export

PROTOCOL = "mqtt"

-- Cached state from topics
local grid_l1_w = 0
local grid_l2_w = 0
local grid_l3_w = 0
local pv_ac_l1_w = 0
local pv_ac_l2_w = 0
local pv_ac_l3_w = 0
local pv_dc_w = 0
local bat_w = 0
local bat_soc = 0
local bat_v = 0
local bat_a = 0
local bat_temp = 0

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

-- Extract value from Victron MQTT JSON payload: {"value": 123.4}
local function parse_value(payload)
    local ok, data = pcall(host.json_decode, payload)
    if not ok or not data then return nil end
    if data.value ~= nil then
        return tonumber(data.value)
    end
    return nil
end

-- Check if a topic ends with a given suffix
local function topic_ends_with(topic, suffix)
    local suffix_len = string.len(suffix)
    local topic_len = string.len(topic)
    if topic_len < suffix_len then return false end
    return string.sub(topic, topic_len - suffix_len + 1) == suffix
end

----------------------------------------------------------------------------
-- Driver interface
----------------------------------------------------------------------------

function driver_init(config)
    host.set_make("Victron")

    -- Grid power per phase
    host.mqtt_subscribe("N/+/system/0/Ac/Grid/L1/Power")
    host.mqtt_subscribe("N/+/system/0/Ac/Grid/L2/Power")
    host.mqtt_subscribe("N/+/system/0/Ac/Grid/L3/Power")

    -- PV on AC output per phase
    host.mqtt_subscribe("N/+/system/0/Ac/PvOnOutput/L1/Power")
    host.mqtt_subscribe("N/+/system/0/Ac/PvOnOutput/L2/Power")
    host.mqtt_subscribe("N/+/system/0/Ac/PvOnOutput/L3/Power")

    -- DC PV power
    host.mqtt_subscribe("N/+/system/0/Dc/Pv/Power")

    -- Battery
    host.mqtt_subscribe("N/+/system/0/Dc/Battery/Power")
    host.mqtt_subscribe("N/+/system/0/Dc/Battery/Soc")
    host.mqtt_subscribe("N/+/system/0/Dc/Battery/Voltage")
    host.mqtt_subscribe("N/+/system/0/Dc/Battery/Current")
    host.mqtt_subscribe("N/+/system/0/Dc/Battery/Temperature")
end

function driver_poll()
    local messages = host.mqtt_messages()
    if not messages then return 1000 end

    -- Process incoming messages and cache values
    for _, msg in ipairs(messages) do
        local val = parse_value(msg.payload)
        if val then
            local topic = msg.topic

            -- Grid power
            if topic_ends_with(topic, "Ac/Grid/L1/Power") then
                grid_l1_w = val
            elseif topic_ends_with(topic, "Ac/Grid/L2/Power") then
                grid_l2_w = val
            elseif topic_ends_with(topic, "Ac/Grid/L3/Power") then
                grid_l3_w = val

            -- PV AC power
            elseif topic_ends_with(topic, "Ac/PvOnOutput/L1/Power") then
                pv_ac_l1_w = val
            elseif topic_ends_with(topic, "Ac/PvOnOutput/L2/Power") then
                pv_ac_l2_w = val
            elseif topic_ends_with(topic, "Ac/PvOnOutput/L3/Power") then
                pv_ac_l3_w = val

            -- PV DC power
            elseif topic_ends_with(topic, "Dc/Pv/Power") then
                pv_dc_w = val

            -- Battery
            elseif topic_ends_with(topic, "Dc/Battery/Power") then
                bat_w = val
            elseif topic_ends_with(topic, "Dc/Battery/Soc") then
                bat_soc = val
            elseif topic_ends_with(topic, "Dc/Battery/Voltage") then
                bat_v = val
            elseif topic_ends_with(topic, "Dc/Battery/Current") then
                bat_a = val
            elseif topic_ends_with(topic, "Dc/Battery/Temperature") then
                bat_temp = val
            end
        end
    end

    -- Emit PV telemetry
    -- Total PV = AC PV (all phases) + DC PV, negate for generation convention
    local pv_ac_total = pv_ac_l1_w + pv_ac_l2_w + pv_ac_l3_w
    local pv_total = pv_ac_total + pv_dc_w

    host.emit("pv", {
        w = -pv_total,
    })

    -- Emit Battery telemetry
    -- Victron: positive power = discharging, negate for convention (positive = charging)
    local bat_soc_fract = bat_soc / 100  -- percent to fraction

    host.emit("battery", {
        w      = -bat_w,
        v      = bat_v,
        a      = bat_a,
        soc    = bat_soc_fract,
        temp_c = bat_temp,
    })

    -- Emit Meter telemetry
    -- Victron grid: positive = import (matches convention)
    local grid_total = grid_l1_w + grid_l2_w + grid_l3_w

    host.emit("meter", {
        w    = grid_total,
        l1_w = grid_l1_w,
        l2_w = grid_l2_w,
        l3_w = grid_l3_w,
    })

    return 1000
end

function driver_cleanup()
    grid_l1_w = 0
    grid_l2_w = 0
    grid_l3_w = 0
    pv_ac_l1_w = 0
    pv_ac_l2_w = 0
    pv_ac_l3_w = 0
    pv_dc_w = 0
    bat_w = 0
    bat_soc = 0
    bat_v = 0
    bat_a = 0
    bat_temp = 0
end
