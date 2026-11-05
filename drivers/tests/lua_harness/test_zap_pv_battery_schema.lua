-- Exercise zap.lua's read_pv and read_battery on the 1.x and the data model v2
-- local API. Run with the scenario as arg[1]. The v2 payload is what a Zap on
-- firmware 7.0.3 sent for a simulated Solis, with the serial replaced.

local scenario = arg[1]

dofile("drivers/tests/lua_harness/host_mock.lua")
host.reset()

local function respond(path, body)
    host._http_responses["http://127.0.0.1" .. path] = body
end

local V1_DEVICES = [[
{"devices":[{"sn":"INV-1","type":"modbus_tcp","device_type":"inverter","ders":[
  {"type":"pv","enabled":false,"rated_power":20000},
  {"type":"battery","enabled":false,"rated_power":5000,"capacity":15000}]}]}
]]

local V1_DATA = [[
{"pv":{"type":"pv","W":-3000,"rated_power_W":20000,"total_generation_Wh":150000,
  "mppt1_V":300,"mppt1_A":-5,"mppt2_V":290,"mppt2_A":-4.8,"heatsink_C":45},
 "battery":{"type":"battery","W":5000,"V":52,"A":10,"SoC_nom_fract":0.75,
  "rated_power_W":5000,"capacity_Wh":15000,
  "total_charge_Wh":4200000,"total_discharge_Wh":1800000,"heatsink_C":24},
 "version":"v1","format":"json"}
]]

local V2_DEVICES = [[
{"count":1,"devices":[{"type":"modbus_tcp","profile":"solis","device_type":"inverter","sn":"INV-1","ders":[
  {"type":"solar","enabled":true,"installed_power_W_dc":8000},
  {"type":"battery","enabled":true,"rated_power_W_dc":5000,"capacity_Wh_dc":15000},
  {"type":"inverter","enabled":true,"rated_power_W_ac":20000}]}]}
]]

local V2_DATA = [[
{"solar":{"type":"solar","make":"solis","W_ac":null,"W_dc":-3000,
  "mppt":[{"V_dc":300,"A_dc":-5,"W_dc":-1500},{"V_dc":290,"A_dc":-4.8,"W_dc":-1392}],
  "total_generation_Wh_ac":null,"total_generation_Wh_dc":150000,
  "lower_limit_W_ac":null,"lower_limit_W_dc":null},
 "battery":{"type":"battery","make":"solis","W_ac":null,"W_dc":5000,"V_ac":null,"V_dc":52,
  "A_ac":null,"A_dc":10,"soc_nom_fract":0.75,"soh_fract":null,"temperature_C":24,
  "total_charge_Wh_ac":null,"total_charge_Wh_dc":4200000,
  "total_discharge_Wh_ac":null,"total_discharge_Wh_dc":1800000,
  "upper_limit_W_ac":null,"upper_limit_W_dc":5000,"setpoint_W_ac":null,"setpoint_W_dc":5000},
 "inverter":{"type":"inverter","make":"solis","W_ac":-2400,"temperature_C":45,"rated_power_W_ac":20000},
 "version":"v2","format":"json"}
]]

local function near(actual, expected)
    return type(actual) == "number" and math.abs(actual - expected) < 0.001
end

local function want(name, actual, expected)
    if not near(actual, expected) then
        error(scenario .. ": " .. name .. " = " .. tostring(actual) .. ", want " .. tostring(expected))
    end
end

local function metric(name)
    local entry = host._metrics[name]
    return entry and entry.value
end

local function poll(config)
    dofile("drivers/lua/zap.lua")
    config.host = "127.0.0.1"
    driver_init(config)
    local ok, err = pcall(driver_poll)
    if not ok then error("driver_poll failed: " .. tostring(err)) end
end

local function assert_full_reading()
    local pv = host._emitted.pv and host._emitted.pv[1]
    if not pv then error(scenario .. ": no pv reading") end
    want("pv.w", pv.w, -3000)
    want("pv.total_generation_wh", pv.total_generation_wh, 150000)
    want("pv.rated_w", pv.rated_w or pv.rated_power_w, 20000)

    local battery = host._emitted.battery and host._emitted.battery[1]
    if not battery then error(scenario .. ": no battery reading") end
    want("battery.w", battery.w, 5000)
    want("battery.soc", battery.soc, 0.75)
    want("battery.v", battery.v, 52)
    want("battery.a", battery.a, 10)
    want("battery.temp_c", battery.temp_c, 24)
    want("battery.total_charge_wh", battery.total_charge_wh, 4200000)
    want("battery.total_discharge_wh", battery.total_discharge_wh, 1800000)
    want("battery.rated_w", battery.rated_w or battery.rated_power_w, 5000)

    want("pv_heatsink_c", metric("pv_heatsink_c"), 45)
    want("pv_mppt1_v", metric("pv_mppt1_v"), 300)
    want("pv_mppt1_a", metric("pv_mppt1_a"), -5)
    want("pv_mppt2_v", metric("pv_mppt2_v"), 290)
    want("pv_mppt2_a", metric("pv_mppt2_a"), -4.8)
    want("battery_dc_v", metric("battery_dc_v"), 52)
    want("battery_dc_a", metric("battery_dc_a"), 10)
