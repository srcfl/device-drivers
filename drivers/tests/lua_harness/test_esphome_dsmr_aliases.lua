local scenario = arg[1]
if scenario ~= "name-derived" and scenario ~= "delivered-returned" then
    error("alias scenario must be name-derived or delivered-returned")
end

dofile("drivers/tests/lua_harness/host_mock.lua")
host.reset()

host.set_poll_interval = function(interval_ms)
    host._poll_interval = interval_ms
end
host.emit_metric = function() end
host.http_get = function(url)
    local response = host._http_responses[url]
    if response then return response, nil end
    return nil, "404: " .. url
end

local function sensor(path, value)
    host._http_responses["http://127.0.0.1/" .. path] =
        string.format('{"value":%s}', tostring(value))
end

local function text_sensor(path, value)
    host._http_responses["http://127.0.0.1/text_sensor/" .. path] =
        string.format('{"value":"%s"}', value)
end

dofile("drivers/lua/esphome-dsmr.lua")

if type(DRIVER) ~= "table" or DRIVER.id ~= "esphome-dsmr" or DRIVER.version ~= "1.0.1" then
    error("ESPHome DSMR identity metadata is wrong")
end
if DRIVER.host_api_min ~= 1 or DRIVER.host_api_max ~= 1 or DRIVER.read_only ~= true then
    error("ESPHome DSMR host API or read-only metadata is wrong")
end

if scenario == "name-derived" then
    sensor("sensor/power_consumed", 0)
    sensor("sensor/power_produced", 4.782)
    sensor("sensor/power_consumed_phase_1", 0)
    sensor("sensor/power_produced_phase_1", 4.775)
    sensor("sensor/power_consumed_phase_2", 0)
    sensor("sensor/power_produced_phase_2", 4.783)
    sensor("sensor/power_consumed_phase_3", 0)
    sensor("sensor/power_produced_phase_3", 4.743)
    sensor("sensor/voltage_phase_1", 236.1)
    sensor("sensor/voltage_phase_2", 236.0)
    sensor("sensor/voltage_phase_3", 236.5)
    sensor("sensor/current_phase_1", 20.5)
    sensor("sensor/current_phase_2", 20.4)
    sensor("sensor/current_phase_3", 20.3)
    text_sensor("dsmr_identification", "TESTDSMR-P1-00000001")
else
    sensor("sensor/power_delivered", 1.5)
    sensor("sensor/power_returned", 0.25)
    sensor("sensor/power_delivered_l1", 0.5)
    sensor("sensor/power_delivered_l2", 0.5)
    sensor("sensor/power_delivered_l3", 0.5)
    sensor("sensor/power_returned_l1", 0.1)
    sensor("sensor/power_returned_l2", 0.08)
    sensor("sensor/power_returned_l3", 0.07)
    sensor("sensor/voltage_l1", 230)
    sensor("sensor/voltage_l2", 231)
    sensor("sensor/voltage_l3", 229)
    sensor("sensor/current_l1", 6.5)
    sensor("sensor/current_l2", 6.4)
    sensor("sensor/current_l3", 6.3)
    sensor("sensor/energy_delivered", 1000)
    sensor("sensor/energy_returned", 42)
end

driver_init({host = "127.0.0.1", poll_ms = 1000})
local ok, poll_result = pcall(driver_poll)
if not ok then error("ESPHome DSMR poll failed: " .. tostring(poll_result)) end

local samples = host._emitted.meter
if not samples or #samples ~= 1 then error("ESPHome DSMR did not emit one meter sample") end
local meter = samples[1]
local function near(actual, expected)
    return type(actual) == "number" and math.abs(actual - expected) < 0.001
end

if scenario == "name-derived" then
    if host._sn ~= "TESTDSMR-P1-00000001" then error("dsmr_identification alias was not used") end
    if not near(meter.w, -4782) or not near(meter.l3_w, -4743) then
        error("name-derived power aliases produced wrong signs or values")
    end
    if not near(meter.l1_a, 20.5) or not near(meter.l2_a, 20.4) or not near(meter.l1_v, 236.1) then
        error("name-derived phase aliases were not emitted")
    end
else
    if not near(meter.w, 1250) or not near(meter.l1_w, 400) then
        error("delivered/returned power aliases produced wrong signs or values")
    end
    if not near(meter.l2_a, 6.4) or not near(meter.import_wh, 1000000) or
       not near(meter.export_wh, 42000) then
        error("delivered/returned phase or energy aliases were not emitted")
    end
end

if driver_command("meter", 0, {}) ~= false then
    error("ESPHome DSMR read-only command did not reject control")
end
driver_default_mode()
driver_cleanup()
