-- ABB Terra AC control: watts to amps, caps, pause and resume, default mode
-- and honest results. 0x4100 takes mA, high word first.
dofile("drivers/tests/lua_harness/host_mock.lua")
local driver = "drivers/lua/abb_terra.lua"

local H
local function set_u32(addr, v)
    H[addr], H[addr + 1] = v // 65536, v % 65536
end
local function set_state(code, below)
    H[0x400C], H[0x400D] = 0, (code + (below and 128 or 0)) * 256
end

-- A three-phase Terra AC with a car charging at 16 A.
local function device(opts)
    opts = opts or {}
    H = host._modbus_registers.holding
    H[0x4000], H[0x4001], H[0x4002], H[0x4003] = 0x5422, 0x0400, 0x4920, 0x0025
    set_u32(0x4006, opts.max_ma or 32000)
    set_u32(0x4008, opts.error or 0)
    set_u32(0x400A, 0x0111)
    set_state(opts.state or 4)
    set_u32(0x400E, opts.limit_ma or 16000)
    for i = 0, 2 do set_u32(0x4010 + 2 * i, opts.amps_ma or 16000) end
    for i = 0, 2 do set_u32(0x4016 + 2 * i, 2310) end
    set_u32(0x401C, opts.power or 11000)
    set_u32(0x401E, 4321)
end

local function boot(opts)
    host.reset()
    DRIVER, driver_command, driver_default_mode = nil, nil, nil
    dofile(driver)
    device(opts)
    driver_init({})
end