end

if scenario == "v1" then
    respond("/api/devices", V1_DEVICES)
    respond("/api/devices/INV-1/data/json", V1_DATA)
    poll({ read_pv = true, read_battery = true })
    assert_full_reading()

elseif scenario == "v2" then
    respond("/api/devices", V2_DEVICES)
    respond("/api/devices/INV-1/data/json", V2_DATA)
    poll({ read_pv = true, read_battery = true })
    assert_full_reading()

elseif scenario == "v2_panels_rating" then
    -- No inverter rating set: the rating falls back on the installed panels.
    respond("/api/devices", [[
{"devices":[{"type":"modbus_tcp","device_type":"inverter","sn":"INV-1","ders":[
  {"type":"solar","installed_power_W_dc":8000},
  {"type":"inverter","rated_power_W_ac":0}]}]}
]])
    respond("/api/devices/INV-1/data/json", [[{"solar":{"W_ac":null,"W_dc":-3000},"version":"v2"}]])
    poll({ read_pv = true })
    want("pv.rated_w", host._emitted.pv[1].rated_w or host._emitted.pv[1].rated_power_w, 8000)

elseif scenario == "v2_ac_side" then
    -- An AC-side power and energy count. An AC-side voltage and current are the
    -- grid's, so they are not the battery's.
    respond("/api/devices", V2_DEVICES)
    respond("/api/devices/INV-1/data/json", [[
{"solar":{"W_ac":-1000,"W_dc":null,"total_generation_Wh_ac":700,"total_generation_Wh_dc":null},
 "battery":{"W_ac":-400,"W_dc":null,"V_ac":230,"V_dc":null,"A_ac":-1.7,"A_dc":null,
  "soc_nom_fract":0.5,"total_charge_Wh_ac":90,"total_charge_Wh_dc":null},
 "version":"v2"}
]])
    poll({ read_pv = true, read_battery = true })
    want("pv.w", host._emitted.pv[1].w, -1000)
    want("pv.total_generation_wh", host._emitted.pv[1].total_generation_wh, 700)
    local battery = host._emitted.battery[1]
    want("battery.w", battery.w, -400)
    want("battery.total_charge_wh", battery.total_charge_wh, 90)
    if battery.v ~= nil or battery.a ~= nil then
        error("v2_ac_side: an AC voltage or current became the battery's")
    end
    if metric("battery_dc_v") ~= nil or metric("battery_dc_a") ~= nil then
        error("v2_ac_side: an AC voltage or current became a DC metric")
    end

elseif scenario == "v2_null" then
    -- What was not read stays unknown, never 0.
    respond("/api/devices", V2_DEVICES)
    respond("/api/devices/INV-1/data/json", [[
{"solar":{"W_ac":null,"W_dc":null,"mppt":null,"total_generation_Wh_ac":null,"total_generation_Wh_dc":null},
 "battery":{"W_ac":null,"W_dc":null,"V_dc":null,"soc_nom_fract":null},
 "version":"v2"}
]])
    poll({ read_pv = true, read_battery = true })
    if host._emitted.pv then error("v2_null: null power became a pv reading") end
    if host._emitted.battery then error("v2_null: null power became a battery reading") end

elseif scenario == "v2_null_soc" then
    respond("/api/devices", V2_DEVICES)
    respond("/api/devices/INV-1/data/json", [[
{"battery":{"W_dc":100,"soc_nom_fract":null,"total_charge_Wh_dc":null},"version":"v2"}
]])
    poll({ read_battery = true })
    local battery = host._emitted.battery[1]
    if battery.soc ~= nil or battery.total_charge_wh ~= nil then
        error("v2_null_soc: an unread value was invented")
    end

elseif scenario == "v2_not_opted_in" then
    -- The defaults are unchanged: nothing but the meter is read, and the v2
    -- inverter DER is not a resource of its own.
    respond("/api/devices", [[
{"devices":[{"type":"modbus_tcp","device_type":"inverter","sn":"INV-1","ders":[
  {"type":"solar"},{"type":"battery"},{"type":"inverter","rated_power_W_ac":20000}]},
 {"type":"mqtt","device_type":"v2x_charger","sn":"EV-1","ders":[{"type":"ev_charger_port"}]}]}
]])
    respond("/api/devices/INV-1/data/json", V2_DATA)
    poll({})
    if host._emitted.pv or host._emitted.battery then
        error("v2_not_opted_in: read a resource that was not opted in")
    end
    want("other_resources", metric("other_resources"), 3)

else
    error("unknown scenario: " .. tostring(scenario))
end

driver_cleanup()
