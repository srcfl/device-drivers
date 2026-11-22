-- victron (Modbus) battery block. Run with the scenario as arg[1].
--
-- Registers on com.victronenergy.system (Victron dbus_modbustcp
-- attributes.csv): 840 voltage (0.1 V), 841 current (0.1 A, signed),
-- 842 power (W, signed), 843 SoC (%), 844 battery state
-- (0 idle, 1 charging, 2 discharging).

local scenario = arg[1]

dofile("drivers/tests/lua_harness/host_mock.lua")
host.reset()

local function near(actual, expected)
    return type(actual) == "number" and math.abs(actual - expected) < 0.001
end

local function want(name, actual, expected)
    if not near(actual, expected) then
        error(scenario .. ": " .. name .. " = " .. tostring(actual) .. ", want " .. tostring(expected))
    end
end

local function poll()
    dofile("drivers/lua/victron.lua")
    driver_init({})
    local ok, err = pcall(driver_poll)
    if not ok then error(scenario .. ": driver_poll failed: " .. tostring(err)) end
end

-- 53.2 V, -10.0 A, -536 W, 80 %, state 1 (charging).
host._modbus_registers.holding[840] = { 532, 65436, 65000, 80, 1 }
host._modbus_registers.holding[820] = { 100, 200, 300 }

if scenario == "battery" then
    poll()
    local b = host._emitted.battery and host._emitted.battery[1]
    if not b then error(scenario .. ": no battery reading") end
    want("battery.v", b.v, 53.2)
    want("battery.a", b.a, -10)
    want("battery.w", b.w, -536)
    want("battery.soc", b.soc, 0.8)
    -- 844 is the battery state, not a temperature: state 1 once came out
    -- as a battery at 0.1 °C.
    if b.temp_c ~= nil or b.temperature_C ~= nil then
        error(scenario .. ": battery state 844 became a temperature")
    end
    if host._metrics.battery_temp_c ~= nil then
        error(scenario .. ": battery state 844 became a battery_temp_c metric")
    end
    -- The system service has no BMS limit, so none is reported.
    for key in pairs(b) do
        if string.find(key, "available", 1, true) then
            error(scenario .. ": invented " .. key)
        end
    end
    want("battery_dc_v", host._metrics.battery_dc_v and host._metrics.battery_dc_v.value, 53.2)

elseif scenario == "battery_read_fails" then
    host._modbus_read_fail_addresses[840] = "Illegal Data Address"
    poll()
    if host._emitted.battery then
        error(scenario .. ": a failed battery read became a battery reading")
    end
    for _, name in ipairs({ "battery_dc_v", "battery_dc_a", "battery_temp_c" }) do
        if host._metrics[name] ~= nil then
            error(scenario .. ": a failed battery read became metric " .. name)
        end
    end
    if not host._emitted.meter then
        error(scenario .. ": the meter went with the battery")
    end

else
    error("unknown scenario: " .. tostring(scenario))
end
