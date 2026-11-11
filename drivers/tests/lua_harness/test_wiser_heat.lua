-- wiser_heat: decode the hub's /data/domain/ answer.
--
-- HUB_R_GEN2 is the shape and values one Wiser Hub R gen 2 (WT704R1B30S4,
-- firmware 4.50.4) returned on 2026-11-10, with identifiers replaced and
-- unrelated sections removed: a room with nothing assigned, a smoke alarm,
-- and one heating channel. The later cases change single fields to cover
-- what that hub could not show: a room with a thermostat, an offline
-- device, a sensor error, a relay that is on.
--
-- Usage: lua55 test_wiser_heat.lua

local script_dir = arg[0]:match("(.*/)") or "./"
dofile(script_dir .. "host_mock.lua")

local ROOT = script_dir .. "../../../"
local URL = "https://hub.test/data/domain/"
local failed = 0

local function fail(msg)
    failed = failed + 1
    io.stderr:write("FAIL " .. msg .. "\n")
end

local function expect(name, value, unit)
    local m = host._metrics[name]
    if not m then return fail(name .. ": not emitted") end
    if type(m.value) ~= "number" or math.abs(m.value - value) > 0.001 then
        fail(name .. ": value " .. tostring(m.value) .. " want " .. tostring(value))
    end
    if unit and m.unit ~= unit then
        fail(name .. ": unit " .. tostring(m.unit) .. " want " .. unit)
    end
end

local function absent(name)
    if host._metrics[name] ~= nil then
        fail(name .. ": emitted " .. tostring(host._metrics[name].value) .. ", want absent")
    end
end

local HUB_R_GEN2 = [[{
 "Device": [
  {"id": 0, "ProductType": "Controller", "ModelIdentifier": "WT704R1B30S4",
   "ActiveFirmwareVersion": "4.50.4", "DisplayedSignalStrength": "VeryGood",
   "UUID": "HUB-UUID"},
  {"id": 2, "ProductType": "SmokeAlarmDevice", "ModelIdentifier": "Unknown",
   "ActiveFirmwareVersion": "2.7.6", "DisplayedSignalStrength": "Good"}
 ],
 "Room": [
  {"id": 1, "Name": "Room", "Mode": "Manual",
   "CalculatedTemperature": -32768, "CurrentSetPoint": -200,
   "DisplayedSetPoint": -200, "Invalid": "NothingAssigned",
   "SetpointOrigin": "FromNoControl"}
 ],
 "SmokeAlarmDevice": [
  {"id": 1, "DeviceId": 2, "MeasuredTemperature": 210, "ACMains": false,
   "SmokeAlarm": false, "HeatAlarm": false}
 ],
 "HeatingChannel": [
  {"id": 1, "Name": "Channel-1", "PercentageDemand": 0,
   "DemandOnOffOutput": "Off", "HeatingRelayState": "Off"}
 ]
}]]

local function run(body, config)
    host.reset()
    host._http_responses[URL] = body
    dofile(ROOT .. "drivers/lua/wiser_heat.lua")
    driver_init(config or { host = "hub.test", secret = "s" })
    return driver_poll()
end

-- The hub as it answered.

-- The interval the host will actually use: the last set_poll_interval.
local function set_interval()
    local ms
    for _, call in ipairs(host._calls) do
        if call.func == "set_poll_interval" then ms = call.args[1] end
    end
    return ms
end
local interval = run(HUB_R_GEN2)
if interval ~= 60000 then fail("poll interval " .. tostring(interval)) end
-- The host caps a returned interval at 30 s; the minute has to be set.
if set_interval() ~= 60000 then fail("set_poll_interval " .. tostring(set_interval())) end
if host._make ~= "Wiser" then fail("make " .. tostring(host._make)) end
if host._model ~= "WT704R1B30S4" then fail("model " .. tostring(host._model)) end
if host._sn ~= "HUB-UUID" then fail("sn " .. tostring(host._sn)) end
expect("smoke_alarm_1_temp_c", 21.0, "°C")
expect("heating_channel_1_demand_pct", 0, "%")
expect("heating_channel_1_relay_on", 0)
expect("wiser_poll_ok", 1)
-- Nothing assigned to the room: no temperature and no -20 °C setpoint.
absent("room_1_temp_c")
absent("room_1_setpoint_c")

