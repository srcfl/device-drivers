-- Schrack i-CHARGE CION: an order becomes 101 (whole A) then 100 = 1, per
-- phase, rounded down, within every cap. Below 6 A and pause write 100 = 0.
-- A void authorisation is cleared with 0 before 1. Default mode withdraws the
-- authorisation once and settles. A refused write returns false.
dofile("drivers/tests/lua_harness/host_mock.lua")
local DRIVER_PATH = "drivers/lua/schrack_ev.lua"

local CP_A, CP_B, CP_C = 65, 66, 67

-- cp: CP state; auth/current: registers 100/101; offered: 126; max: 127;
-- cable: 128; void: 120; bits: 121.
local function charger(s)
    local h = host._modbus_registers.holding
    h[100] = s.auth or 0
    h[101] = s.current or 16
    h[120] = s.void or 0
    h[121] = s.bits or 0
    h[126] = s.offered or 0
    h[127] = s.max or 32
    h[128] = s.cable or 32
    h[139] = s.cp or CP_B
    h[150] = s.error or 0
end

local function boot(config)
    host.reset()
    driver_init, driver_poll, driver_command, driver_default_mode = nil, nil, nil, nil
    dofile(DRIVER_PATH)
    driver_init(config or {})
    charger({ cp = CP_B })
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

-- 1. Current first, then authorise.
boot()
assert(order(11040))
assert(table.concat(writes(), ",") == "101=16,100=1", "writes were " .. table.concat(writes(), ","))

-- 2. Whole amperes, rounded down, never up.
boot()
assert(order(4500)); assert(last(101) == 6, "4500 W did not round down to 6 A")

-- 3. Below 6 A withdraws the authorisation.
boot()
assert(order(4000))
assert(table.concat(writes(), ",") == "100=0", "below 6 A wrote " .. table.concat(writes(), ","))

-- 4. The charger measures no phases, so only config decides. A 1p order on
-- an idle three-phase installation gives P/(3*V).
boot()
assert(order(7000, ONE)); assert(last(101) == 10, "an idle 1p order was not split over three")
assert(order(3680, ONE)); assert(last(100) == 0, "a 1p order reached 16 A on a three-phase installation")
boot({ phases = 1 })
assert(order(3680, ONE)); assert(last(101) == 16, "phases: 1 was ignored")
-- On a one-phase installation every order is one phase, within the fuse.
assert(order(11040)); assert(last(101) == 25, "phases: 1 did not decide a 3p order")

-- 5. Caps: Core's max and cap per phase, the charger's maximum and the cable.
boot()
assert(order(22000, { phase_mode = "3p", voltage = 230, max_amps_per_phase = 10 }))
assert(last(101) == 10, "max_amps_per_phase was exceeded")
assert(order(22000, { phase_mode = "3p", voltage = 230, max_amps_per_phase = 25, cap_amps_per_phase = 8 }))
assert(last(101) == 8, "cap_amps_per_phase was exceeded")
assert(order(1e12)); assert(last(101) == 25, "a huge order passed the fuse")
boot()
charger({ cp = CP_B, max = 13 })
driver_poll()
assert(order(11040)); assert(last(101) == 13, "the charger's maximum was exceeded")
boot()
charger({ cp = CP_B, max = 32, cable = 13 })
driver_poll()
assert(order(11040)); assert(last(101) == 13, "the cable's capacity was exceeded")

-- 6. Write only on change; a decrease lands at once.
boot()
assert(order(11040)); assert(order(11040))
assert(#writes() == 2, "an unchanged order was written again")
assert(order(5520)); assert(last(101) == 8, "a decrease was not written at once")
assert(#writes() == 3)

-- 7. With no car, the current is set but authorisation waits for the car.
boot()
charger({ cp = CP_A })
driver_poll()
assert(order(11040))
assert(table.concat(writes(), ",") == "101=16", "authorised with no car: " .. table.concat(writes(), ","))
charger({ cp = CP_B, current = 16 })
driver_poll()
assert(order(11040)); assert(last(100) == 1, "did not authorise once the car arrived")

-- 8. A void authorisation is cleared with 0 before 1.
boot()
charger({ cp = CP_B, void = 1 })
driver_poll()
assert(order(11040))
assert(table.concat(writes(), ",") == "101=16,100=0,100=1", "void not cleared: " .. table.concat(writes(), ","))

-- 9. Pause withdraws the authorisation, resume gives it back.
boot()
assert(order(11040))
assert(driver_command("ev_pause", 0, {})); assert(last(100) == 0, "pause did not withdraw")
assert(driver_command("ev_resume", 0, {})); assert(last(100) == 1, "resume did not authorise")
assert(#writes(101) == 1, "resume rewrote an unchanged current")

-- 10. Core runs default mode at every start: a charger FTW never wrote to in
-- this run is left alone, and a charge already running goes on.
boot()
charger({ cp = CP_C, auth = 1, current = 16, bits = 3, offered = 16 })
driver_poll()
for _ = 1, 3 do assert(driver_default_mode() == true) end
assert(#writes() == 0, "default mode wrote to a charger FTW never steered")
-- Once FTW wrote, default mode withdraws once, then writes nothing.
boot()
assert(order(11040))
assert(driver_default_mode() == true); assert(last(100) == 0, "default mode did not withdraw")
local before = #writes()
for _ = 1, 5 do assert(driver_default_mode() == true) end
assert(#writes() == before, "default mode kept writing")

-- 11. A refused write returns false, and the next order tries again.
boot()
host._modbus_write_error = "modbus exception function=0x06 code=0x02"
assert(order(11040) == false, "a refused write returned true")
host._modbus_write_error = nil
assert(order(11040)); assert(last(101) == 16 and last(100) == 1, "the order was not retried")

-- 12. A charger that refuses the stand-down and never took an authorisation
-- is left alone after three tries. One that took one keeps being asked.
boot()
host._modbus_write_error = "modbus exception function=0x06 code=0x02"
assert(order(4000) == false)
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
assert(#writes(100) == 6, "gave up withdrawing an authorisation this driver gave")

-- 13. A charger that no longer holds the order is written again once the
-- order could land.
boot()
assert(order(11040))
charger({ cp = CP_C, auth = 1, current = 32, bits = 3, offered = 32 })
driver_poll()
assert(order(11040)); assert(#writes(101) == 1, "rewrote before the order could land")
later(11000)
driver_poll()
assert(order(11040)); assert(#writes(101) == 2, "a lost current was not written again")

-- 14. Telemetry: state, the charger's offer, no invented power.
boot()
charger({ cp = CP_C, auth = 1, current = 16, bits = 3, offered = 16 })
driver_poll()
local ev = host._emitted.ev[#host._emitted.ev]
assert(ev.connected == true and ev.charging == true and ev.max_a == 16)
assert(ev.w == nil and ev.session_wh == nil, "reported power the charger does not measure")
charger({ cp = CP_B, auth = 0 })
driver_poll()
ev = host._emitted.ev[#host._emitted.ev]
assert(ev.charging == false and ev.reason_no_current_label == "not_authorised")
host._modbus_read_error = "timeout"
local count = #host._emitted.ev
driver_poll()
assert(#host._emitted.ev == count, "a failed read was reported")

print("schrack_ev control: ok")
