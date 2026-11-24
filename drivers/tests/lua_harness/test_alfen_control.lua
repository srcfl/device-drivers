-- Alfen control: watts to amps, caps, pause and resume, the validity-time
-- refresh, default mode and honest results.
dofile("drivers/tests/lua_harness/host_mock.lua")
local driver = "drivers/lua/alfen.lua"

-- FLOAT32 and FLOAT64 words from string.pack, so the test does not share
-- the driver's own encoder.
local function f32_words(x)
    local b1, b2, b3, b4 = string.pack(">f", x):byte(1, 4)
    return b1 * 256 + b2, b3 * 256 + b4
end
local function f64_words(x)
    local b = { string.pack(">d", x):byte(1, 8) }
    return b[1] * 256 + b[2], b[3] * 256 + b[4], b[5] * 256 + b[6], b[7] * 256 + b[8]
end
local function f32_value(hi, lo)
    return string.unpack(">f", string.char(hi // 256, hi % 256, lo // 256, lo % 256))
end

local H
local low_first = false
local function set_f32(addr, x)
    local hi, lo = f32_words(x)
    if low_first then hi, lo = lo, hi end
    H[addr], H[addr + 1] = hi, lo
end
local function set_state(s)
    H[1201] = s:byte(1) * 256 + (s:byte(2) or 0)
    H[1202] = 0
end

-- A three-phase charger with a car charging at 16 A.
local function device(opts)
    opts = opts or {}
    H = host._modbus_registers.holding
    for i = 0, 2 do set_f32(306 + 2 * i, opts.volts or 231) end
    local amps = opts.phase_amps or { opts.amps or 16, opts.amps or 16, opts.amps or 16 }
    for i = 0, 2 do set_f32(320 + 2 * i, amps[i + 1]) end
    set_f32(344, opts.power or 11000)
    local w1, w2, w3, w4 = f64_words(123456)
    if low_first then w1, w2, w3, w4 = w4, w3, w2, w1 end
    H[374], H[375], H[376], H[377] = w1, w2, w3, w4
    H[1200] = 1
    set_state(opts.state or "C2")
    set_f32(1206, opts.applied or 16)
    H[1208], H[1209] = 0, opts.valid_s or 60
    set_f32(1210, opts.applied or 16)
    set_f32(1212, opts.safe or 6)
    H[1214] = 1
    H[1215] = opts.phase_setting or 3
end

local function boot(opts, config)
    host.reset()
    DRIVER, driver_command, driver_default_mode = nil, nil, nil
    dofile(driver)
    device(opts)
    driver_init(config or {})
end

local function writes()
    local out = {}
    for _, c in ipairs(host._calls) do
        if c.func == "modbus_write_multiple" or c.func == "modbus_write" then
            assert(c.args[1] == 1210, "wrote register " .. tostring(c.args[1]))
            local hi, lo = c.args[2][1], c.args[2][2]
            if low_first then hi, lo = lo, hi end
            out[#out + 1] = f32_value(hi, lo)
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
boot({ state = "B2", amps = 0, power = 0 })
driver_poll()
assert(order(11040)); assert(near(last(), 16), "11040 W 3p is 16 A, got " .. tostring(last()))
assert(order(7000)); assert(near(last(), 10.1), "7000 W 3p rounds down to 10.1 A")
assert(order(4140)); assert(near(last(), 6), "4140 W 3p is exactly 6 A")
assert(order(4000)); assert(near(last(), 0), "below 6 A must write 0, never round up")
assert(order(-500)); assert(near(last(), 0), "a negative order is 0 A")

-- 2. Caps: the fuse, Core's room, the hardware and the config ceiling.
assert(order(11040, { phase_mode = "3p", voltage = 230, max_amps_per_phase = 10 }))
assert(near(last(), 10), "max_amps_per_phase must cap")
assert(order(11040, { phase_mode = "3p", voltage = 230, max_amps_per_phase = 25, cap_amps_per_phase = 8.55 }))
assert(near(last(), 8.5), "cap_amps_per_phase must cap and round down")
assert(order(11040, { phase_mode = "3p", voltage = 230, max_amps_per_phase = 25, cap_amps_per_phase = 5 }))
assert(near(last(), 0), "a cap below 6 A must pause")
assert(order(50000, { phase_mode = "3p", voltage = 230 }))
assert(near(last(), 32), "never above the 32 A hardware maximum")
boot({ state = "B2" }, { max_a = 13 })
driver_poll()
assert(order(11040)); assert(near(last(), 13), "config max_a must cap")

-- 3. Phases. A 1p order alone proves nothing: this charger does not switch
-- phases, and a three-phase car would draw the 1p current on all three.
local P1 = { phase_mode = "1p", voltage = 230, max_amps_per_phase = 25 }
-- An idle three-phase charger: divide by three.
boot({ state = "B2", amps = 0, power = 0 })
driver_poll()
assert(order(7360, P1)); assert(near(last(), 10.6), "1p order on an idle charger, got " .. tostring(last()))
-- Even when the charger is set to one phase: only a measurement counts.
boot({ state = "B2", amps = 0, power = 0, phase_setting = 1 })
driver_poll()
assert(order(3680, P1)); assert(near(last(), 0), "1p order before any measurement")
-- The car measured on exactly one phase: divide by one.
set_state("C2")
set_f32(320, 15); set_f32(322, 0); set_f32(324, 0)
driver_poll()
assert(order(3680, P1)); assert(near(last(), 16), "one phase measured, got " .. tostring(last()))
-- The same car on a charger set to three phases: 1215 is a floor.
boot({ state = "C2", phase_amps = { 15, 0, 0 }, phase_setting = 3 })
driver_poll()
assert(order(3680, P1)); assert(near(last(), 0), "1215 = 3 must keep three phases")
-- A three-phase car on a 1p order.
boot({ state = "C2", amps = 16, phase_setting = 1 })
driver_poll()
assert(order(7360, P1)); assert(near(last(), 10.6), "three phases measured, got " .. tostring(last()))
-- Re-plug: the first order after a new plug-in is three phases again.
set_state("A"); driver_poll()
set_state("B2"); driver_poll()
assert(order(3680, P1)); assert(near(last(), 0), "first order after a re-plug")
-- Config says the installation is single-phase.
boot({ state = "B2", amps = 0, power = 0, phase_setting = 1 }, { phases = 1 })
driver_poll()
assert(order(3680, P1)); assert(near(last(), 16), "config phases: 1, got " .. tostring(last()))
-- ... but not when the charger reports three phases.
boot({ state = "B2", amps = 0, power = 0, phase_setting = 3 }, { phases = 1 })
driver_poll()
assert(order(3680, P1)); assert(near(last(), 0), "config phases: 1 against 1215 = 3")

-- 4. Write only on change, refresh before the validity time runs out.
boot({ state = "C2" })
driver_poll()
assert(order(11040)); assert(count() == 1)
later(2000); assert(order(11040)); assert(count() == 1, "same order rewrote within 2 s")
driver_poll()
later(5000); assert(order(11040)); assert(count() == 1, "same order rewrote within 7 s")
later(9000); assert(order(11040)); assert(count() == 2, "no refresh after 16 s")
-- A short validity time makes the refresh come sooner.
H[1209] = 12; driver_poll()
later(3500); assert(order(11040)); assert(count() == 3, "no refresh with 12 s left")
-- A setpoint the charger lost (reboot) is written again.
H[1209] = 60; set_f32(1210, 0); driver_poll()
later(31000); local before = count()
assert(order(11040)); assert(count() == before + 1, "lost setpoint not rewritten")
-- A decrease goes out at once.
assert(order(6900)); assert(near(last(), 10), "decrease not applied at once")

-- 5. Pause and resume, through Core's contactor cycle.
boot({ state = "C2" })
driver_poll()
assert(order(11040)); assert(near(last(), 16))
assert(driver_command("ev_pause", 0, {})); assert(near(last(), 0), "pause must write 0 A")
later(3000); local n = count()
assert(order(11040)); assert(count() == n, "an order inside the pause hold reopened the charger")
assert(driver_command("ev_resume", 0, {})); assert(near(last(), 16), "resume must restore the order")
assert(driver_command("ev_pause", 0, {})); assert(near(last(), 0))
later(11000)
assert(order(11040)); assert(near(last(), 16), "a pause must not outlast the hold")
boot()
driver_poll()
assert(driver_command("ev_start", 0, {}) == false, "start before any order must say no")
assert(driver_command("ev_resume", 0, {}) == false, "resume before any order must say no")
assert(count() == 0, "start before any order wrote")

-- 6. Default mode: nothing unless FTW wrote; then 0 A once.
boot()
driver_poll()
assert(driver_default_mode()); assert(count() == 0, "default mode wrote on a site FTW never steered")
assert(order(11040))
assert(driver_default_mode()); assert(near(last(), 0), "default mode must write 0 A")
local settled = count()
for _ = 1, 5 do later(20000); assert(driver_default_mode()) end
assert(count() == settled, "default mode did not settle")
-- After default mode Core is back in charge; 0 A orders are refreshed again.
later(20000); assert(order(0)); assert(count() == settled + 1)

-- 7. Honest results: a refused write returns false, and so does a refused
-- stand-down.
boot()
driver_poll()
assert(order(11040))
host._modbus_write_error = "modbus exception function=0x10 code=0x04"
assert(order(6900) == false, "a refused write must return false")
assert(driver_command("ev_pause", 0, {}) == false, "a refused pause must return false")
-- After FTW wrote, a refused stand-down says false: a car may still be
-- charging. It is tried again once a minute, not on every call, and says
-- true only once the charger takes 0 A.
local function standdown(expect_write)
    local b = host._modbus_write_attempts
    local result = driver_default_mode()
    local wrote = host._modbus_write_attempts - b
    assert(wrote == (expect_write and 1 or 0),
        "alfen: stand-down wrote " .. wrote .. " times")
    return result
end
assert(standdown(true) == false, "alfen: a refused stand-down must say false")
for _ = 1, 5 do
    later(5000)
    assert(standdown(false) == false, "alfen: retried inside a minute, or said true")
end
later(35000)
assert(standdown(true) == false, "alfen: not retried after a minute")
later(30000)
assert(standdown(false) == false, "alfen: retried inside a minute")
host._modbus_write_error = nil
later(31000)
assert(standdown(true) == true, "alfen: a stand-down the charger took must say true")
for _ = 1, 3 do assert(standdown(false) == true, "alfen: did not settle") end
assert(order(11040)); assert(near(last(), 16), "a working charger is written again")

-- 8. Readings: device values only; a failed read stays nil.
boot({ state = "C2" })
driver_poll()
local e = host._emitted.ev[#host._emitted.ev]
assert(near(e.w, 11000) and e.connected == true and e.charging == true)
assert(near(e.max_a, 16) and near(e.current_limit_a, 16))
assert(near(e.l1_v, 231) and near(e.l3_a, 16))
assert(e.total_charge_wh and math.abs(e.total_charge_wh - 123456) < 1)
assert(e.phases == 3 and e.request_active == true)
set_state("B2"); driver_poll()
e = host._emitted.ev[#host._emitted.ev]
assert(e.connected == true and e.charging == false and e.request_active == false)
assert(e.reason_no_current_label == "vehicle not requesting current")
H[344], H[345] = 0xFFFF, 0xFFFF   -- NaN: the meter has no power value
local emitted = #host._emitted.ev
driver_poll()
assert(#host._emitted.ev == emitted, "emitted without a power reading")
boot()
host._modbus_read_fail_addresses[1200] = "Illegal Data Address"
driver_poll()
e = host._emitted.ev[#host._emitted.ev]
assert(e.connected == nil and e.max_a == nil, "a failed status read must stay nil")

-- 9. Stalled: we offer current, the car is plugged in, no PWM for 30 s.
boot({ state = "B1" })
driver_poll()
assert(order(11040))
driver_poll(); later(31000); driver_poll()
e = host._emitted.ev[#host._emitted.ev]
assert(e.command_stalled == true, "B1 under a 16 A offer for 31 s must stall")
assert(e.reason_no_current_label == "charger not offering current")

-- 10. A charger that sends 32-bit values low word first is read and written
-- low word first.
low_first = true
boot({ state = "C2" })
driver_poll()
e = host._emitted.ev[#host._emitted.ev]
assert(near(e.l1_v, 231) and near(e.w, 11000), "low-word-first values misread")
assert(order(11040)); assert(near(last(), 16), "low-word-first write wrong")
low_first = false

-- 11. Word order unknown: no voltage, no current anywhere. No reading is
-- reported and no current above 0 A is written; 0 A still goes through.
boot({ state = "B2", volts = 0, amps = 0, power = 0, applied = 0, safe = 0 })
driver_poll()
assert(host._emitted.ev == nil, "reported before the word order was known")
assert(order(11040) == false, "a current written in an unknown word order")
assert(count() == 0, "wrote a current in an unknown word order")
assert(driver_command("ev_pause", 0, {}), "0 A must go through in either order")
assert(near(last(), 0) and count() == 1)
set_f32(306, 230); driver_poll()
later(11000)   -- past the pause hold
assert(order(11040)); assert(near(last(), 16), "learned order must allow writes")

-- 12. A status block that stops answering is asked once a minute, not never;
-- the measurement block is asked every poll.
boot({ state = "C2" })
host._modbus_read_fail_addresses[1200] = "timeout"
local function reads(addr)
    local n = 0
    for _, c in ipairs(host._calls) do
        if c.func == "modbus_read" and c.args[1] == addr then n = n + 1 end
    end
    return n
end
for _ = 1, 10 do driver_poll(); later(5000) end
assert(reads(1200) == 3, "status block asked " .. reads(1200) .. " times in 50 s")
assert(reads(306) == 10, "measurement block skipped")
host._modbus_read_fail_addresses[1200] = nil
later(25000); driver_poll()   -- a minute after the third miss
assert(reads(1200) == 4, "status block not retried after a minute")
e = host._emitted.ev[#host._emitted.ev]
assert(e.connected == true, "status block did not come back")
host._modbus_read_fail_addresses[306] = "timeout"
for _ = 1, 5 do driver_poll() end
assert(reads(306) == 16, "the required block must be asked every poll")

print("alfen control: ok")