local function writes()
    local out = {}
    for _, c in ipairs(host._calls) do
        if c.func == "modbus_write_multiple" or c.func == "modbus_write" then
            assert(c.args[1] == 0x4100, "wrote register " .. tostring(c.args[1]))
            out[#out + 1] = (c.args[2][1] * 65536 + c.args[2][2]) / 1000
        end
    end
    return out
end
local function last() local w = writes(); return w[#w] end
local function count() return #writes() end
local function near(a, b) return a ~= nil and b ~= nil and math.abs(a - b) < 0.001 end
local function later(ms) host._millis_counter = host._millis_counter + ms end
local function order(w, cmd)
    return driver_command("ev_set_current", w,
        cmd or { phase_mode = "3p", voltage = 230, max_amps_per_phase = 25 })
end

-- 1. Watts to amps per phase, rounded down to 0.1 A, and the minimum.
boot({ state = 2, amps_ma = 0, power = 0 })
driver_poll()
assert(order(11040)); assert(near(last(), 16), "11040 W 3p is 16 A")
assert(order(7000)); assert(near(last(), 10.1), "7000 W 3p rounds down to 10.1 A")
assert(order(4140)); assert(near(last(), 6), "4140 W 3p is exactly 6 A")
assert(order(4000)); assert(near(last(), 0), "below 6 A must write 0, never round up")
assert(order(3680, { phase_mode = "1p", voltage = 230 })); assert(near(last(), 16))

-- 2. Caps: the fuse, Core's room, the charger's own ceiling.
assert(order(11040, { phase_mode = "3p", voltage = 230, max_amps_per_phase = 10 }))
assert(near(last(), 10), "max_amps_per_phase must cap")
assert(order(11040, { phase_mode = "3p", voltage = 230, max_amps_per_phase = 25, cap_amps_per_phase = 7.25 }))
assert(near(last(), 7.2), "cap_amps_per_phase must cap and round down")
boot({ state = 2, max_ma = 16000 })
driver_poll()
assert(order(50000)); assert(near(last(), 16), "never above the charger's own ceiling")

-- 3. Phases: a three-phase car on a 1p order is divided by three.
boot({ state = 4 })
driver_poll()
assert(order(7360, { phase_mode = "1p", voltage = 230 }))
assert(near(last(), 10.6), "seen phases must override a 1p order")

-- 4. Write only on change; a limit the charger lost is written again.
boot({ state = 4 })
driver_poll()
assert(order(11040)); assert(count() == 1)
for _ = 1, 5 do later(5000); driver_poll(); assert(order(11040)) end
assert(count() == 1, "same order rewritten without a change")
set_u32(0x400E, 32000); driver_poll()   -- charger restarted at its maximum
later(31000); assert(order(11040)); assert(count() == 2, "lost limit not rewritten")
set_u32(0x400E, 10000); driver_poll()   -- its own load balancing, lower
later(31000); assert(order(11040)); assert(count() == 2, "a lower charger limit is not ours to fight")
assert(order(6900)); assert(near(last(), 10), "decrease not applied at once")

-- 5. Pause and resume, through Core's contactor cycle.
boot({ state = 4 })
driver_poll()
assert(order(11040))
assert(driver_command("ev_pause", 0, {})); assert(near(last(), 0), "pause must write 0 A")
later(3000); local n = count()
assert(order(11040)); assert(count() == n, "an order inside the pause hold reopened the charger")
assert(driver_command("ev_resume", 0, {})); assert(near(last(), 16), "resume must restore the order")
assert(driver_command("ev_pause", 0, {}))
later(11000)
assert(order(11040)); assert(near(last(), 16), "a pause must not outlast the hold")

-- 6. Default mode: nothing unless FTW wrote; then 0 A once.
boot()
driver_poll()
assert(driver_default_mode()); assert(count() == 0, "default mode wrote on a site FTW never steered")
assert(order(11040))
assert(driver_default_mode()); assert(near(last(), 0), "default mode must write 0 A")
local settled = count()
for _ = 1, 5 do later(20000); assert(driver_default_mode()) end
assert(count() == settled, "default mode did not settle")

-- 7. Honest results.
boot()
driver_poll()
assert(order(11040))
host._modbus_write_error = "modbus exception function=0x10 code=0x02"
assert(order(6900) == false, "a refused write must return false")
local attempts = {}
for i = 1, 6 do
    local b = host._modbus_write_attempts
    driver_default_mode()
    attempts[i] = host._modbus_write_attempts - b
end
assert(table.concat(attempts, ",") == "1,1,1,0,0,0",
    "default mode must stop after three refusals, got " .. table.concat(attempts, ","))

-- 8. Readings: device values only; a failed read stays nil.
boot({ state = 4 })
driver_poll()
assert(host._sn == "5422040049200025", "serial: " .. tostring(host._sn))
local e = host._emitted.ev[#host._emitted.ev]
assert(e.w == 11000 and e.connected == true and e.charging == true)
assert(near(e.max_a, 16) and near(e.current_limit_a, 16) and e.session_wh == 4321)
assert(near(e.l1_v, 231) and near(e.l2_a, 16) and e.phases == 3)
set_state(2); driver_poll()
e = host._emitted.ev[#host._emitted.ev]
assert(e.connected == true and e.charging == false and e.request_active == false)
set_state(0); driver_poll()
e = host._emitted.ev[#host._emitted.ev]
assert(e.connected == false and e.phases == nil, "unplug must clear the phases")
set_state(5); set_u32(0x400A, 0x0101); driver_poll()
e = host._emitted.ev[#host._emitted.ev]
assert(e.connected == true, "state 'other' with the cable in the car is connected")
local emitted = #host._emitted.ev
host._modbus_read_fail_addresses[0x4006] = "timeout"
driver_poll()
assert(#host._emitted.ev == emitted, "emitted without a reading")

-- 9. Stalled: B1 (pending authorization) under our offer for 30 s.
boot({ state = 1, power = 0, amps_ma = 0 })
driver_poll()
assert(order(11040))
driver_poll(); later(31000); driver_poll()
e = host._emitted.ev[#host._emitted.ev]
assert(e.command_stalled == true, "B1 under a 16 A offer for 31 s must stall")
assert(e.reason_no_current_label == "pending authorization")

print("abb_terra control: ok")
