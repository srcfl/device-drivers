-- Hoymiles via OpenDTU MQTT Driver (community, untested)
-- Emits: PV, Meter
-- MQTT protocol
--
-- Subscribes to: solar/#
-- Topics:
--   solar/+/status/AC/Power       (W)
--   solar/+/status/AC/Voltage     (V)
--   solar/+/status/AC/Current     (A)
--   solar/+/status/AC/Frequency   (Hz)
--   solar/+/status/DC/0/Voltage   (V, MPPT 1)
--   solar/+/status/DC/0/Current   (A, MPPT 1)
--   solar/+/status/INV/YieldTotal (kWh)
--
-- Sign convention:
--   PV W: negative (generation), following Sourceful convention
--   Meter W: positive = import, negative = export

PROTOCOL = "mqtt"

-- Cached state from MQTT messages
local ac_power = 0
local ac_voltage = 0
local ac_current = 0
local ac_frequency = 0
local dc0_voltage = 0
local dc0_current = 0
local yield_total_kwh = 0
local has_data = false

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

-- Safe tonumber that returns 0 for nil/unparseable values
local function num(v)
    return tonumber(v) or 0
end

-- Match a topic against a pattern, extracting the inverter ID.
-- Returns true and the inverter ID on match, false otherwise.
-- Pattern format uses * for the wildcard segment.
local function topic_ends_with(topic, suffix)
    -- Check if topic ends with the given suffix after "solar/<id>/"
    local prefix = "solar/"
    if string.sub(topic, 1, #prefix) ~= prefix then
        return false
    end
    local rest = string.sub(topic, #prefix + 1)
    -- Find the first / to skip the inverter ID
    local slash_pos = string.find(rest, "/")
    if not slash_pos then return false end
    local after_id = string.sub(rest, slash_pos)
    return after_id == suffix
end

----------------------------------------------------------------------------
-- Driver interface
----------------------------------------------------------------------------

function driver_init(config)
    host.set_make("Hoymiles")

    host.mqtt_subscribe("solar/#")
end

function driver_poll()
    local messages = host.mqtt_messages()
    if not messages or #messages == 0 then return 2000 end

    local fresh_power = false

    -- Process incoming messages and cache values
    for _, msg in ipairs(messages) do
        local topic = msg.topic
        local val = num(msg.payload)

        if topic_ends_with(topic, "/status/AC/Power") then
            ac_power = val
            has_data = true
            fresh_power = true
        elseif topic_ends_with(topic, "/status/AC/Voltage") then
            ac_voltage = val
        elseif topic_ends_with(topic, "/status/AC/Current") then
            ac_current = val
        elseif topic_ends_with(topic, "/status/AC/Frequency") then
            ac_frequency = val
        elseif topic_ends_with(topic, "/status/DC/0/Voltage") then
            dc0_voltage = val
        elseif topic_ends_with(topic, "/status/DC/0/Current") then
            dc0_current = val
        elseif topic_ends_with(topic, "/status/INV/YieldTotal") then
            yield_total_kwh = val
        end
    end

    -- Only emit if we have received at least one power reading
    if not has_data or not fresh_power then return 2000 end

    -- Emit PV telemetry
    -- Negate power: PV generation is negative by convention
    host.emit("pv", {
        w           = -ac_power,
        mppt1_v     = dc0_voltage,
        mppt1_a     = dc0_current,
        mppt2_v     = 0,
        mppt2_a     = 0,
        lifetime_wh = yield_total_kwh * 1000,
    })

    -- Emit Meter telemetry from AC side
    host.emit("meter", {
        w           = ac_power,
        l1_v        = ac_voltage,
        l1_a        = ac_current,
        hz          = ac_frequency,
        import_wh   = yield_total_kwh * 1000,
    })

    return 2000
end

function driver_cleanup()
    ac_power = 0
    ac_voltage = 0
    ac_current = 0
    ac_frequency = 0
    dc0_voltage = 0
    dc0_current = 0
    yield_total_kwh = 0
    has_data = false
end
