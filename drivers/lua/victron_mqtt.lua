-- Victron Energy Venus OS MQTT Driver (community, untested)
-- Emits: PV, Battery, Meter
-- Subscribes to N/+/system/0/... topics on the Venus OS MQTT broker, and to
-- the BMS's own limits on N/+/battery/+/...
-- Values come as JSON: {"value": 123.4}
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
-- This driver sends no keep-alive (R/<portal ID>/keepalive). Venus OS
-- publishes only while some client keeps it alive, and a value that seldom
-- changes, such as a fixed CCL or ActiveBmsInstance, arrives only when a
-- keep-alive asks for a full republish. Until then the limit is left out.
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
-- A tighter bound per value, for SoC and temperature too, would need the
-- driver to ask for a full republish with a keep-alive every 30 s or so.
-- It sends none today.
local BMS_MAX_AGE_MS = 60000
local LINK_SILENT_MS = 60000
local last_message_ms = nil   -- host.millis() of the latest message batch
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

local function forget_battery_values()
    bat_soc = nil
    bat_v = nil
    bat_a = nil
    bat_temp = nil
    bms = {}
    active_bms = nil
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

    -- A silent link: what was cached may have changed or gone unheard.
    if last_message_ms ~= nil and now - last_message_ms > LINK_SILENT_MS then
        forget_battery_values()
        last_message_ms = nil
    end

    if not messages or #messages == 0 then return 1000 end
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

        if instance then
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
            bat_soc = val
        elseif topic_ends_with(topic, "Dc/Battery/Voltage") then
            bat_v = val
        elseif topic_ends_with(topic, "Dc/Battery/Current") then
            bat_a = val
        elseif topic_ends_with(topic, "Dc/Battery/Temperature") then
            -- The system's battery temperature: the battery monitor's or
            -- BMS's sensor, not an inverter heatsink.
            bat_temp = val

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
        if bat_v ~= nil then battery.V = bat_v end
        if bat_a ~= nil then battery.A = bat_a end
        if bat_soc ~= nil then battery.SoC_nom_fract = bat_soc / 100 end  -- percent to fraction

        local temp_c = temperature(bat_temp)
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
end
