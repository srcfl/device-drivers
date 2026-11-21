-- KEBA P30: an order becomes 5004 (mA, function code 6) then 5014 = 1, per
-- phase, rounded down to 0.1 A, within every cap. Below 6 A and pause write
-- 5014 = 0. Default mode disables once and settles. A refused write returns
-- false. The failsafe timer is refreshed only while an order stands.
dofile("drivers/tests/lua_harness/host_mock.lua")
local DRIVER_PATH = "drivers/lua/keba.lua"

local function set_u32(addr, v)
    host._modbus_registers.holding[addr] = math.floor(v / 65536)
    host._modbus_registers.holding[addr + 1] = v % 65536
end

-- state: KEBA charging state; cable: cable state; ma: per-phase current;
-- offered: register 1100 in mA.
local function charger(state, cable, ma, offered, extra)
    set_u32(1000, state)
    set_u32(1004, cable)
    for i, addr in ipairs({ 1008, 1010, 1012 }) do set_u32(addr, ma[i] or 0) end
    for _, addr in ipairs({ 1040, 1042, 1044 }) do set_u32(addr, 230) end
    local total = 0
    for i = 1, 3 do total = total + (ma[i] or 0) * 230 end
    set_u32(1020, total)            -- mW: mA * V
    set_u32(1100, offered or 32000)
    set_u32(1110, (extra and extra.hw) or 32000)
    set_u32(1502, 12345)
    set_u32(1602, (extra and extra.failsafe) or 0)
end

local function boot(product)
    host.reset()
    driver_init, driver_poll, driver_command, driver_default_mode = nil, nil, nil, nil
    dofile(DRIVER_PATH)
    driver_init({})
    set_u32(1016, product or 304111)
    set_u32(1014, 18416854)
    charger(2, 7, {}, 32000)
    driver_poll()
end

local function writes(addr)
    local out = {}
    for _, call in ipairs(host._calls) do
        if call.func == "modbus_write" and (addr == nil or call.args[1] == addr) then
            table.insert(out, addr and call.args[2] or (call.args[1] .. "=" .. call.args[2]))
        end
    end
    return out
