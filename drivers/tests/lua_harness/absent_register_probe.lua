-- For one driver, take each register it reads, make that register stop
-- answering, and watch what the driver does about it over ten polls.
--
-- The rule being measured: a driver that keeps reporting telemetry must not
-- keep failing reads. The host counts every failed host.modbus_read against
-- the poll whether or not Lua caught it (go/internal/drivers/lua.go, "%d of
-- %d modbus reads failed"), so a driver that decided it can live without a
-- register and then goes on paying for it every five seconds gets marked
-- offline by the stale-telemetry watchdog. The site then reports nothing at
-- all, which is worse than reporting one field less.
--
-- Emitting nothing while failing is fine and is not a violation: a device
-- that cannot answer its identity block or its main data block really is
-- unreadable, and failing the poll is the honest outcome. The violation is
-- doing both -- claiming the device is fine while permanently costing a
-- failed read.
--
-- `tests/test_blueprint.py` holds the blueprint to the same property. This
-- applies it to the drivers that actually ship.
--
-- Usage: lua55 absent_register_probe.lua <root> <driver-path>
-- Prints one line per probed address:
--   ADDR <n> SETTLED <0|1> EMITTED <n> COUNTS a,b,c,...
-- or a single "SKIP <reason>" for a driver this cannot measure.

local root = arg[1]
local driver_path = arg[2]
package.path = root .. "/drivers/tests/lua_harness/?.lua;" .. package.path
require("host_mock")

local POLLS = 10
local CONFIG = {
    host = "127.0.0.1", port = 502, unit_id = 1, slave_id = 1,
    nominal_w = 10000, rated_w = 10000,
    url = "http://127.0.0.1", topic = "test", serial = "TEST123",
}

local function fill_registers()
    local regs = {}
    for addr = 0, 65535 do regs[addr] = 100 end
    -- SunSpec magic, so identity probes pass and the driver reaches its
    -- real register map instead of bailing at the front door.
    regs[40000] = 0x5375
    regs[40001] = 0x6e53
    host._modbus_registers.holding = regs
    host._modbus_registers.input = regs
end

local function clear_globals()
    driver_init, driver_poll, driver_cleanup = nil, nil, nil
    driver_command, driver_default_mode = nil, nil
    driver_command_v2, driver_default_mode_v2 = nil, nil
    DRIVER, PROTOCOL = nil, nil
end

-- Which addresses does this driver read when everything answers?
local function discover()
    host.reset()
    clear_globals()
    fill_registers()
    if not pcall(dofile, driver_path) then return nil, "load failed" end
    if PROTOCOL ~= "modbus" then return nil, "not modbus" end
    if type(driver_poll) ~= "function" then return nil, "no driver_poll" end
    if type(driver_init) == "function" then pcall(driver_init, CONFIG) end
    for _ = 1, 3 do pcall(driver_poll) end

    local seen, order = {}, {}
    for _, call in ipairs(host._calls) do
        if call.func == "modbus_read" and type(call.args[1]) == "number" then
            local addr = call.args[1]
            if not seen[addr] then
                seen[addr] = true
                order[#order + 1] = addr
            end
        end
    end
    return order
end

local addresses, why = discover()
if not addresses then
    print("SKIP " .. tostring(why))
    return
end
if #addresses == 0 then
    print("SKIP reads no registers")
    return
end

for _, addr in ipairs(addresses) do
    host.reset()
    clear_globals()
    fill_registers()
    host._modbus_read_fail_addresses[addr] = "Illegal Data Address"
    pcall(dofile, driver_path)
    if type(driver_init) == "function" then pcall(driver_init, CONFIG) end

    local counts = {}
    for _ = 1, POLLS do
        local before = #host._calls
        pcall(driver_poll)
        local failed = 0
        for i = before + 1, #host._calls do
            local call = host._calls[i]
            if call.func == "modbus_read"
               and host._modbus_read_fail_addresses[call.args[1]] then
                failed = failed + 1
            end
        end
        counts[#counts + 1] = failed
    end

    local settled = (counts[POLLS] == 0
        and counts[POLLS - 1] == 0 and counts[POLLS - 2] == 0) and 1 or 0

    -- Did the driver keep reporting telemetry while it kept failing? That is
    -- the combination that takes a working device offline: the driver decided
    -- it can live without the register, then went on paying for it anyway.
    local emitted = 0
    for _, kind in ipairs({"pv", "battery", "meter", "ev", "heatpump", "vehicle", "v2x_charger"}) do
        local e = host._emitted[kind]
        if e and #e > 0 then emitted = emitted + #e end
    end

    print(string.format("ADDR %d SETTLED %d EMITTED %d COUNTS %s",
        addr, settled, emitted, table.concat(counts, ",")))
end
