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
    driver_init(config or { base_url = "https://hub.test", secret = "s" })
    return driver_poll()
end

-- The hub as it answered.
local interval = run(HUB_R_GEN2)
if interval ~= 60000 then fail("poll interval " .. tostring(interval)) end
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

-- The hub does not answer (wrong secret, or offline): nothing is emitted.
host.reset()
dofile(ROOT .. "drivers/lua/wiser_heat.lua")
driver_init({ base_url = "https://hub.test", secret = "s" })
local retry = driver_poll()
if retry ~= 30000 then fail("retry interval " .. tostring(retry)) end
absent("smoke_alarm_1_temp_c")
absent("heating_channel_1_demand_pct")
expect("wiser_poll_ok", 0)

-- Not JSON.
run("<html>Bad request</html>")
absent("smoke_alarm_1_temp_c")
expect("wiser_poll_ok", 0)

-- No secret: the driver does not call the hub at all.
host.reset()
dofile(ROOT .. "drivers/lua/wiser_heat.lua")
driver_init({ base_url = "https://hub.test" })
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
