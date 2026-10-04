dofile("drivers/tests/lua_harness/host_mock.lua")
host.reset()
dofile("drivers/lua/heishamon.lua")
driver_init({})

host._mqtt_buffer = {
    {
        topic = "panasonic_heat_pump/main/Heat_Power_Consumption",
        payload = "4200",
    },
    {
        topic = "panasonic_heat_pump/main/Outside_Temp",
        payload = "5",
    },
}
driver_poll()

local fresh_power = host._metrics.hp_power_w
if fresh_power == nil or fresh_power.value ~= 4200 then
    error("fresh Heishamon power reading was not emitted")
end

host._metrics = {}
host._millis_counter = 60100
host._mqtt_buffer = {{
    topic = "panasonic_heat_pump/main/Outside_Temp",
    payload = "6",
}}
driver_poll()

if host._metrics.hp_power_w ~= nil then
    error("stale Heishamon power survived an unrelated fresh topic")
end

local fresh_outdoor = host._metrics.hp_outdoor_temp_c
if fresh_outdoor == nil or fresh_outdoor.value ~= 6 then
    error("fresh unrelated Heishamon telemetry was dropped with stale power")
end

-- Newer heat pumps can send -200 on the old power topic. Invalid values
-- must clear the previous power reading while other measurements survive.
for _, invalid in ipairs({"-200", "nan", "1e99"}) do
    host._metrics = {}
    host._mqtt_buffer = {{topic="panasonic_heat_pump/main/Heat_Power_Consumption", payload="4200"}}
    driver_poll()
    assert(host._metrics.hp_power_w.value == 4200, "valid power did not recover")
    host._metrics = {}
    host._mqtt_buffer = {
        {topic="panasonic_heat_pump/main/Heat_Power_Consumption", payload=invalid},
        {topic="panasonic_heat_pump/main/Outside_Temp", payload="7"},
    }
    driver_poll()
    assert(host._metrics.hp_power_w == nil, "invalid power was emitted: " .. invalid)
    assert(host._metrics.hp_outdoor_temp_c.value == 7, "invalid power dropped outdoor temperature")
end

host._metrics = {}
host._mqtt_buffer = {{topic="panasonic_heat_pump/main/Heat_Power_Consumption", payload="0"}}
driver_poll()
assert(host._metrics.hp_power_w.value == 0, "measured zero power was dropped")
