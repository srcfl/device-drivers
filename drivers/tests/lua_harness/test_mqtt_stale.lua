local driver_name = arg[1]
if not driver_name then error("driver name is required") end

dofile("drivers/tests/lua_harness/host_mock.lua")
host.reset()
dofile("drivers/lua/" .. driver_name .. ".lua")
driver_init({})

if driver_name == "ambibox" then
    host._mqtt_buffer = {
        {topic = "device/evCharger/0/powerAc", payload = "3500"},
        {topic = "device/evCharger/0/powerDc", payload = "3300"},
    }
elseif driver_name == "ferroamp" then
    host._mqtt_buffer = {{
        topic = "extapi/data/ehub",
        payload = '{"pext":{"val":[1500,0,0]},"ppv":{"val":[3000]},"pbat":{"val":-500}}',
    }}
elseif driver_name == "ferroamp_dc2_v2x" then
    host._mqtt_buffer = {
        {topic = "dc2/connector/1/pe/measured_voltage", payload = "400"},
        {topic = "dc2/connector/1/pe/measured_current", payload = "10"},
    }
elseif driver_name == "opendtu_mqtt" then
    host._mqtt_buffer = {{topic = "solar/inverter/status/AC/Power", payload = "4200"}}
elseif driver_name == "victron_mqtt" then
    host._mqtt_buffer = {
        {topic = "N/test/system/0/Ac/Grid/L1/Power", payload = '{"value":1200}'},
        {topic = "N/test/system/0/Ac/PvOnOutput/L1/Power", payload = '{"value":3000}'},
        {topic = "N/test/system/0/Dc/Battery/Power", payload = '{"value":-500}'},
    }
else
    error("unknown MQTT driver: " .. driver_name)
end

local fresh_ok, fresh_error = pcall(driver_poll)
if not fresh_ok then error("fresh poll raised: " .. tostring(fresh_error)) end

local fresh_emits = 0
for _, emissions in pairs(host._emitted) do fresh_emits = fresh_emits + #emissions end
if fresh_emits == 0 then error("fresh poll emitted no telemetry") end

host._emitted = {}
host._mqtt_buffer = {}
local stale_ok, stale_error = pcall(driver_poll)
if not stale_ok then error("idle poll raised: " .. tostring(stale_error)) end

for stream, emissions in pairs(host._emitted) do
    if #emissions > 0 then
        error(string.format("idle MQTT poll emitted %d %s samples", #emissions, stream))
    end
end
