-- Etrel INCH: an order becomes a Float32 current setpoint at holding 8, per
-- phase, rounded down, within every cap. Pause writes 0 A and resume brings the
-- order back. Default mode stands down once and settles. A refused write
-- returns false.
dofile("drivers/tests/lua_harness/host_mock.lua")
local DRIVER_PATH = "drivers/lua/etrel.lua"

-- Test data encoder, checked against the mock's own decoder below.
local function enc(v)
    if v == 0 then return 0, 0 end
    local e, m = 0, v
    while m >= 2 do m = m / 2; e = e + 1 end
    while m < 1 do m = m * 2; e = e - 1 end
    local f = math.floor((m - 1) * 0x800000 + 0.5)
    return (e + 127) * 128 + math.floor(f / 65536), f % 65536
end
for _, v in ipairs({ 0.5, 6, 16, 230, 7.36 }) do
    local hi, lo = enc(v)
    assert(math.abs(host.decode_f32_be(hi, lo) - v) < 1e-3, "test encoder is wrong for " .. v)
end

local function set_f32(addr, v)
    local hi, lo = enc(v)
    host._modbus_registers.input[addr] = hi
    host._modbus_registers.input[addr + 1] = lo
end

-- status: Etrel connector status; amps: per-phase current; kw: total power;
-- target: the current the charger lets the car take.
local function charger(status, amps, kw, target)
    host._modbus_registers.input[0] = status
    for i = 1, 3 do set_f32(8 + 2 * (i - 1), 230) end
    for i = 1, 3 do set_f32(14 + 2 * (i - 1), amps[i] or 0) end
    set_f32(26, kw or 0)
    set_f32(4, target or 0)
end

local function boot()
    host.reset()
    driver_init, driver_poll, driver_command, driver_default_mode = nil, nil, nil, nil
    dofile(DRIVER_PATH)
    driver_init({})
    charger(3, {}, 0, 32)
    driver_poll()
end

local function setpoint_writes()
    local out = {}
    for _, call in ipairs(host._calls) do
        if call.func == "modbus_write_multiple" then
            assert(call.args[1] == 8, "wrote holding " .. tostring(call.args[1]))
            local v = call.args[2]
            table.insert(out, host.decode_f32_be(v[1], v[2]))
        end
    end
    return out
