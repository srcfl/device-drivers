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
