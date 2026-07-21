local scenario = arg[1]
if not scenario then
    error("failure scenario is required")
end

dofile("drivers/tests/lua_harness/host_mock.lua")
host.reset()
dofile("drivers/lua/goodwe.lua")
driver_init({})

local expected = {pv = true, battery = true, meter = true}
if scenario == "all" then
    host._modbus_read_error = "simulated Modbus timeout"
    expected = {}
elseif scenario == "pv" then
    host._modbus_read_fail_addresses[35105] = "simulated PV power timeout"
    expected.pv = nil
elseif scenario == "battery" then
    host._modbus_read_fail_addresses[35180] = "simulated battery power timeout"
    expected.battery = nil
elseif scenario == "meter" then
    host._modbus_read_fail_addresses[35140] = "simulated meter power timeout"
    expected.meter = nil
else
    error("unknown failure scenario: " .. scenario)
end

local ok, poll_error = pcall(driver_poll)
if not ok then
    error("driver_poll raised: " .. tostring(poll_error))
end

for _, stream in ipairs({"pv", "battery", "meter"}) do
    local emitted = (host._emitted[stream] and #host._emitted[stream] > 0) or false
    if emitted ~= (expected[stream] == true) then
        error(string.format("%s emission=%s, expected=%s", stream, tostring(emitted), tostring(expected[stream] == true)))
    end
end
