-- KEBA P30: an order becomes 5004 (mA, function code 6) then 5014 = 1, per
-- phase, rounded down to 0.1 A, within every cap. Below 6 A and pause write
-- 5014 = 0; resume writes a fresh order back, or only 6 A when the order is
-- old. Default mode acts only after FTW wrote, returns true only once the
-- stand-down lands, and retries a refused one at most once a minute. A
-- refused write returns false. The failsafe timer is refreshed while FTW
-- steers.
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

local function boot(product, config)
    host.reset()
    driver_init, driver_poll, driver_command, driver_default_mode = nil, nil, nil, nil
    dofile(DRIVER_PATH)
    driver_init(config or {})
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

-- 1. Current first, then enable.
boot()
assert(order(11040))
assert(table.concat(writes(), ",") == "5004=16000,5014=1", "writes were " .. table.concat(writes(), ","))

-- 2. Round down to 0.1 A, never up.
boot()
assert(order(4500)); assert(last(5004) == 6500, "4500 W did not round down to 6.5 A")

-- 3. Below 6 A disables; 5004 takes nothing under 6000 mA.
boot()
assert(order(4000))
assert(table.concat(writes(), ",") == "5014=0", "below 6 A wrote " .. table.concat(writes(), ","))

-- 4. One phase only when it is certain. A 1p order on an idle three-phase
-- installation gives P/(3*V), so a three-phase car never gets the L1 sum.
boot()
assert(order(7000, ONE)); assert(last(5004) == 10100, "an idle 1p order was not split over three")
-- ...and on a car that draws on three phases.
boot()
charger(3, 7, { 10000, 10000, 10000 }, 10000)
driver_poll()
assert(order(7000, ONE)); assert(last(5004) == 10100, "measured phases were ignored")
-- A 1p order on a car that draws on exactly one phase gives P/V.
boot()
charger(3, 7, { 10000, 0, 0 }, 10000)
driver_poll()
assert(order(3680, ONE)); assert(last(5004) == 16000, "a one-phase car did not get P/V")
-- A car once seen on three phases stays three until it is unplugged.
boot()
charger(3, 7, { 10000, 10000, 10000 }, 10000)
driver_poll()
charger(3, 7, { 10000, 0, 0 }, 10000)
driver_poll()
assert(order(7000, ONE)); assert(last(5004) == 10100, "a three-phase car got P/V")
charger(1, 0, {}, 10000)
driver_poll()
charger(3, 7, { 10000, 0, 0 }, 10000)
driver_poll()
assert(order(3680, ONE)); assert(last(5004) == 16000, "unplugging did not forget the old car")
-- A one-phase installation (config) gives P/V, idle or not, unless the car
-- draws on more than one phase.
boot(nil, { phases = 1 })
assert(order(3680)); assert(last(5004) == 16000, "phases: 1 was ignored")
charger(3, 7, { 10000, 10000, 10000 }, 10000)
driver_poll()
assert(order(7000)); assert(last(5004) == 10100, "phases: 1 overrode three measured phases")

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
-- Resume carries no budget. With no order and no limit on record, after a
-- reload for example, nothing is written and the start is accepted: Core's
-- next order sets the level. The wait is logged once.
boot()
assert(driver_command("ev_start", 0, {}) == true, "a start with no known limit was refused")
assert(driver_command("ev_resume", 0, {}) == true)
assert(#writes() == 0, "start without an order wrote")
local waits = 0
for _, line in ipairs(host._logs) do
    if line:find("waits for Core's next order", 1, true) then waits = waits + 1 end
end
assert(waits == 1, "the wait was logged " .. waits .. " times")
-- An order an hour old is not trusted: 5004 = 6000 mA first, then enable.
boot()
assert(order(11040))
assert(driver_command("ev_pause", 0, {}))
later(3600000)
local resumed_before = #writes()
assert(driver_command("ev_resume", 0, {}))
local resumed = {}
for i = resumed_before + 1, #writes() do resumed[#resumed + 1] = writes()[i] end
assert(table.concat(resumed, ",") == "5004=6000,5014=1", "an old order resumed as " .. table.concat(resumed, ","))
-- ...and nothing when the last positive order left no room for 6 A. A later
-- 0 W order names only the site maximum and must not replace that cap.
boot()
assert(order(11040, { phase_mode = "3p", voltage = 230, max_amps_per_phase = 25, cap_amps_per_phase = 4 }))
assert(order(0, { phase_mode = "3p", voltage = 230, max_amps_per_phase = 25 }))
later(3600000)
resumed_before = #writes()
assert(driver_command("ev_resume", 0, {}) == false)
assert(#writes() == resumed_before, "resumed without room for 6 A")

-- 8. Core runs default mode at every start: a charger FTW never wrote to in
-- this run is left alone, and a charge already running goes on.
boot()
charger(3, 7, { 16000, 16000, 16000 }, 16000)
driver_poll()
for _ = 1, 3 do assert(driver_default_mode() == true) end
assert(#writes() == 0, "default mode wrote to a charger FTW never steered")
-- Once FTW wrote, default mode disables once, then writes nothing.
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

-- 10. Once FTW wrote, a refused stand-down returns false. It is tried again
-- at most once a minute, with no write in between, and true only once it
-- lands.
boot()
assert(order(11040))
host._modbus_write_error = "modbus exception function=0x06 code=0x02"
local function default_writes()
    local n = #writes()
    local result = driver_default_mode()
    return #writes() - n, result
end
local counts = {}
for i = 1, 4 do
    local count, result = default_writes()
    counts[i] = count
    assert(result == false, "a refused stand-down returned " .. tostring(result))
end
assert(table.concat(counts, ",") == "1,0,0,0", "stand-down retried too often: " .. table.concat(counts, ","))
later(61000)
local count, result = default_writes()
assert(count == 1 and result == false, "the stand-down was not retried after a minute")
host._modbus_write_error = nil
later(61000)
count, result = default_writes()
assert(count == 1 and result == true and last(5014) == 0, "a landed stand-down was not confirmed")
count, result = default_writes()
assert(count == 0 and result == true, "a confirmed stand-down was written again")

-- 10b. A charger that stays suspended against an enable for 30 s gets the
-- enable again on the next order, at most every 30 s.
boot()
assert(order(11040))
charger(5, 7, {}, 16000)
driver_poll()
later(31000)
driver_poll()
assert(host._emitted.ev[#host._emitted.ev].command_stalled == true, "a stalled enable was not reported")
assert(order(11040)); assert(#writes(5014) == 2, "a stalled enable was not written again")
later(5000)
driver_poll()
assert(order(11040)); assert(#writes(5014) == 2, "a stalled enable was written again too soon")

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

-- 13. The failsafe timer is refreshed at half its timeout while FTW steers,
-- paused or not, and while FTW holds the charger disabled. After three
-- refusals it is tried once a minute, and the count starts over after a
-- success.
boot()
charger(2, 7, {}, 32000, { failsafe = 20 })
assert(order(11040))
driver_poll(); assert(#writes(5018) == 1 and last(5018) == 20, "failsafe was not refreshed")
later(4000); driver_poll(); assert(#writes(5018) == 1, "failsafe refreshed too often")
later(7000); driver_poll(); assert(#writes(5018) == 2, "failsafe refresh stopped")
assert(driver_command("ev_pause", 0, {}))
later(11000); driver_poll(); assert(#writes(5018) == 3, "failsafe refresh stopped during a pause")
host._modbus_write_error = "modbus exception function=0x06 code=0x02"
for n = 4, 6 do
    later(11000); driver_poll(); assert(#writes(5018) == n, "a refused refresh was not retried")
end
later(11000); driver_poll(); assert(#writes(5018) == 6, "no back-off after three refusals")
later(50000); driver_poll(); assert(#writes(5018) == 7, "the refresh did not retry after a minute")
host._modbus_write_error = nil
later(61000); driver_poll(); assert(#writes(5018) == 8, "the refresh did not retry after a minute")
later(11000); driver_poll(); assert(#writes(5018) == 9, "a success did not reset the back-off")
-- While FTW holds the charger disabled after a stand-down, the refresh goes
-- on, so a failsafe current cannot start a charge FTW stopped.
assert(driver_default_mode() == true)
later(11000); driver_poll(); assert(#writes(5018) == 10, "failsafe refresh stopped while FTW holds the charger disabled")

-- 13b. With L2 or L3 unreadable the phase count is unknown: a 1p order is
-- divided by three. The lost registers are tried again once a minute.
boot()
charger(3, 7, { 10000, 0, 0 }, 10000)
host._modbus_read_fail_addresses[1010] = "timeout"
host._modbus_read_fail_addresses[1012] = "timeout"
for _ = 1, 4 do driver_poll() end
assert(order(7000, ONE)); assert(last(5004) == 10100, "an unknown phase count was not treated as three")
local function reads(addr)
    local n = 0
    for _, call in ipairs(host._calls) do
        if call.func == "modbus_read" and call.args[1] == addr then n = n + 1 end
    end
    return n
end
local tries = reads(1010)
driver_poll(); assert(reads(1010) == tries, "a lost phase current was read on every poll")
host._modbus_read_fail_addresses[1010] = nil
host._modbus_read_fail_addresses[1012] = nil
later(61000)
driver_poll(); assert(reads(1010) == tries + 1, "a lost phase current was not tried again")
assert(order(3680, ONE)); assert(last(5004) == 16000, "a one-phase car did not get P/V once all three answered")

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