-- A room with a thermostat, a relay that is on.
local thermostat = HUB_R_GEN2
    :gsub('"CalculatedTemperature": %-32768', '"CalculatedTemperature": 196')
    :gsub('"CurrentSetPoint": %-200', '"CurrentSetPoint": 205')
    :gsub('"PercentageDemand": 0', '"PercentageDemand": 45')
    :gsub('"HeatingRelayState": "Off"', '"HeatingRelayState": "On"')
run(thermostat)
expect("room_1_temp_c", 19.6, "°C")
expect("room_1_setpoint_c", 20.5, "°C")
expect("heating_channel_1_demand_pct", 45, "%")
expect("heating_channel_1_relay_on", 1)

-- A sensor error is not a 200 °C room.
run((HUB_R_GEN2:gsub('"CalculatedTemperature": %-32768', '"CalculatedTemperature": 2000')))
absent("room_1_temp_c")

-- An offline smoke alarm: the hub's cached value is not fresh.
run((HUB_R_GEN2:gsub('"DisplayedSignalStrength": "Good"', '"DisplayedSignalStrength": "Offline"')))
absent("smoke_alarm_1_temp_c")
expect("heating_channel_1_demand_pct", 0, "%")

-- No floor thermostat fields for a room with nothing assigned.
run(HUB_R_GEN2)
absent("room_1_temp_is_floor")
absent("room_1_demand_pct")
absent("room_1_output_on")

-- HUB_CFMT is what the same hub returned on 2026-11-11 with a Renova CFMT
-- 16 A floor thermostat (WDE011680) on electric floor heating, in preset P6
-- (room control on the air sensor, floor sensor as limit), identifiers
-- replaced and unrelated fields removed.
local HUB_CFMT = [[{
 "Device": [
  {"id": 0, "ProductType": "Controller", "ModelIdentifier": "WT704R1B30S4",
   "ActiveFirmwareVersion": "4.50.4", "DisplayedSignalStrength": "VeryGood",
   "UUID": "HUB-UUID"},
  {"id": 8, "ProductType": "CFMT", "ProductIdentifier": "RenovaCFMT16A",
   "ProductModel": "WDE011680", "ModelIdentifier": "Unknown", "RoomId": 6,
   "DisplayedSignalStrength": "VeryGood"}
 ],
 "Room": [
  {"id": 6, "Name": "Room", "Mode": "Auto", "DemandType": "Modulating",
   "CalculatedTemperature": 242, "CurrentSetPoint": 200,
   "FloorSensorState": "InRange", "PercentageDemand": 0,
   "ControlOutputState": "Off", "SetpointOrigin": "FromManualOverride",
   "InputTemperatureType": "Air"}
 ],
 "HeatingActuator": [
  {"id": 8, "DeviceId": 8, "ThermostatApplication": "OccupiedSpace",
   "HeatingEmitter": "Floor", "ControlLoop": "PI",
   "LocalTemperatureSourceSelect": "Ambient", "OutputType": "Relay",
   "OutputRelayEnabled": true,
   "FloorTemperatureSensor": {"MaximumTemperature": 300, "Offset": 0,
    "SensorType": "NTC_15K", "MeasuredTemperature": 263,
    "Status": "Normal_Operation"},
   "MeasuredTemperature": 242, "OccupiedHeatingSetPoint": 200,
   "InstantaneousDemand": 0}
 ],
 "HeatingChannel": [
  {"id": 1, "Name": "Channel-1", "PercentageDemand": 0,
   "DemandOnOffOutput": "Off", "HeatingRelayState": "Off"}
 ]
}]]

-- P6: the room is air, the floor sensor is reported on its own.
run(HUB_CFMT)
expect("room_6_temp_c", 24.2, "°C")
expect("room_6_setpoint_c", 20.0, "°C")
expect("room_6_temp_is_floor", 0)
expect("room_6_demand_pct", 0, "%")
expect("room_6_output_on", 0)
expect("heating_actuator_8_floor_temp_c", 26.3, "°C")
expect("heating_actuator_8_floor_max_c", 30.0, "°C")
-- No lower limit configured: none emitted.
absent("heating_actuator_8_floor_min_c")

