-- Victron Energy Venus OS MQTT Driver (community, untested)
-- Emits: PV, Battery, Meter
-- Subscribes to N/+/system/0/... topics on the Venus OS MQTT broker, and to
-- the BMS's own limits on N/+/battery/+/...
-- Values come as JSON: {"value": 123.4}
-- Sends the Venus keep-alive on R/<portal ID>/keepalive, see "Keep-alive".
--
-- Topic format and payload rules: victronenergy/dbus-flashmq README.
--   N/<portal ID>/<service type>/<device instance>/<D-Bus path>
--   {"value": null} means the D-Bus value is invalid; an empty payload means
--   the device left the D-Bus. Either way the value is gone, so the driver
--   forgets it rather than keep the last number.
-- D-Bus paths: victronenergy/venus wiki, "dbus".
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
-- Battery values stay nil until a message carries one. A number the GX never
-- sent must not reach FTW: 0 % SoC reads as an empty pack, 0 °C as a cold one.
local bat_soc = nil
local bat_v = nil
local bat_a = nil
local bat_temp = nil
-- When each value above last arrived: the poll's stamp (see "Keep-alive").
local bat_soc_at, bat_v_at, bat_a_at, bat_temp_at = nil, nil, nil, nil

-- What the battery's BMS says it allows now, per battery service.
--
-- A BMS on the GX (CAN-bus or Lynx) publishes its charge and discharge
-- current limits, CCL and DCL, on /Info/MaxChargeCurrent and
-- /Info/MaxDischargeCurrent in amps. Victron's DVCC page says the BMS sends
-- them as "the maximum charge current requested by the battery", that some
-- makes send dynamic values and others a fixed one. Either way it is the
-- BMS's own word, read as it changes, not a rating this driver knows; a DCL
-- of 0 means the BMS allows no discharge now. Victron does not say how often
-- a given BMS updates them.
--
-- Several battery services can exist at once: a shunt beside a BMS, or two
-- Lynx Smart BMS plus their combined service. The GX picks one for DVCC and
-- names its device instance in system/0/ActiveBmsInstance
-- (victronenergy/dbus-systemcalc-py, delegates/batteryservice.py). The
-- driver uses that one; until it
-- is known, it uses the only service that sent a limit, and none when more
-- than one did.
--
-- A value that seldom changes, such as a fixed CCL or ActiveBmsInstance,
-- arrives only in a full republish (see "Keep-alive" below). Until then the
-- limit is left out.
--
-- How old a value may be. Venus sends a value when it changes and never
-- repeats it on its own, so a quiet topic is not a stale one: a fixed CCL or
-- a full pack's 100 % SoC can stand for hours. What goes stale is a value
-- whose null or empty payload the driver never heard, because the broker
-- link was down or the device left without one. So:
--   * Watts need the BMS's own voltage from the last BMS_MAX_AGE_MS. Its
--     voltage moves in 0.01 V steps and changes within seconds once current
--     flows, so a working BMS refreshes it well inside that time. A battery
--     at rest can hold its voltage longer; then the watts are left out.
--   * The BMS's limits and cell temperatures count only while that BMS has
--     sent something in the last BMS_MAX_AGE_MS (in practice its voltage).
--     A fixed CCL stays valid while its BMS keeps talking and goes with it.
--   * When nothing at all has arrived for LINK_SILENT_MS, the driver forgets
--     every battery value: Venus stops publishing 60 s after the last
--     keep-alive (dbus-flashmq README), and a null sent while the driver was
--     not listening is lost.
--   * The system's SoC, voltage, current and temperature count until a
--     full republish leaves them out. A full republish resends every value
--     the GX has and ends with N/<portal ID>/full_publish_completed, so a
--     value that arrived well before that last message was not in it: the
--     GX no longer has it. Until a full republish has completed, for
--     example when the host refuses to send the keep-alive, they stay until
--     a null, an empty payload or a silent link clears them.
local BMS_MAX_AGE_MS = 60000
local LINK_SILENT_MS = 60000
local last_message_ms = nil   -- host.millis() of the latest message batch

