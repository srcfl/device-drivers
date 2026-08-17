dofile("drivers/tests/lua_harness/host_mock.lua")

local driver_name = arg[1]
if driver_name ~= "huawei" and driver_name ~= "ferroamp_modbus" then
    error("unsupported driver " .. tostring(driver_name))
end

dofile("drivers/lua/" .. driver_name .. ".lua")

driver_init()

local commands = {
    { "battery", 2000 },
    { "battery", -2000 },
    { "battery", 0 },
    { "curtail", 1000 },
    { "curtail_disable", 0 },
    { "deinit", 0 },
}
local accepted = {}
for _, command in ipairs(commands) do
    table.insert(accepted, driver_command(command[1], command[2], {}))
end

driver_default_mode()
driver_cleanup()

if host._modbus_write_attempts ~= 0 then
    error(driver_name .. ": read-only lifecycle attempted " ..
        tostring(host._modbus_write_attempts) .. " Modbus writes")
end

if not DRIVER or DRIVER.read_only ~= true then
    error(driver_name .. ": DRIVER.read_only must be true")
end

for _, result in ipairs(accepted) do
    if result ~= false then
        error(driver_name .. ": accepted a control command")
    end
end