end
local function last(addr) local w = writes(addr); return w[#w] end
local function later(ms) host._millis_counter = host._millis_counter + ms end
local THREE = { phase_mode = "3p", voltage = 230, max_amps_per_phase = 25 }
local ONE = { phase_mode = "1p", voltage = 230, max_amps_per_phase = 25 }
local function order(w, cmd) return driver_command("ev_set_current", w, cmd or THREE) end

-- 1. Current first, then enable. Three phases and one.
boot()
assert(order(11040))
assert(table.concat(writes(), ",") == "5004=16000,5014=1", "writes were " .. table.concat(writes(), ","))
boot()
assert(order(3680, ONE)); assert(last(5004) == 16000, "3680 W on 1p is not 16 A")

-- 2. Round down to 0.1 A, never up.
boot()
assert(order(4500)); assert(last(5004) == 6500, "4500 W did not round down to 6.5 A")

-- 3. Below 6 A disables; 5004 takes nothing under 6000 mA.
boot()
assert(order(4000))
assert(table.concat(writes(), ",") == "5014=0", "below 6 A wrote " .. table.concat(writes(), ","))

-- 4. A one-phase order on a car that draws on three phases is split over three.
boot()
charger(3, 7, { 10000, 10000, 10000 }, 10000)
driver_poll()
assert(order(7000, ONE)); assert(last(5004) == 10100, "measured phases were ignored")

-- 5. Caps: Core's max and cap per phase, and the charger's hardware limit.
boot()
assert(order(22000, { phase_mode = "3p", voltage = 230, max_amps_per_phase = 10 }))
assert(last(5004) == 10000, "max_amps_per_phase was exceeded")
assert(order(22000, { phase_mode = "3p", voltage = 230, max_amps_per_phase = 25, cap_amps_per_phase = 8 }))
assert(last(5004) == 8000, "cap_amps_per_phase was exceeded")
assert(order(1e12)); assert(last(5004) == 25000, "a huge order passed the fuse")
boot()
charger(2, 7, {}, 13000, { hw = 13000 })
driver_poll()
assert(order(11040)); assert(last(5004) == 13000, "the charger's hardware limit was exceeded")

-- 6. Write only on change; a decrease lands at once.
boot()
assert(order(11040)); assert(order(11040))
assert(#writes() == 2, "an unchanged order was written again")
assert(order(5520)); assert(last(5004) == 8000, "a decrease was not written at once")
assert(#writes() == 3)

-- 7. Pause disables, resume enables at the same current.
boot()
assert(order(11040))
assert(driver_command("ev_pause", 0, {})); assert(last(5014) == 0, "pause did not disable")
assert(driver_command("ev_resume", 0, {})); assert(last(5014) == 1, "resume did not enable")
assert(#writes(5004) == 1, "resume rewrote an unchanged current")
boot()
assert(driver_command("ev_start", 0, {}))
assert(table.concat(writes(), ",") == "5004=6000,5014=1", "start without an order is not 6 A")

-- 8. Default mode disables once, then writes nothing.
boot()
assert(order(11040))
assert(driver_default_mode() == true); assert(last(5014) == 0, "default mode did not disable")
local before = #writes()
for _ = 1, 5 do assert(driver_default_mode() == true) end
assert(#writes() == before, "default mode kept writing")

-- 9. A refused write returns false, and the next order tries again.
boot()
host._modbus_write_error = "modbus exception function=0x06 code=0x02"
assert(order(11040) == false, "a refused write returned true")
host._modbus_write_error = nil
assert(order(11040)); assert(last(5004) == 16000 and last(5014) == 1, "the order was not retried")
-- A refused enable fails the order too.
boot()
host._modbus_write_fail_at = 2
assert(order(11040) == false, "a refused enable returned true")

-- 10. A charger that refuses the stand-down and never took an enable is left
-- alone after three tries. One that took an enable keeps being asked.
boot()
host._modbus_write_error = "modbus exception function=0x06 code=0x02"
local counts = {}
for i = 1, 6 do
    local n = #writes()
    local result = driver_default_mode()
    counts[i] = #writes() - n
    assert(result == (i > 3), "default mode result " .. tostring(result) .. " on call " .. i)
end
assert(table.concat(counts, ",") == "1,1,1,0,0,0", "default mode did not settle: " .. table.concat(counts, ","))
boot()
assert(order(11040))
host._modbus_write_error = "modbus exception function=0x06 code=0x02"
for _ = 1, 5 do assert(driver_default_mode() == false) end
assert(#writes(5014) == 6, "gave up disabling a charger this driver enabled")

-- 11. Not a P30: no control, no writes.
boot(4000110)
assert(order(11040) == false, "controlled a charger that is not a P30")
assert(driver_default_mode() == true)
assert(#writes() == 0, "wrote to a charger that is not a P30")

-- 12. A charger that offers more than the order, or charges while disabled,
-- has lost it: the next order writes it again, once the order could land.
boot()
assert(order(11040))
charger(3, 7, { 16000, 16000, 16000 }, 32000)
driver_poll()
assert(order(11040)); assert(#writes(5004) == 1, "rewrote before the order could land")
later(31000)
driver_poll()
assert(order(11040)); assert(#writes(5004) == 2, "a lost current was not written again")
boot()
assert(order(4000))
charger(3, 7, { 16000, 16000, 16000 }, 16000)
later(31000)
driver_poll()
assert(order(4000)); assert(#writes(5014) == 2, "charging while disabled was not disabled again")

-- 13. The failsafe timer is refreshed at half its timeout while an order
-- stands, and not after the stand-down.
boot()
charger(2, 7, {}, 32000, { failsafe = 20 })
assert(order(11040))
driver_poll(); assert(#writes(5018) == 1 and last(5018) == 20, "failsafe was not refreshed")
later(4000); driver_poll(); assert(#writes(5018) == 1, "failsafe refreshed too often")
later(7000); driver_poll(); assert(#writes(5018) == 2, "failsafe refresh stopped")
assert(driver_default_mode())
later(11000); driver_poll(); assert(#writes(5018) == 2, "failsafe refreshed after the stand-down")

-- 14. Telemetry: power in W, session energy, state, the charger's offer.
boot()
charger(3, 7, { 16000, 16000, 16000 }, 16000)
driver_poll()
local ev = host._emitted.ev[#host._emitted.ev]
assert(math.abs(ev.w - 11040) < 1, "power is not in W")
assert(ev.connected == true and ev.charging == true and ev.phases == 3)
assert(ev.max_a == 16 and ev.session_wh == 1234.5)
charger(5, 7, {}, 16000)
driver_poll()
ev = host._emitted.ev[#host._emitted.ev]
assert(ev.charging == false and ev.reason_no_current_label == "suspended")
host._modbus_read_error = "timeout"
local count = #host._emitted.ev
driver_poll()
assert(#host._emitted.ev == count, "a failed read was reported")

print("keba control: ok")