-- Keep-alive (victronenergy/dbus-flashmq README, "Keep-alive").
--
-- Venus OS publishes value changes only while some client has sent a
-- read request to R/<portal ID>/keepalive in the last 60 s. The README
-- sends one every 30 s. An empty payload asks for a full republish of every
-- topic, ending with N/<portal ID>/full_publish_completed; the option
-- {"keepalive-options": ["suppress-republish"]} keeps the GX awake without
-- one. Victron suggests the second on the timer and the first when the
-- program needs fresh values. This driver asks for a full republish when it
-- first learns the portal ID, when the GX speaks again after a silent link,
-- and every REPUBLISH_MS,
-- so values that seldom change are seen again and an old one can be told
-- from a current one.
--
-- The portal ID is the second part of every N/ topic. dbus-flashmq
-- publishes N/<portal ID>/system/0/Serial retained (Item::should_be_retained
-- in its source), so a client that subscribes to it learns the ID at once,
-- before any keep-alive. When that topic names another portal ID, the GX on
-- the broker has changed: the driver follows it, forgets what the old one
-- said and asks the new one for every value.
--
-- Which values a full republish resent. The host hands over the messages
-- that arrived since the last poll, so a republish usually lands in one
-- poll, and at most straddles one boundary. Each poll gets a stamp, its
-- clock and its number, and every value keeps the stamp of the poll that
-- brought it. A value was resent if it arrived within REPUBLISH_POLLS polls
-- before the completion, or within REPUBLISH_SLACK_MS of it. Counting polls
-- holds on a host that polls every 5 s or slower; the time bound holds on
-- one that polls faster than this driver asks.
--
-- host.mqtt_publish returns nothing on FTW when it sends and an error text
-- when it refuses, for example for a driver FTW runs read-only. Then the GX
-- publishes only while another client keeps it awake, as before 1.2.0, and
-- the driver tries again on the next keep-alive.
local KEEPALIVE_MS = 30000
local REPUBLISH_MS = 120000
local REPUBLISH_POLLS = 2
local REPUBLISH_SLACK_MS = 5000
local SUPPRESS_REPUBLISH = '{"keepalive-options": ["suppress-republish"]}'
local portal_id = nil
local last_keepalive_ms = nil     -- last keep-alive the driver tried
local last_republish_ms = nil     -- last full republish the host sent
local republish_due = true        -- ask for every value on the next one
local keepalive_refused = false   -- host refused the last keep-alive
local full_publish_at = nil       -- stamp of the latest full_publish_completed
local poll_seq = 0                -- number of the current poll
local BMS_TOPIC = "^N/[^/]+/battery/(%d+)/(.+)$"
local BMS_PATHS = {
    ["Info/MaxChargeCurrent"]      = "charge_a",
    ["Info/MaxDischargeCurrent"]   = "discharge_a",
    ["Dc/0/Voltage"]               = "v",
    ["System/MinCellTemperature"]  = "cell_min_c",
    ["System/MaxCellTemperature"]  = "cell_max_c",
}
local bms = {}            -- device instance (number) -> fields above, plus
                          -- seen_ms (last valid value) and v_ms (last voltage)
local active_bms = nil    -- system/0/ActiveBmsInstance, nil until known

-- Plausible ranges (docs/WRITING-A-DRIVER.md, "What a battery can do now").
local MIN_TEMP_C, MAX_TEMP_C = -40, 100
local MAX_LIMIT_W = 100000

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

-- Extract value from Victron MQTT JSON payload: {"value": 123.4}.
-- Returns nil for {"value": null}, an empty payload and anything else that
-- is not a number.
local function parse_value(payload)
    local ok, data = pcall(host.json_decode, payload)
    if not ok or type(data) ~= "table" then return nil end
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

local function in_range(v, lo, hi)
    if v == nil or v ~= v or v < lo or v > hi then return nil end
    return v