-- P8 as the hub showed it on 2026-11-11 before the change: the room
-- temperature is the floor sensor's, and the relay is on.
local p8 = HUB_CFMT
    :gsub('"InputTemperatureType": "Air"', '"InputTemperatureType": "Floor"')
    :gsub('"ControlOutputState": "Off"', '"ControlOutputState": "On"')
    :gsub('"PercentageDemand": 0,(%s+)"ControlOutputState"', '"PercentageDemand": 100,%1"ControlOutputState"')
    :gsub('"CalculatedTemperature": 242', '"CalculatedTemperature": 263')
    :gsub('"FloorTemperatureSensor": {"MaximumTemperature": 300,',
          '"FloorTemperatureSensor": {"MaximumTemperature": 300, "MinimumTemperature": 220,')
run(p8)
expect("room_6_temp_c", 26.3, "°C")
expect("room_6_temp_is_floor", 1)
expect("room_6_demand_pct", 100, "%")
expect("room_6_output_on", 1)
expect("heating_actuator_8_floor_min_c", 22.0, "°C")

-- A floor sensor not in normal operation: its reading is not emitted,
-- the configured limits still are.
run((HUB_CFMT:gsub('"Status": "Normal_Operation"', '"Status": "Open_Circuit"')))
absent("heating_actuator_8_floor_temp_c")
expect("heating_actuator_8_floor_max_c", 30.0, "°C")

-- An offline thermostat: the hub's cached floor reading is not fresh.
run((HUB_CFMT:gsub('"RoomId": 6,(%s+)"DisplayedSignalStrength": "VeryGood"',
                   '"RoomId": 6,%1"DisplayedSignalStrength": "Offline"')))
absent("heating_actuator_8_floor_temp_c")
absent("heating_actuator_8_floor_max_c")

-- The sensor type is logged once, and again when it changes.
local function sensor_logs()
    local n = 0
    for _, l in ipairs(host._logs) do
        if l:find("floor sensor", 1, true) then n = n + 1 end
    end
    return n
end
run(HUB_CFMT)
driver_poll()
if sensor_logs() ~= 1 then fail("sensor type logged " .. sensor_logs() .. " times, want 1") end
host._http_responses[URL] = (HUB_CFMT:gsub("NTC_15K", "NTC_10K"))
driver_poll()
if sensor_logs() ~= 2 then fail("changed sensor type logged " .. sensor_logs() .. " times, want 2") end

-- The hub does not answer (wrong secret, or offline): nothing is emitted.
host.reset()
dofile(ROOT .. "drivers/lua/wiser_heat.lua")
driver_init({ host = "hub.test", secret = "s" })
local retry = driver_poll()
if retry ~= 30000 then fail("retry interval " .. tostring(retry)) end
if set_interval() ~= 30000 then fail("set retry interval " .. tostring(set_interval())) end
absent("smoke_alarm_1_temp_c")
absent("heating_channel_1_demand_pct")
expect("wiser_poll_ok", 0)

-- Not JSON.
run("<html>Bad request</html>")
absent("smoke_alarm_1_temp_c")
expect("wiser_poll_ok", 0)

-- A base_url in config is not honoured: the secret goes only to
-- https://<host>/.
host.reset()
host._http_responses[URL] = HUB_R_GEN2
dofile(ROOT .. "drivers/lua/wiser_heat.lua")
driver_init({ host = "hub.test", base_url = "http://elsewhere.test", secret = "s" })
driver_poll()
for _, c in ipairs(host._calls or {}) do
    if c.func == "http_get" and c.args[1] ~= URL then
        fail("called " .. tostring(c.args[1]) .. ", want " .. URL)
    end
end
expect("wiser_poll_ok", 1)

-- No secret: the driver does not call the hub at all.
host.reset()
dofile(ROOT .. "drivers/lua/wiser_heat.lua")
driver_init({ host = "hub.test" })
driver_poll()
for _, c in ipairs(host._calls or {}) do
    if c.func == "http_get" then fail("called the hub without a secret") end
end
absent("wiser_poll_ok")

if failed > 0 then
    print("FAILED " .. failed)
    os.exit(1)
end
print("PASS")
