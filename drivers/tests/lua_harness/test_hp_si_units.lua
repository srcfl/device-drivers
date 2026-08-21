-- Pin kW/kWh → W/Wh at emit for nibe_local and myuplink.
--
-- Usage: lua55 test_hp_si_units.lua

local script_dir = arg[0]:match("(.*/)") or "./"
dofile(script_dir .. "host_mock.lua")

local ROOT = script_dir .. "../../../"
local failed = 0

local function fail(msg)
    failed = failed + 1
    io.stderr:write("FAIL " .. msg .. "\n")
end

local function near(a, b)
    return type(a) == "number" and math.abs(a - b) < 0.01
end

local function expect_metric(name, value, unit)
    local m = host._metrics[name]
    if not m then
        fail(name .. ": not emitted")
        return
    end
    if not near(m.value, value) then
        fail(name .. ": value " .. tostring(m.value) .. " want " .. tostring(value))
    end
    if m.unit ~= unit then
        fail(name .. ": unit " .. tostring(m.unit) .. " want " .. tostring(unit))
    end
end

---------------------------------------------------------------------------
-- nibe_local: divisor then SI conversion, folded units, unexpected preserved
---------------------------------------------------------------------------

host.reset()
dofile(ROOT .. "drivers/lua/nibe_local.lua")

host._http_responses["https://192.168.1.180:8443/api/v1/devices/SN1/points"] = [[{
  "1801": {
    "title": "Compressor",
    "value": {"integerValue": 15},
    "metadata": {"unit": "kW ", "divisor": 10, "variableSize": "s16", "modbusRegisterID": 1}
  },
  "22130": {
    "title": "Used",
    "value": {"integerValue": 800},
    "metadata": {"unit": "W", "divisor": 1, "variableSize": "s16", "modbusRegisterID": 2}
  },
  "28393": {
    "title": "Consumed",
    "value": {"integerValue": 53999},
    "metadata": {"unit": "KWh", "divisor": 10, "variableSize": "s32", "modbusRegisterID": 3}
  },
  "28392": {
    "title": "Produced",
    "value": {"integerValue": 42},
    "metadata": {"divisor": 1, "variableSize": "s32", "modbusRegisterID": 4}
  },
  "4001": {
    "title": "Bulk kilowatt",
    "value": {"integerValue": 25},
    "metadata": {"unit": "kW", "divisor": 10, "variableSize": "s16", "modbusRegisterID": 5}
  },
  "4002": {
    "title": "Bulk watts",
    "value": {"integerValue": 1200},
    "metadata": {"unit": "W", "divisor": 1, "variableSize": "s16", "modbusRegisterID": 6}
  },
  "4003": {
    "title": "Bulk energy",
    "value": {"integerValue": 12},
    "metadata": {"unit": "kWh", "divisor": 1, "variableSize": "s32", "modbusRegisterID": 7}
  },
  "4004": {
    "title": "Speed",
    "value": {"integerValue": 3000},
    "metadata": {"unit": "rpm", "divisor": 1, "variableSize": "s16", "modbusRegisterID": 8}
  },
  "4005": {
    "title": "Odd power",
    "value": {"integerValue": 9},
    "metadata": {"unit": "GM", "divisor": 1, "variableSize": "s16", "modbusRegisterID": 9}
  }
}]]

driver_init({
    host = "192.168.1.180",
    username = "user",
    password = "pass",
    device_id = "SN1",
})
local nibe_ok, nibe_interval = pcall(driver_poll)
if not nibe_ok then
    fail("nibe poll threw: " .. tostring(nibe_interval))
else
    expect_metric("hp_power_w", 1500, "W")
    expect_metric("hp_used_power_w", 800, "W")
    expect_metric("hp_energy_consumed_kwh", 5399900, "Wh")
    expect_metric("hp_energy_produced_kwh", 42, "Wh")
    expect_metric("hp_bulk_kilowatt", 2500, "W")
    expect_metric("hp_bulk_watts", 1200, "W")
    expect_metric("hp_bulk_energy", 12000, "Wh")
    expect_metric("hp_speed", 3000, "rpm")
    expect_metric("hp_odd_power", 9, "GM")
    local consumed = host._metrics["hp_energy_consumed_kwh"]
    if consumed and consumed.unit == "Wh" and consumed.name then
        fail("headline name must stay hp_energy_consumed_kwh")
    end
end

-- Missing points URL must take the retry path, not abort the poll.
driver_cleanup()
host.reset()
driver_init({
    host = "192.168.1.180",
    username = "user",
    password = "pass",
    device_id = "SN1",
})
local err_ok, err_ret = pcall(driver_poll)
if not err_ok then
    fail("nibe poll without HTTP fixture threw: " .. tostring(err_ret))
elseif type(err_ret) ~= "number" then
    fail("nibe poll without HTTP fixture returned " .. tostring(err_ret))
end

---------------------------------------------------------------------------
-- myuplink: headline kW, bulk kWh, folded "kW ", unexpected preserved
---------------------------------------------------------------------------

driver_cleanup()
host.reset()
dofile(ROOT .. "drivers/lua/myuplink.lua")

host._http_responses["https://api.myuplink.com/oauth/token"] =
    [[{"access_token":"t","expires_in":3600}]]
host._http_responses["https://api.myuplink.com/v2/devices/DEV1/points"] = [[
[
  {"parameterId": 10012, "value": 1.5, "parameterUnit": "kW", "parameterName": "Compressor"},
  {"parameterId": 40013, "value": 48, "parameterUnit": "°C", "parameterName": "HW"},
  {"parameterId": 40033, "value": 21, "parameterUnit": "°C", "parameterName": "Indoor"},
  {"parameterId": 40004, "value": 5, "parameterUnit": "°C", "parameterName": "Outdoor"},
  {"parameterId": 99901, "value": 12.3, "parameterUnit": "kWh", "parameterName": "Energy consumed"},
  {"parameterId": 99902, "value": 800, "parameterUnit": "W", "parameterName": "Used power"},
  {"parameterId": 99903, "value": 2.0, "parameterUnit": "kW ", "parameterName": "Odd kilowatt"},
  {"parameterId": 99904, "value": 3000, "parameterUnit": "rpm", "parameterName": "Speed"}
]
]]

driver_init({
    client_id = "id",
    client_secret = "secret",
    refresh_token = "refresh",
    device_id = "DEV1",
    setup_retry_ms = 0,
})
local up_ok, up_interval = pcall(driver_poll)
if not up_ok then
    fail("myuplink poll threw: " .. tostring(up_interval))
else
    expect_metric("hp_power_w", 1500, "W")
    expect_metric("hp_energy_consumed", 12300, "Wh")
    expect_metric("hp_used_power", 800, "W")
    expect_metric("hp_odd_kilowatt", 2000, "W")
    expect_metric("hp_speed", 3000, "rpm")
    if host._metrics["hp_energy_consumed_kwh"] then
        fail("myuplink must not emit hp_energy_consumed_kwh")
    end
end

if failed > 0 then
    io.stderr:write(failed .. " checks failed\n")
    os.exit(1)
end
print("PASS")