end

local function temperature(v)
    return in_range(v, MIN_TEMP_C, MAX_TEMP_C)
end

-- A current limit in amps, never negative.
local function limit_a(v)
    if v == nil or v ~= v or v < 0 or v == math.huge then return nil end
    return v
end

local function fresh(at_ms, now)
    return at_ms ~= nil and now - at_ms <= BMS_MAX_AGE_MS
end

-- Amps from the BMS times the voltage the same BMS service reported in the
-- last BMS_MAX_AGE_MS. Without that voltage there is no wattage.
local function limit_w(amps, b, now)
    amps = limit_a(amps)
    local volts = b.v
    if amps == nil or volts == nil or volts ~= volts or volts <= 0 then return nil end
    if not fresh(b.v_ms, now) then return nil end
    return in_range(amps * volts, 0, MAX_LIMIT_W)
end

-- The BMS whose limits count now, or nil. A BMS that has said nothing for
-- BMS_MAX_AGE_MS does not count.
local function selected_bms(now)
    if active_bms ~= nil then
        local b = bms[active_bms]
        if b and fresh(b.seen_ms, now) then return b end
        return nil
    end
    local only = nil
    for _, b in pairs(bms) do
        if fresh(b.seen_ms, now) and (b.charge_a ~= nil or b.discharge_a ~= nil) then
            if only then return nil end
            only = b
        end
    end
    return only
end

-- A system battery value, or nil once a full republish has left it out.
local function current(value, at)
    if value == nil or full_publish_at == nil then return value end
    if at == nil then return nil end
    if full_publish_at.seq - at.seq <= REPUBLISH_POLLS then return value end
    if full_publish_at.ms - at.ms <= REPUBLISH_SLACK_MS then return value end
    return nil
end

local function forget_battery_values()
    bat_soc = nil
    bat_v = nil
    bat_a = nil
    bat_temp = nil
    bat_soc_at, bat_v_at, bat_a_at, bat_temp_at = nil, nil, nil, nil
    bms = {}
    active_bms = nil
    full_publish_at = nil
end

-- FTW returns nothing when it sends and an error text when it refuses; a
-- host or mock that returns true has sent it too.
local function publish(topic, payload)
    local ok, result = pcall(host.mqtt_publish, topic, payload)
    if not ok then return false, tostring(result) end
    if result == nil or result == true then return true end
    return false, tostring(result)
end

local function keep_alive(now)
    if portal_id == nil then return end
    -- When the GX speaks after a silent link, ask at once; a refused one
    -- waits its turn.
    local due = last_keepalive_ms == nil or now - last_keepalive_ms >= KEEPALIVE_MS
        or (republish_due and not keepalive_refused)
    if not due then return end
    local full = republish_due or last_republish_ms == nil
        or now - last_republish_ms >= REPUBLISH_MS
    last_keepalive_ms = now
    local sent, err = publish("R/" .. portal_id .. "/keepalive",
                              full and "" or SUPPRESS_REPUBLISH)
    if sent then
        if full then
            last_republish_ms = now
            republish_due = false
        end
        if keepalive_refused then
            host.log("info", "Victron MQTT: the host sends the keep-alive again")
            keepalive_refused = false
        end
    elseif not keepalive_refused then
        host.log("warn", "Victron MQTT: the host refused the keep-alive (" ..
            tostring(err) .. "); the GX publishes only while another client " ..
            "keeps it awake")
        keepalive_refused = true
    end
end

----------------------------------------------------------------------------
-- Driver interface
----------------------------------------------------------------------------

