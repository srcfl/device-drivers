-- go-e HTTP API v2: power orders become whole amps, writes happen only on a
-- change, default mode stops the charger once, and a refused write fails.
dofile("drivers/tests/lua_harness/host_mock.lua")
local DRIVER_PATH = "drivers/lua/goe_http.lua"

-- A small go-e: /api/status serves `dev`, /api/set changes it.
local dev, set_mode, sets, status_fail

local function nrg(v, a)
  return { v, v, v, 0, a[1], a[2], a[3], a[1] * v, a[2] * v, a[3] * v, 0,
           (a[1] + a[2] + a[3]) * v, 1, 1, 1, 0 }
end

host.http_get = function(url)
  table.insert(host._calls, { func = "http_get", args = { url } })
  if url:find("/api/status", 1, true) then
    if status_fail then return nil, "timeout" end
    return host.json_encode(dev)
  end
  local query = url:match("/api/set%?(.*)$")
  if query then
    sets[#sets + 1] = query
    if set_mode == "down" then return nil, "connection refused" end
    local reply = {}
    for key, value in query:gmatch("(%w+)=([^&]+)") do
      if set_mode == "refuse" or (set_mode == "refuse_amp" and key == "amp") then
        reply[key] = "value not allowed"
      else
        dev[key] = tonumber(value)
        reply[key] = true
      end
    end
    return host.json_encode(reply)
  end
  return nil, "HTTP 404"
end

local function boot(over, conf)
  host.reset()
  dev = { car = 3, amp = 16, frc = 0, ama = 32, mca = 6, var = 22, alw = true,
          acu = 16, wh = 1200, eto = 345000, modelStatus = 3,
          sse = "123456", typ = "go-eCharger", nrg = nrg(230, { 0, 0, 0 }) }
  for k, v in pairs(over or {}) do dev[k] = v end
  set_mode, sets, status_fail = "ok", {}, false
  driver_init, driver_poll, driver_command, driver_default_mode = nil, nil, nil, nil
  dofile(DRIVER_PATH)
  local c = { host = "192.0.2.10", port = 80 }
  for k, v in pairs(conf or {}) do c[k] = v end
  driver_init(c)
  driver_poll()
end

local THREE = { phase_mode = "3p", voltage = 230 }
local function order(w, cmd) return driver_command("ev_set_current", w, cmd or THREE) end
local function last_set() return sets[#sets] end
local function check(cond, msg) if not cond then error(msg, 2) end end

-- 1. Power to amps: rounded down, never up; phases and caps respected.
boot()
check(order(4140), "6 A order failed")
check(#sets == 2 and sets[1] == "amp=6" and sets[2] == "frc=2",
  "4140 W 3p should write amp=6, then frc=2, got " .. table.concat(sets, ", "))
check(dev.amp == 6 and dev.frc == 2, "charger did not take the order")

boot()
check(order(11000), "11 kW order failed")
check(dev.amp == 15, "11000 W 3p should be 15 A, got " .. tostring(dev.amp))

boot()
check(order(4139), "4139 W order failed")
check(dev.frc == 1, "5.99 A must stop the charger, not round up")
check(last_set() == "frc=1", "a stop writes only frc, got " .. tostring(last_set()))

-- A "1p" order on an idle charger divides by three: idle proves nothing.
boot()
check(order(6900, { phase_mode = "1p", voltage = 230 }), "1p order on an idle charger failed")
check(dev.amp == 10, "6900 W 1p on an idle charger should be P/(3V) = 10 A, got " .. tostring(dev.amp))
-- A "1p" order with the car measured on exactly one phase divides by one.
boot({ car = 2, nrg = nrg(230, { 10, 0, 0 }) })
check(order(3680, { phase_mode = "1p", voltage = 230 }), "1p order on one phase failed")
check(dev.amp == 16, "3680 W 1p on one measured phase should be 16 A, got " .. tostring(dev.amp))
-- A "3p" order stays three-phase even with the car on one phase.
boot({ car = 2, nrg = nrg(230, { 10, 0, 0 }) })
check(order(6900, { phase_mode = "3p", voltage = 230 }), "3p order on one phase failed")
check(dev.amp == 10, "6900 W 3p should stay 10 A, got " .. tostring(dev.amp))
-- A one-phase installation divides by one while idle, not with three live.
boot(nil, { phases = 1 })
check(order(3680), "order on a one-phase installation failed")
check(dev.amp == 16, "3680 W on an idle one-phase installation should be 16 A, got " .. tostring(dev.amp))
boot({ car = 2, nrg = nrg(230, { 10, 10, 10 }) }, { phases = 1 })
check(order(6900), "order with three live phases failed")
check(dev.amp == 10, "three live phases override phases = 1, got " .. tostring(dev.amp))

-- A "1p" order while the car is measured on three phases uses three.
boot({ car = 2, nrg = nrg(230, { 10, 10, 10 }) })
check(order(3680, { phase_mode = "1p", voltage = 230 }), "1p order on 3 phases failed")
check(dev.frc == 1, "3680 W over three measured phases is 5.3 A and must stop")

-- A missing phase_mode counts as three phases.
boot()
check(order(7360, { voltage = 230 }), "order without phase_mode failed")
check(dev.amp == 10, "7360 W without phase_mode should be 10 A, got " .. tostring(dev.amp))

boot()
check(order(4320, { phase_mode = "3p", voltage = 240 }), "240 V order failed")
check(dev.amp == 6, "4320 W at 240 V 3p should be 6 A, got " .. tostring(dev.amp))

boot()
check(order(22000, { phase_mode = "3p", voltage = 230, max_amps_per_phase = 10 }), "fuse cap order failed")
check(dev.amp == 10, "max_amps_per_phase 10 must cap at 10 A, got " .. tostring(dev.amp))

boot()
check(order(22000, { phase_mode = "3p", voltage = 230, max_amps_per_phase = 25, cap_amps_per_phase = 8.6 }), "cap order failed")
check(dev.amp == 8, "cap_amps_per_phase 8.6 must cap at 8 A, got " .. tostring(dev.amp))

boot({ ama = 13 })
check(order(22000), "ama order failed")
check(dev.amp == 13, "the owner's ama 13 must cap the order, got " .. tostring(dev.amp))

boot({ var = 11, ama = 32 })
check(order(22000), "11 kW unit order failed")
check(dev.amp == 16, "an 11 kW unit must not be asked for more than 16 A, got " .. tostring(dev.amp))

boot({ mca = 8 })
check(order(4830), "mca order failed")
check(dev.frc == 1, "7 A is below the charger's minimum of 8 A and must stop")

boot()
check(order(0), "0 W order failed")
check(dev.frc == 1, "0 W must stop the charger")

-- 2. Writes only on change; decreases go out at once.
boot()
check(order(6900), "10 A order failed")
local n = #sets
check(order(6900), "repeat order failed")
driver_poll()
check(order(6900), "repeat order after a poll failed")
check(#sets == n, "an unchanged order wrote again")
check(order(4140), "decrease failed")
check(#sets == n + 1 and last_set() == "amp=6", "a decrease should write amp=6 alone, got " .. tostring(last_set()))
-- A failed poll forgets the charger's state, so the next order writes.
status_fail = true
driver_poll()
status_fail = false
check(order(4140), "order after a failed poll failed")
check(#sets == n + 3 and sets[#sets - 1] == "amp=6" and sets[#sets] == "frc=2",
  "after a failed poll the order must be written again, amp then frc")

-- 3. Pause and resume.
boot()
check(order(6900), "order before pause failed")
check(driver_command("ev_pause", 0, {}), "pause failed")
check(dev.frc == 1 and last_set() == "frc=1", "pause should write frc=1")
check(driver_command("ev_resume", 0, {}), "resume failed")
check(dev.frc == 2 and dev.amp == 10, "resume should restart at the last order of 10 A")
check(last_set() == "frc=2", "resume should write only frc, got " .. tostring(last_set()))
-- A start with no earlier order uses the minimum.
boot()
check(driver_command("ev_start", 0, {}), "start failed")
check(dev.amp == 6 and dev.frc == 2, "start without an order should offer 6 A")
-- A resume after a zero order starts at the minimum, not the older order.
boot()
check(order(6900), "10 A order failed")
check(order(0), "zero order failed")
check(dev.frc == 1, "a zero order stops")
check(driver_command("ev_resume", 0, {}), "resume after a zero order failed")
check(dev.amp == 6 and dev.frc == 2, "resume after a zero order should offer 6 A, got " .. tostring(dev.amp))
-- An order older than 30 s is stale: resume at the minimum.
boot()
check(order(6900), "10 A order failed")
check(driver_command("ev_pause", 0, {}), "pause failed")
host._millis_counter = host._millis_counter + 31000
check(driver_command("ev_resume", 0, {}), "late resume failed")
check(dev.amp == 6, "a resume 31 s after the order should offer 6 A, got " .. tostring(dev.amp))
-- Never above Core's last cap; no start when the cap is below the minimum.
boot()
check(order(22000, { phase_mode = "3p", voltage = 230, max_amps_per_phase = 25, cap_amps_per_phase = 5 }), "capped order failed")
check(dev.frc == 1, "a 5 A cap stops the charger")
local before = #sets
check(driver_command("ev_resume", 0, {}) == false, "a resume with a cap below 6 A must return false")
check(#sets == before and dev.frc == 1, "a resume with no room must not write")

-- 4. Default mode does nothing until FTW wrote, then stops once and settles.
boot()
for _ = 1, 3 do check(driver_default_mode() == true, "default mode on a fresh driver failed") end
check(#sets == 0, "default mode on a fresh driver wrote " .. #sets .. " times")
check(order(6900), "order before default failed")
n = #sets
for _ = 1, 5 do check(driver_default_mode() == true, "default mode failed") end
check(#sets == n + 1 and last_set() == "frc=1", "default mode should write frc=1 once, wrote " .. (#sets - n))
-- A charger already off needs no write.
boot({ frc = 1 })
for _ = 1, 3 do driver_default_mode() end
check(#sets == 0, "default mode wrote to a charger that was already off")
-- After FTW commands again, default mode stops it again, once.
boot()
driver_default_mode()
check(order(6900), "order after default failed")
n = #sets
driver_default_mode(); driver_default_mode()
check(#sets == n + 1, "default mode after a new order should write once")

-- 5. A failed or refused write returns false.
boot()
set_mode = "down"
check(order(6900) == false, "a write that never arrived must return false")
check(driver_command("ev_pause", 0, {}) == false, "a pause that never arrived must return false")
boot()
set_mode = "refuse"
check(order(6900) == false, "a refused write must return false")
check(dev.amp == 16, "a refused write must not change the charger")
-- A refused stand-down returns false, and is tried again at most once a minute.
boot()
check(order(6900), "order before refusal failed")
sets = {}
set_mode = "refuse"
for i = 1, 6 do check(driver_default_mode() == false, "a refused stand-down must return false (call " .. i .. ")") end
check(#sets == 1, "default mode should write once inside a minute, wrote " .. #sets)
host._millis_counter = host._millis_counter + 61000
check(driver_default_mode() == false and #sets == 2, "default mode should try again after a minute")
set_mode = "ok"
check(driver_default_mode() == false and #sets == 2, "the next try waits another minute")
host._millis_counter = host._millis_counter + 61000
check(driver_default_mode() == true and dev.frc == 1, "a stop the charger takes returns true")
check(driver_default_mode() == true and #sets == 3, "once stood down, default mode settles")
-- amp refused, frc accepted: frc=2 must not go out after a refused amp.
boot()
set_mode = "refuse_amp"
check(order(6900) == false, "a refused amp must fail the order")
check(#sets == 1 and sets[1] == "amp=10", "only amp may be written, got " .. table.concat(sets, ", "))
check(dev.frc == 0, "the charger must not be switched on after a refused amp")
-- A car leaves while FTW has the charger on: stop it once.
boot()
check(order(6900), "order before unplug failed")
check(dev.frc == 2, "charger on")
dev.car = 1
local n0 = #sets
driver_poll()
check(#sets == n0 + 1 and dev.frc == 1, "no car after FTW's order should stop the charger once")
driver_poll(); driver_poll()
check(#sets == n0 + 1, "the unplug stop must not repeat")
-- A charger the owner turned on, with no FTW order, is left alone.
boot({ car = 1, frc = 2 })
driver_poll()
check(#sets == 0, "an unplugged charger FTW never turned on must not be written")

-- 6. Readings.
boot({ car = 2, amp = 10, frc = 2, acu = 8, nrg = nrg(230, { 8, 8, 8 }) })
local ev = host._emitted.ev[#host._emitted.ev]
check(ev.w == 3 * 8 * 230, "w should be the charger's total power")
check(ev.connected == true and ev.charging == true, "car 2 is connected and charging")
check(ev.max_a == 10 and ev.current_limit_a == 8, "max_a is amp, current_limit_a is acu")
check(ev.phases == 3 and ev.session_wh == 1200 and ev.lifetime_wh == 345000, "phases and energy")
check(host._sn == "123456", "serial number not set")
boot({ car = 3, frc = 1 })
ev = host._emitted.ev[#host._emitted.ev]
check(ev.max_a == 0, "a charger forced off offers 0 A")
check(ev.reason_no_current_label == nil, "modelStatus 3 is not a reason for no current")
boot({ car = 3, modelStatus = 4, frc = 1 })
ev = host._emitted.ev[#host._emitted.ev]
check(ev.reason_no_current_label == "force state off", "modelStatus 4 should be labelled")
boot({ car = 4 })
ev = host._emitted.ev[#host._emitted.ev]
check(ev.request_active == false and ev.charging == false, "car 4 is complete")
-- A failed read reports nothing.
boot()
local before = #host._emitted.ev
status_fail = true
driver_poll()
check(#host._emitted.ev == before, "a failed read must not emit")
-- Stalled: FTW ordered current, the car waits, and the charger will not allow it.
boot({ car = 3, alw = false })
check(order(6900), "order before stall failed")
for _ = 1, 400 do driver_poll() end
ev = host._emitted.ev[#host._emitted.ev]
check(ev.command_stalled == true, "an order the charger blocks for 30 s should be stalled")

print("PASS test_goe_http_control")
