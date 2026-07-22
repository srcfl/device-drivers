dofile("drivers/tests/lua_harness/host_mock.lua")
host.reset()

-- Model the FTW v1 host exactly for the calls GoodWe uses. The old generic
-- aliases do not exist in FTW and must not hide a source compatibility bug.
host.decode_u32 = nil
host.decode_i32 = nil
host.decode_u32_be = function(hi, lo)
    return (hi & 0xFFFF) * 65536 + (lo & 0xFFFF)
end
host.decode_i32_be = function(hi, lo)
    local value = (hi & 0xFFFF) * 65536 + (lo & 0xFFFF)
    if value >= 0x80000000 then return value - 0x100000000 end
    return value
end
host.log = function(level, message)
    if type(level) ~= "string" or type(message) ~= "string" then
        error("FTW host.log requires level and message")
    end
end

dofile("drivers/lua/goodwe.lua")

if type(DRIVER) ~= "table" or DRIVER.id ~= "goodwe" or DRIVER.version ~= "1.0.2" then
    error("GoodWe FTW identity metadata is wrong")
end
if DRIVER.host_api_min ~= 1 or DRIVER.host_api_max ~= 1 or DRIVER.read_only ~= true then
    error("GoodWe FTW host API or read-only metadata is wrong")
end
if type(DRIVER.protocols) ~= "table" or DRIVER.protocols[1] ~= "modbus" then
    error("GoodWe FTW protocol metadata is wrong")
end
if DRIVER.connection_defaults.unit_id ~= 1 then
    error("GoodWe legacy connection default changed")
end
if type(driver_init) ~= "function" or type(driver_poll) ~= "function" or
   type(driver_command) ~= "function" or type(driver_default_mode) ~= "function" then
    error("GoodWe FTW lifecycle is incomplete")
end

local fixture = dofile("drivers/tests/lua_harness/goodwe_fixtures.lua")["gw8kn-et-hk3000"]
for address, registers in pairs(fixture.registers) do
    host._modbus_registers.holding[address] = registers
end

driver_init({profile = "gw8kn-et-hk3000"})
local ok, poll_error = pcall(driver_poll)
if not ok then error("GoodWe failed against the FTW v1 host: " .. tostring(poll_error)) end
if host._make ~= "GoodWe" then error("GoodWe did not report its make") end
if not host._emitted.pv or host._emitted.pv[1].w ~= -5000 then
    error("GoodWe FTW PV decode or sign is wrong")
end
if not host._emitted.meter or host._emitted.meter[1].w ~= 1500 then
    error("GoodWe FTW meter decode or sign is wrong")
end

local writes_before = host._modbus_write_attempts
if driver_command("battery", 1000, {}) ~= false then
    error("GoodWe read-only command did not reject control")
end
driver_default_mode()
driver_cleanup()
if host._modbus_write_attempts ~= writes_before then
    error("GoodWe read-only lifecycle attempted a write")
end