function driver_init(config)
    host.set_make("Victron")

    -- The portal ID (retained, so it arrives before any keep-alive) and the
    -- end of a full republish
    host.mqtt_subscribe("N/+/system/0/Serial")
    host.mqtt_subscribe("N/+/full_publish_completed")

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

    -- The BMS's limits and cell temperatures, and which BMS the GX uses
    host.mqtt_subscribe("N/+/system/0/ActiveBmsInstance")
    host.mqtt_subscribe("N/+/battery/+/Info/MaxChargeCurrent")
    host.mqtt_subscribe("N/+/battery/+/Info/MaxDischargeCurrent")
    host.mqtt_subscribe("N/+/battery/+/Dc/0/Voltage")
    host.mqtt_subscribe("N/+/battery/+/System/MinCellTemperature")
    host.mqtt_subscribe("N/+/battery/+/System/MaxCellTemperature")
end

function driver_poll()
    local now = host.millis()
    local messages = host.mqtt_messages()
    poll_seq = poll_seq + 1
    local stamp = { ms = now, seq = poll_seq }

    -- A silent link: what was cached may have changed or gone unheard.
    if last_message_ms ~= nil and now - last_message_ms > LINK_SILENT_MS then
        forget_battery_values()
        last_message_ms = nil
    end

    if not messages or #messages == 0 then
        keep_alive(now)
        return 1000
    end
    -- The first word after a silent link: ask for every value again.
    if last_message_ms == nil then republish_due = true end
    last_message_ms = now

    local fresh_pv = false
    local fresh_battery = false
    local fresh_meter = false

    -- Process incoming messages and cache values. Venus OS publishes a value
    -- when it changes, so the latest message is the current value until a
    -- newer one, a null or an empty payload replaces it.
    for _, msg in ipairs(messages) do
        local topic = msg.topic
        local val = parse_value(msg.payload)
        local instance, path = string.match(topic, BMS_TOPIC)

        local serial_portal = string.match(topic, "^N/([^/]+)/system/0/Serial$")
        if serial_portal and serial_portal ~= portal_id then
            if portal_id ~= nil then
                host.log("info", "Victron MQTT: portal ID changed from " ..
                    portal_id .. " to " .. serial_portal)
                forget_battery_values()
            end
            portal_id = serial_portal
            republish_due = true
        elseif portal_id == nil then
            portal_id = string.match(topic, "^N/([^/]+)/")
        end

        if topic_ends_with(topic, "/full_publish_completed") then
            full_publish_at = stamp
        elseif instance then
            local field = BMS_PATHS[path]
            if field then
                instance = tonumber(instance)
                local b = bms[instance] or {}
                bms[instance] = b
                b[field] = val
                if val ~= nil then
                    b.seen_ms = now
                    if field == "v" then b.v_ms = now end
                end
            end
        elseif topic_ends_with(topic, "system/0/ActiveBmsInstance") then
            active_bms = val

        -- Battery values that ride along with battery power. A null or an
        -- empty payload clears them.
        elseif topic_ends_with(topic, "Dc/Battery/Soc") then
            bat_soc, bat_soc_at = val, stamp
        elseif topic_ends_with(topic, "Dc/Battery/Voltage") then
            bat_v, bat_v_at = val, stamp
        elseif topic_ends_with(topic, "Dc/Battery/Current") then
            bat_a, bat_a_at = val, stamp
        elseif topic_ends_with(topic, "Dc/Battery/Temperature") then
            -- The system's battery temperature: the battery monitor's or
            -- BMS's sensor, not an inverter heatsink.
            bat_temp, bat_temp_at = val, stamp

        elseif val then
            -- Grid power
            if topic_ends_with(topic, "Ac/Grid/L1/Power") then
                grid_l1_w = val
                fresh_meter = true
            elseif topic_ends_with(topic, "Ac/Grid/L2/Power") then
                grid_l2_w = val
                fresh_meter = true
            elseif topic_ends_with(topic, "Ac/Grid/L3/Power") then
                grid_l3_w = val
                fresh_meter = true

            -- PV AC power
            elseif topic_ends_with(topic, "Ac/PvOnOutput/L1/Power") then
                pv_ac_l1_w = val
                fresh_pv = true
            elseif topic_ends_with(topic, "Ac/PvOnOutput/L2/Power") then
                pv_ac_l2_w = val
                fresh_pv = true
            elseif topic_ends_with(topic, "Ac/PvOnOutput/L3/Power") then
                pv_ac_l3_w = val
                fresh_pv = true

            -- PV DC power
            elseif topic_ends_with(topic, "Dc/Pv/Power") then
                pv_dc_w = val
                fresh_pv = true

            -- Battery
            elseif topic_ends_with(topic, "Dc/Battery/Power") then
                bat_w = val
                fresh_battery = true
            end
        end
    end

    keep_alive(now)

    -- Emit PV telemetry
    -- Total PV = AC PV (all phases) + DC PV, negate for generation convention
    local pv_ac_total = pv_ac_l1_w + pv_ac_l2_w + pv_ac_l3_w
    local pv_total = pv_ac_total + pv_dc_w

    if fresh_pv then
        host.emit("pv", {
            W = -pv_total,
        })
    end

    -- Emit Battery telemetry, only on a fresh battery power message.
    -- Victron's D-Bus docs give battery power as "positive when charged,
    -- negative when discharged" (/Dc/0/Power on the battery service), and
    -- dbus-systemcalc-py copies that value into system/0/Dc/Battery/Power.
    -- That is the site convention already, so it passes through, as it does
    -- in victron.lua (Modbus 842, the same value). Up to 1.1.0 this driver
    -- negated it (srcfl/device-drivers#255).
    if fresh_battery then
        local battery = { W = bat_w }
        local v = current(bat_v, bat_v_at)
        local a = current(bat_a, bat_a_at)
        local soc = current(bat_soc, bat_soc_at)
        if v ~= nil then battery.V = v end
        if a ~= nil then battery.A = a end
        if soc ~= nil then battery.SoC_nom_fract = soc / 100 end  -- percent to fraction

        local temp_c = temperature(current(bat_temp, bat_temp_at))
        if temp_c ~= nil then battery.temperature_C = temp_c end

        local b = selected_bms(now)
        local charge_a, discharge_a, charge_w, discharge_w, cell_min_c, cell_max_c
        if b then
            charge_a    = limit_a(b.charge_a)
            discharge_a = limit_a(b.discharge_a)
            charge_w    = limit_w(b.charge_a, b, now)
            discharge_w = limit_w(b.discharge_a, b, now)
            cell_min_c  = temperature(b.cell_min_c)
            cell_max_c  = temperature(b.cell_max_c)
        end
        if charge_w ~= nil then battery.available_charge_W = charge_w end
        if discharge_w ~= nil then battery.available_discharge_W = discharge_w end

        host.emit("battery", battery)

        if temp_c ~= nil then host.emit_metric("battery_temp_c", temp_c, "°C") end
        if charge_a ~= nil then host.emit_metric("battery_charge_limit_a", charge_a, "A") end
        if discharge_a ~= nil then host.emit_metric("battery_discharge_limit_a", discharge_a, "A") end
        if charge_w ~= nil then host.emit_metric("battery_available_charge_w", charge_w, "W") end
        if discharge_w ~= nil then host.emit_metric("battery_available_discharge_w", discharge_w, "W") end
        if cell_min_c ~= nil then host.emit_metric("battery_cell_temp_min_c", cell_min_c, "°C") end
        if cell_max_c ~= nil then host.emit_metric("battery_cell_temp_max_c", cell_max_c, "°C") end
    end

    -- Emit Meter telemetry
    -- Victron grid: positive = import (matches convention)
    local grid_total = grid_l1_w + grid_l2_w + grid_l3_w

    if fresh_meter then
        host.emit("meter", {
            W    = grid_total,
            L1_W = grid_l1_w,
            L2_W = grid_l2_w,
            L3_W = grid_l3_w,
        })
    end

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
    forget_battery_values()
    last_message_ms = nil
    portal_id = nil
    poll_seq = 0
    last_keepalive_ms = nil
    last_republish_ms = nil
    republish_due = true
    keepalive_refused = false
end
