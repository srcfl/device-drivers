-- ferroamp_modbus battery block. Run with the scenario as arg[1].
--
-- Ferroamp Modbus TCP Revision D: input 6100 battery power (kW, + discharging),
-- 6016 SoC (%), 6064 / 6068 energy from / to the battery (kWh). Floats are
-- IEEE 754 with the low word at the lower address.

local scenario = arg[1]

dofile("drivers/tests/lua_harness/host_mock.lua")
host.reset()

local function f32(value)
    local hi, lo = string.unpack(">I2I2", string.pack(">f", value))
    return { lo, hi }
end

local function near(actual, expected)
    return type(actual) == "number" and math.abs(actual - expected) < 0.01
end

local function want(name, actual, expected)
    if not near(actual, expected) then
        error(scenario .. ": " .. name .. " = " .. tostring(actual) .. ", want " .. tostring(expected))
    end
end

local function poll()
    dofile("drivers/lua/ferroamp_modbus.lua")
    driver_init({})
    local ok, err = pcall(driver_poll)
    if not ok then error(scenario .. ": driver_poll failed: " .. tostring(err)) end
    return host._emitted.battery and host._emitted.battery[1]
end

local input = host._modbus_registers.input
input[6100] = f32(2.5)                  -- discharging 2.5 kW
input[6016] = f32(64)
local energy = {}
for _, r in ipairs(f32(1200)) do energy[#energy + 1] = r end   -- 6064-6065
energy[3], energy[4] = 0, 0
for _, r in ipairs(f32(1500)) do energy[#energy + 1] = r end   -- 6068-6069
energy[7], energy[8] = 0, 0
input[6064] = energy

if scenario == "battery" then
    local b = poll()
    if not b then error(scenario .. ": no battery reading") end
    want("battery.w", b.w, -2500)
    want("battery.soc", b.soc, 0.64)
    want("battery.discharge_wh", b.discharge_wh, 1200000)
    want("battery.charge_wh", b.charge_wh, 1500000)
    -- Ferroamp's Modbus map has no battery temperature or live limit.
    for key in pairs(b) do
        if string.find(key, "temp", 1, true) or string.find(key, "available", 1, true) then
            error(scenario .. ": invented " .. key)
        end
    end

elseif scenario == "power_read_fails" then
    host._modbus_read_fail_addresses[6100] = "Illegal Data Address"
    if poll() then error(scenario .. ": no battery power, but a battery reading") end
    if not host._emitted.meter then error(scenario .. ": the meter went with the battery") end

elseif scenario == "energy_read_fails" then
    host._modbus_read_fail_addresses[6064] = "Illegal Data Address"
    local b = poll()
    want("battery.w", b.w, -2500)
    if b.charge_wh ~= nil or b.discharge_wh ~= nil then
        error(scenario .. ": a failed energy read became a counter")
    end

elseif scenario == "soc_read_fails" then
    host._modbus_read_fail_addresses[6016] = "Illegal Data Address"
    local b = poll()
    want("battery.w", b.w, -2500)
    if b.soc ~= nil then error(scenario .. ": a failed SoC read became a SoC") end

else
    error("unknown scenario: " .. tostring(scenario))
end