end
local function last_setpoint() local w = setpoint_writes(); return w[#w] end
local function near(a, b) return a ~= nil and math.abs(a - b) < 0.01 end
local function later(ms) host._millis_counter = host._millis_counter + ms end
local THREE = { phase_mode = "3p", voltage = 230, max_amps_per_phase = 25 }
local ONE = { phase_mode = "1p", voltage = 230, max_amps_per_phase = 25 }
local function order(w, cmd) return driver_command("ev_set_current", w, cmd or THREE) end

-- 1. Power to amps per phase, three phases and one.
boot()
assert(order(11040)); assert(near(last_setpoint(), 16), "11040 W on 3p is not 16 A")
boot()
assert(order(3680, ONE)); assert(near(last_setpoint(), 16), "3680 W on 1p is not 16 A")

-- 2. Round down to 0.1 A, never up.
boot()
assert(order(4500)); assert(near(last_setpoint(), 6.5), "4500 W did not round down to 6.5 A")

-- 3. Below 6 A gives 0 A, not 6 A.
boot()
assert(order(4000)); assert(near(last_setpoint(), 0), "5.8 A was not written as 0 A")

-- 4. A one-phase order on a car that draws on three phases is split over three.
boot()
charger(4, { 10, 10, 10 }, 6.9, 10)
driver_poll()
assert(order(7000, ONE)); assert(near(last_setpoint(), 10.1), "measured phases were ignored")

-- 5. Caps: Core's max and cap per phase, and the charger's own limit.
boot()
assert(order(22000, { phase_mode = "3p", voltage = 230, max_amps_per_phase = 10 }))
assert(near(last_setpoint(), 10), "max_amps_per_phase was exceeded")
assert(order(22000, { phase_mode = "3p", voltage = 230, max_amps_per_phase = 25, cap_amps_per_phase = 8 }))
assert(near(last_setpoint(), 8), "cap_amps_per_phase was exceeded")
assert(order(1e12)); assert(near(last_setpoint(), 25), "a huge order passed the fuse")
assert(order(0 / 0)); assert(near(last_setpoint(), 0), "NaN did not give 0 A")
host.reset()
dofile(DRIVER_PATH)
driver_init({})
set_f32(1028, 13)
charger(3, {}, 0, 13)
driver_poll()
assert(order(11040)); assert(near(last_setpoint(), 13), "the charger's custom max current was exceeded")

-- 6. Write only on change; a decrease lands at once.
boot()
assert(order(11040)); assert(order(11040))
assert(#setpoint_writes() == 1, "an unchanged order was written again")
assert(order(5520)); assert(near(last_setpoint(), 8), "a decrease was not written at once")
assert(#setpoint_writes() == 2)

-- 7. Pause writes 0 A, resume brings the order back.
boot()
assert(order(11040))
assert(driver_command("ev_pause", 0, {})); assert(near(last_setpoint(), 0), "pause did not write 0 A")
assert(driver_command("ev_resume", 0, {})); assert(near(last_setpoint(), 16), "resume lost the order")
-- Resume with no order on record starts at the minimum.
boot()
assert(driver_command("ev_start", 0, {})); assert(near(last_setpoint(), 6), "start without an order is not 6 A")

-- 8. Default mode stands down once, then writes nothing.
boot()
assert(order(11040))
assert(driver_default_mode() == true); assert(near(last_setpoint(), 0), "default mode did not write 0 A")
local before = #setpoint_writes()
for _ = 1, 5 do assert(driver_default_mode() == true) end
assert(#setpoint_writes() == before, "default mode kept writing")

-- 9. A refused write returns false, and the next order tries again.
boot()
host._modbus_write_error = "modbus exception function=0x10 code=0x0c"
assert(order(11040) == false, "a refused write returned true")
host._modbus_write_error = nil
assert(order(11040)); assert(near(last_setpoint(), 16), "the order was not retried")

-- 10. A charger that refuses the stand-down and never took an order is left
-- alone after three tries. One that took an order keeps being asked.
boot()
host._modbus_write_error = "modbus exception function=0x10 code=0x02"
local writes = {}
for i = 1, 6 do
    local n = #host._calls
    local result = driver_default_mode()
    local count = 0
    for j = n + 1, #host._calls do
        if host._calls[j].func == "modbus_write_multiple" then count = count + 1 end
    end
    writes[i] = count
    assert(result == (i > 3), "default mode result " .. tostring(result) .. " on call " .. i)
end
assert(table.concat(writes, ",") == "1,1,1,0,0,0", "default mode did not settle: " .. table.concat(writes, ","))
boot()
assert(order(11040))
host._modbus_write_error = "modbus exception function=0x10 code=0x02"
for _ = 1, 5 do assert(driver_default_mode() == false) end
local tries = 0
for _, call in ipairs(host._calls) do
    if call.func == "modbus_write_multiple" then tries = tries + 1 end
end
assert(tries == 6, "gave up standing down a charger that holds 16 A")

-- 11. A charger that allows more than the order has lost it: the next order
-- writes it again, once the order has had time to land.
boot()
assert(order(11040))
charger(4, { 16, 16, 16 }, 11, 32)
driver_poll()
assert(order(11040)); assert(#setpoint_writes() == 1, "rewrote before the order could land")
later(31000)
driver_poll()
assert(order(11040)); assert(#setpoint_writes() == 2, "a lost order was not written again")

-- 12. Telemetry: power in W, state, the charger's own offer.
boot()
charger(4, { 16, 16, 15.9 }, 11.04, 16)
driver_poll()
local ev = host._emitted.ev[#host._emitted.ev]
assert(math.abs(ev.w - 11040) < 1, "power is not in W")
assert(ev.connected == true and ev.charging == true)
assert(near(ev.max_a, 16) and ev.phases == 3)
charger(5, {}, 0, 16)
driver_poll()
ev = host._emitted.ev[#host._emitted.ev]
assert(ev.charging == false and ev.request_active == false and ev.reason_no_current_label == "paused_by_vehicle")
host._modbus_read_error = "timeout"
local count = #host._emitted.ev
driver_poll()
assert(#host._emitted.ev == count, "a failed read was reported")

print("etrel control: ok")
