-- What victron_mqtt reports about what the battery can do now.
-- Run with the scenario as arg[1].
--
-- Topics follow Venus OS (victronenergy/dbus-flashmq):
--   N/<portal>/<service>/<instance>/<D-Bus path>, payload {"value": ...};
--   {"value": null} for an invalid value, an empty payload when the device
--   left the D-Bus.

local scenario = arg[1]

dofile("drivers/tests/lua_harness/host_mock.lua")
host.reset()
dofile("drivers/lua/victron_mqtt.lua")
driver_init({})

local function msg(topic, value)
    local payload
    if value == "" then
        payload = ""
    elseif value == nil then
        payload = '{"value": null}'
    else
        payload = '{"value": ' .. tostring(value) .. '}'
    end
    return { topic = "N/c0ffee/" .. topic, payload = payload }
end

local function poll(messages)
    host._emitted = {}
    host._metrics = {}
    host._mqtt_buffer = messages
    local ok, err = pcall(driver_poll)
    if not ok then error(scenario .. ": driver_poll failed: " .. tostring(err)) end
    return host._emitted.battery and host._emitted.battery[#host._emitted.battery]
end

local function near(actual, expected)
    return type(actual) == "number" and math.abs(actual - expected) < 0.001
end

local function want(name, actual, expected)
    if not near(actual, expected) then
        error(scenario .. ": " .. name .. " = " .. tostring(actual) .. ", want " .. tostring(expected))
    end
end

local function absent(name, actual)
    if actual ~= nil then
        error(scenario .. ": " .. name .. " = " .. tostring(actual) .. ", want it left out")
    end
end

local function metric(name)
    local entry = host._metrics[name]
    return entry and entry.value
end

local function battery_power(w)
    return msg("system/0/Dc/Battery/Power", w or -1200)
end

-- A GX with one BMS at device instance 512.
local function bms_messages(extra)
    local list = {
        battery_power(),
        msg("system/0/Dc/Battery/Soc", 64),
        msg("system/0/Dc/Battery/Voltage", 52.1),
        msg("system/0/Dc/Battery/Current", -23),
        msg("system/0/Dc/Battery/Temperature", 17.5),
        msg("system/0/ActiveBmsInstance", 512),
        msg("battery/512/Info/MaxChargeCurrent", 50),
        msg("battery/512/Info/MaxDischargeCurrent", 100),
        msg("battery/512/Dc/0/Voltage", 52),
        msg("battery/512/System/MinCellTemperature", 16),
        msg("battery/512/System/MaxCellTemperature", 19.5),
    }
    for _, m in ipairs(extra or {}) do list[#list + 1] = m end
    return list
end

if scenario == "limits" then
    local b = poll(bms_messages())
    if not b then error(scenario .. ": no battery reading") end
    want("battery.temperature_C", b.temperature_C, 17.5)
    want("battery.available_charge_W", b.available_charge_W, 2600)       -- 50 A x 52 V
    want("battery.available_discharge_W", b.available_discharge_W, 5200) -- 100 A x 52 V
    want("battery_temp_c", metric("battery_temp_c"), 17.5)
    want("battery_charge_limit_a", metric("battery_charge_limit_a"), 50)
    want("battery_discharge_limit_a", metric("battery_discharge_limit_a"), 100)
    want("battery_available_charge_w", metric("battery_available_charge_w"), 2600)
    want("battery_available_discharge_w", metric("battery_available_discharge_w"), 5200)
    want("battery_cell_temp_min_c", metric("battery_cell_temp_min_c"), 16)
    want("battery_cell_temp_max_c", metric("battery_cell_temp_max_c"), 19.5)

    -- The latest message is the current value: a later poll with a fresh
    -- battery power carries it, a changed limit replaces it.
    b = poll({ battery_power(), msg("battery/512/Info/MaxChargeCurrent", 10) })
    want("battery.available_charge_W after change", b.available_charge_W, 520)
    want("battery.available_discharge_W kept", b.available_discharge_W, 5200)

elseif scenario == "bms_forbids_discharge" then
    -- DCL 0: the BMS allows no discharge now. That is a reading, not a gap.
    local b = poll(bms_messages({ msg("battery/512/Info/MaxDischargeCurrent", 0) }))
    want("battery.available_discharge_W", b.available_discharge_W, 0)
    want("battery_discharge_limit_a", metric("battery_discharge_limit_a"), 0)
    want("battery.available_charge_W", b.available_charge_W, 2600)

elseif scenario == "no_bms_voltage" then
    -- Amps without the BMS's own voltage give no watts. The amps still go to
    -- history.
    local list = bms_messages()
    for i = #list, 1, -1 do
        if string.find(list[i].topic, "battery/512/Dc/0/Voltage", 1, true) then table.remove(list, i) end
    end
    local b = poll(list)
    absent("battery.available_charge_W", b.available_charge_W)
    absent("battery.available_discharge_W", b.available_discharge_W)
    absent("battery_available_charge_w", metric("battery_available_charge_w"))
    want("battery_charge_limit_a", metric("battery_charge_limit_a"), 50)

elseif scenario == "null_and_gone_clear" then
    poll(bms_messages())
    -- The GX says the limit is invalid, and the system loses its battery
    -- temperature sensor. Neither keeps its last number.
    local b = poll({
        battery_power(),
        msg("battery/512/Info/MaxChargeCurrent", nil),
        msg("system/0/Dc/Battery/Temperature", ""),
    })
    absent("battery.available_charge_W", b.available_charge_W)
    absent("battery_charge_limit_a", metric("battery_charge_limit_a"))
    absent("battery.temperature_C", b.temperature_C)
    absent("battery_temp_c", metric("battery_temp_c"))
    want("battery.available_discharge_W", b.available_discharge_W, 5200)

    -- The BMS leaves the D-Bus: every topic of it arrives empty.
    b = poll({
        battery_power(),
        msg("battery/512/Info/MaxDischargeCurrent", ""),
        msg("battery/512/Dc/0/Voltage", ""),
        msg("battery/512/System/MinCellTemperature", ""),
        msg("battery/512/System/MaxCellTemperature", ""),
    })
    absent("battery.available_discharge_W", b.available_discharge_W)
    absent("battery_cell_temp_min_c", metric("battery_cell_temp_min_c"))
    absent("battery_cell_temp_max_c", metric("battery_cell_temp_max_c"))

elseif scenario == "picks_active_bms" then
    -- Two BMS services and no word on which one the GX uses: no limit.
    local list = {
        battery_power(),
        msg("battery/512/Info/MaxChargeCurrent", 50),
        msg("battery/512/Dc/0/Voltage", 52),
        msg("battery/513/Info/MaxChargeCurrent", 100),
        msg("battery/513/Dc/0/Voltage", 51),
    }
    local b = poll(list)
    absent("battery.available_charge_W with two BMS", b.available_charge_W)
    absent("battery_charge_limit_a with two BMS", metric("battery_charge_limit_a"))

    -- The GX names 513.
    b = poll({ battery_power(), msg("system/0/ActiveBmsInstance", 513) })
    want("battery.available_charge_W from 513", b.available_charge_W, 5100)

    -- A shunt beside one BMS sends voltage but no limit: the BMS is used.
    host.reset(); dofile("drivers/lua/victron_mqtt.lua"); driver_init({})
    b = poll({
        battery_power(),
        msg("battery/512/Info/MaxChargeCurrent", 50),
        msg("battery/512/Dc/0/Voltage", 52),
        msg("battery/258/Dc/0/Voltage", 12.8),
    })
    want("battery.available_charge_W beside a shunt", b.available_charge_W, 2600)

    -- The GX names a battery that sent no limit: nothing is borrowed from
    -- another one.
    b = poll({ battery_power(), msg("system/0/ActiveBmsInstance", 258) })
    absent("battery.available_charge_W for a shunt", b.available_charge_W)

elseif scenario == "out_of_range" then
    local b = poll(bms_messages({
        msg("system/0/Dc/Battery/Temperature", 150),
        msg("battery/512/System/MinCellTemperature", -45),
        msg("battery/512/System/MaxCellTemperature", 101),
        msg("battery/512/Info/MaxChargeCurrent", 3000),   -- 156 kW
        msg("battery/512/Info/MaxDischargeCurrent", -5),  -- not a limit
    }))
    absent("battery.temperature_C", b.temperature_C)
    absent("battery_temp_c", metric("battery_temp_c"))
    absent("battery_cell_temp_min_c", metric("battery_cell_temp_min_c"))
    absent("battery_cell_temp_max_c", metric("battery_cell_temp_max_c"))
    absent("battery.available_charge_W", b.available_charge_W)
    absent("battery_available_charge_w", metric("battery_available_charge_w"))
    absent("battery.available_discharge_W", b.available_discharge_W)
    absent("battery_discharge_limit_a", metric("battery_discharge_limit_a"))

    -- The edges of the ranges are readings.
    b = poll({
        battery_power(),
        msg("system/0/Dc/Battery/Temperature", -40),
        msg("battery/512/System/MaxCellTemperature", 100),
    })
    want("battery.temperature_C at -40", b.temperature_C, -40)
    want("battery_cell_temp_max_c at 100", metric("battery_cell_temp_max_c"), 100)

elseif scenario == "nothing_invented" then
    -- Only battery power arrived. Nothing else may be made up: no 0 % SoC,
    -- no 0 V, no 0 °C, no limit.
    local b = poll({ battery_power(-800) })
    want("battery.W", b.W, 800)
    for key, value in pairs(b) do
        if key ~= "W" and key ~= "w" then
            error(scenario .. ": invented " .. key .. " = " .. tostring(value))
        end
    end
    for name in pairs(host._metrics) do
        error(scenario .. ": invented metric " .. name)
    end

    -- Limits without a fresh battery power are not sent on their own.
    poll({ msg("battery/512/Info/MaxChargeCurrent", 50), msg("battery/512/Dc/0/Voltage", 52) })
    if host._emitted.battery then error(scenario .. ": a limit alone made a battery reading") end
    if next(host._metrics) then error(scenario .. ": a limit alone made a metric") end

else
    error("unknown scenario: " .. tostring(scenario))
end

driver_cleanup()
