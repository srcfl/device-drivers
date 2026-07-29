-- For one driver, refuse every write the device is asked to take, then call
-- the safe-default path over and over and watch what the driver does about it.
--
-- The rule being measured: a driver whose device refuses a write must stop
-- making that write unprompted.
--
-- driver_default_mode is the path that runs on a timer. FTW reaches it through
-- Registry.SendDefault on lease expiry, the telemetry watchdog, the
-- stale-site-meter standdown and shutdown -- never from a command, and never
-- with anything to say no to it. A driver that writes there whatever the
-- device answers keeps writing for the life of the session.
--
-- A Sungrow SG12RT is the worked example. Its EMS registers do not exist, so
-- every write came back "modbus exception function=0x06", and the driver
-- reissued three of them on every watchdog tick and logged a warn line each
-- time. Fixed in sungrow 1.5.7 by counting refusals: three prove the block is
-- absent, and the unprompted paths stop. See the entry in CHANGELOG.md.
--
-- driver_init and driver_cleanup write once per process, so they cannot flap
-- and are not measured. A command cannot flap either -- something asked for
-- it, and refusing to try is its own failure.
--
-- What is NOT a violation: a driver that never writes here, and a driver that
-- stops. Returning false while it is still trying is honest and is left to the
-- caller to read; this measures the writes, not the verdict.
--
-- Usage: lua55 refused_write_probe.lua <root> <driver-path>
-- Prints one line:
--   DEFAULT_MODE SETTLED <0|1> WRITES a,b,c,... RETURNED x,y,z,...
-- or a single "SKIP <reason>" for a driver this cannot measure.

local root = arg[1]
local driver_path = arg[2]
package.path = root .. "/drivers/tests/lua_harness/?.lua;" .. package.path
require("host_mock")

-- Enough calls that a driver bounded at three attempts is clearly settled and
-- one that never settles is clearly not.
local CALLS = 8

-- What a device says when the register is not implemented. The exact string
-- does not matter to the driver -- any non-empty return from host.modbus_write
-- is an error -- but it matters to whoever reads a failure here and goes
-- looking for the same words in a gateway log.
local REFUSAL = "modbus exception function=0x06 code=0x02"

local CONFIG = {
    host = "127.0.0.1", port = 502, unit_id = 1, slave_id = 1,
    nominal_w = 10000, rated_w = 10000,
    url = "http://127.0.0.1", topic = "test", serial = "TEST123",
}

local function fill_registers()
    local regs = {}
    for addr = 0, 65535 do regs[addr] = 100 end
    -- SunSpec magic, so identity probes pass and the driver reaches its real
    -- register map instead of bailing at the front door.
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

local function count_writes(from)
    local n = 0
    for i = from + 1, #host._calls do
        local func = host._calls[i].func
        if func == "modbus_write" or func == "modbus_write_multiple" then
            n = n + 1
        end
    end
    return n
end

host.reset()
clear_globals()
fill_registers()

if not pcall(dofile, driver_path) then print("SKIP load failed") return end
if PROTOCOL ~= "modbus" then print("SKIP not modbus") return end
if type(driver_default_mode) ~= "function" then
    print("SKIP no driver_default_mode")
    return
end

-- Let the driver reach the state it would really be in: initialised, and
-- polled often enough to have classified the device and settled its reads.
-- Writes answer normally here, so a driver that checks a readback at startup
-- gets the answer it expects.
if type(driver_init) == "function" then pcall(driver_init, CONFIG) end
if type(driver_poll) == "function" then
    for _ = 1, 3 do pcall(driver_poll) end
end

-- From here the device refuses everything it is asked to write.
host._modbus_write_error = REFUSAL

local writes, returned = {}, {}
for _ = 1, CALLS do
    local before = #host._calls
    local ok, result = pcall(driver_default_mode)
    writes[#writes + 1] = count_writes(before)
    if not ok then
        returned[#returned + 1] = "error"
    else
        returned[#returned + 1] = tostring(result)
    end
end

-- Settled means it stopped writing. The last call is what the gateway is
-- still paying for an hour later, so that is the one that decides.
local settled = writes[#writes] == 0 and 1 or 0

print(string.format("DEFAULT_MODE SETTLED %d WRITES %s RETURNED %s",
    settled,
    table.concat(writes, ","),
    table.concat(returned, ",")))
