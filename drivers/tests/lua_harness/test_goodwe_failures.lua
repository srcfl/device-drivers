local profile = arg[1]
local scenario = arg[2]
if not profile or not scenario then
    error("profile and failure scenario are required")
end

dofile("drivers/tests/lua_harness/host_mock.lua")
local fixtures = dofile("drivers/tests/lua_harness/goodwe_fixtures.lua")
local fixture = fixtures[profile]
if not fixture then error("unknown fixture profile: " .. tostring(profile)) end

local function load_fixture()
    host.reset()
    for address, registers in pairs(fixture.registers) do
        host._modbus_registers.holding[address] = registers
    end
    dofile("drivers/lua/goodwe.lua")
    driver_init({profile = profile})
end

local function emission_count()
    local count = 0
    for _, stream in ipairs({"pv", "battery", "meter"}) do
        count = count + ((host._emitted[stream] and #host._emitted[stream]) or 0)
    end
    return count
end

load_fixture()

if scenario == "all" then
    host._modbus_read_error = "simulated Modbus timeout"
    local ok = pcall(driver_poll)
    if ok then error("total timeout did not fail the poll") end
    if emission_count() ~= 0 then error("total timeout emitted telemetry") end
elseif scenario == "middle" then
    host._modbus_read_fail_addresses[fixture.failure_address] = "simulated batch timeout"
    local ok = pcall(driver_poll)
    if ok then error("middle batch timeout did not fail the poll") end
    if emission_count() ~= 0 then error("middle batch timeout emitted telemetry") end
elseif scenario == "short" then
    local last = fixture.batches[#fixture.batches]
    host._modbus_read_short_counts[last[1]] = last[2] - 1
    local ok = pcall(driver_poll)
    if ok then error("short batch did not fail the poll") end
    if emission_count() ~= 0 then error("short batch emitted telemetry") end
elseif scenario == "sentinel" then
    if profile ~= "gw8kn-et-hk3000" then error("sentinel is only a GW8KN fixture") end
    fixture.registers[35138][1] = 65535
    local ok = pcall(driver_poll)
    if ok then error("negative PV sentinel did not fail the poll") end
    if emission_count() ~= 0 then error("negative PV sentinel emitted telemetry") end
elseif scenario == "recover" then
    driver_poll()
    if emission_count() ~= 3 then error("first complete poll did not emit all streams") end
    host._modbus_read_fail_addresses[fixture.failure_address] = "simulated mute session"
    local ok = pcall(driver_poll)
    if ok then error("mute session did not fail the poll") end
    if emission_count() ~= 3 then error("failed recovery poll emitted telemetry") end
    host._modbus_read_fail_addresses = {}
    driver_poll()
    if emission_count() ~= 6 then error("post-reconnect poll did not recover") end
else
    error("unknown failure scenario: " .. scenario)
end

if host._modbus_write_attempts ~= 0 then error("read-only failure path attempted a write") end
