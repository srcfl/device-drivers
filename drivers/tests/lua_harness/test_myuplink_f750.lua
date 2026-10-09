local ROOT = "./"

dofile(ROOT .. "drivers/tests/lua_harness/host_mock.lua")

local failed = 0

local function fail(msg)
    io.stderr:write("FAIL: " .. msg .. "\n")
    failed = failed + 1
end

local function expect_metric(name, value, unit)
    local metric = host._metrics[name]
    if not metric then
        fail("missing metric " .. name)
        return
    end
    if metric.value ~= value then
        fail(name .. ": expected value " .. tostring(value)
            .. ", got " .. tostring(metric.value))
    end
    if metric.unit ~= unit then
        fail(name .. ": expected unit " .. tostring(unit)
            .. ", got " .. tostring(metric.unit))
    end
end

local function expect_absent(name)
    if host._metrics[name] then
        fail("unexpected metric " .. name)
    end
end

dofile(ROOT .. "drivers/lua/myuplink.lua")

host._http_responses["https://api.myuplink.com/oauth/token"] =
    [[{"access_token":"t","expires_in":3600}]]

host._http_responses["https://api.myuplink.com/v2/devices/F750/points"] = [[
[
  {"parameterId":40004,"value":11.6,"parameterUnit":"°C","parameterName":"Outdoor temperature BT1"},
  {"parameterId":40013,"value":50.3,"parameterUnit":"°C","parameterName":"Hot water top BT7"},
  {"parameterId":40014,"value":49.1,"parameterUnit":"°C","parameterName":"Hot water charging BT6"},
  {"parameterId":40033,"value":22.8,"parameterUnit":"°C","parameterName":"Room temperature BT50"},
  {"parameterId":40940,"value":86,"parameterUnit":"DM","parameterName":"current value"},
  {"parameterId":41778,"value":0,"parameterUnit":"Hz","parameterName":"Current com­pressor fre­quency"},
  {"parameterId":43084,"value":0,"parameterUnit":"kW","parameterName":"Power internal add. heat"},
  {"parameterId":43124,"value":-32768,"parameterUnit":"m3/h","parameterName":"Reference air speed sensor"},
  {"parameterId":44298,"value":10494.7,"parameterUnit":"kWh","parameterName":"Hot water incl internal add heat"},
  {"parameterId":50225,"value":-32768,"parameterUnit":"°C","parameterName":"Current temperature system 1"},
  {"parameterId":50233,"value":-32768,"parameterUnit":"°C","parameterName":"Set point temp system 1 heat"}
]
]]

driver_init({
    client_id = "id",
    client_secret = "secret",
    refresh_token = "refresh",
    device_id = "F750",
    setup_retry_ms = 0,
})

local ok, interval = pcall(driver_poll)
if not ok then
    fail("myuplink poll threw: " .. tostring(interval))
else
    expect_metric("hp_hw_top_temp_c", 50.3, "°C")
    expect_metric("hp_indoor_temp_c", 22.8, "°C")
    expect_metric("hp_outdoor_temp_c", 11.6, "°C")

    expect_metric("hp_degree_minutes", 86, "DM")
    expect_metric("hp_current_compressor_frequency", 0, "Hz")
    expect_metric("hp_power_internal_add_heat", 0, "W")
    expect_metric("hp_hot_water_incl_internal_add_heat", 10494700, "Wh")

    expect_absent("hp_reference_air_speed_sensor")
    expect_absent("hp_current_temperature_system_1")
    expect_absent("hp_set_point_temp_system_1_heat")
end

if failed > 0 then
    io.stderr:write(failed .. " checks failed\n")
    os.exit(1)
end

print("PASS")
