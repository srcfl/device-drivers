-- Hardy Barth: the driver finds the eCB1 or Salia controller, power orders
-- become whole amps, writes happen only on a change, default mode stops the
-- station once, and a refused write fails.
dofile("drivers/tests/lua_harness/host_mock.lua")
local DRIVER_PATH = "drivers/lua/hardybarth.lua"

local function check(cond, msg) if not cond then error(msg, 2) end end

local controller      -- "ecb1" or "salia"
local cc, meter, snap -- device state
local posts, post_mode, read_fail

local function salia_snapshot()
  return host.json_encode(snap)
end

host.http_get = function(url, hdrs)
  table.insert(host._calls, { func = "http_get", args = { url, hdrs } })
  if read_fail then return nil, "timeout" end
  if controller == "ecb1" then
    if url:find("/api/v1/chargecontrols/1/maxcurrent", 1, true) then
      return '{"protocol-version":"1.3","maxcurrent":' .. cc.maxcurrent .. '}'
    end
    if url:find("/api/v1/chargecontrols/1", 1, true) then
      return host.json_encode({ ["protocol-version"] = "1.3", chargecontrol = cc })
    end
    if url:find("/api/v1/meters/1", 1, true) then
      return host.json_encode({ ["protocol-version"] = "1.3", meter = { id = 1, data = meter } })
    end
  elseif controller == "salia" and url:find("/api/?reset", 1, true) then
    return salia_snapshot()
  end
  return nil, "HTTP 404: not found"
end

host.http_post = function(url, body, hdrs)
  table.insert(host._calls, { func = "http_post", args = { url, body, hdrs } })
  local path = url:match("^http://[^/]+(/.*)$")
  posts[#posts + 1] = { path = path, body = body, headers = hdrs }
  if post_mode == "down" then return nil, "connection refused" end
  if controller == "ecb1" then
    if post_mode == "refuse" then return nil, 'HTTP 400: {"errors":[]}' end
    if path == "/api/v1/chargecontrols/1/mode" then cc.mode = body:match("mode=(%w+)")
    elseif path == "/api/v1/chargecontrols/1/mode/manual/ampere" then
      cc.manualmodeamp = tonumber(body:match("manualmodeamp=(%d+)"))
    elseif path == "/api/v1/chargecontrols/1/stop" then cc.stateid = 17
    elseif path == "/api/v1/chargecontrols/1/start" then cc.stateid = 2
    else return nil, "HTTP 404" end
    return ""
  end
  if path ~= "/api/" then return nil, "HTTP 404" end
  if post_mode == "refuse" then return '{"error":1,"result":"no valid JSON string"}' end
  local req = host.json_decode(body)
  snap.secc.port0.ci.evse.basic.grid_current_limit.actual = req.grid_current_limit
  return '{"result":"ok"}'
end

local function boot_ecb1(over, conf)
  host.reset()
  controller = "ecb1"
  cc = { id = 1, type = "cPH1", mode = "eco", manualmodeamp = 16, currentpwmamp = 16,
         stateid = 2, state = "connected", connected = true, evminamp = 6, maxcurrent = 32 }
  meter = { ["1-0:1.4.0"] = 0, ["1-0:1.8.0"] = 345.6,
            ["1-0:31.4.0"] = 0, ["1-0:51.4.0"] = 0, ["1-0:71.4.0"] = 0,
            ["1-0:32.4.0"] = 230, ["1-0:52.4.0"] = 230, ["1-0:72.4.0"] = 230 }
  for k, v in pairs(over or {}) do cc[k] = v end
  posts, post_mode, read_fail = {}, "ok", false
  driver_init, driver_poll, driver_command, driver_default_mode = nil, nil, nil, nil
  dofile(DRIVER_PATH)
  driver_init(conf or { host = "192.0.2.30", port = 80 })
  driver_poll()
end

local function boot_salia(over, conf)
  host.reset()
  controller = "salia"
  local o = over or {}
  snap = {
    device = { serial = "101308379", modelname = "Salia PLCC Master", software_version = "2.3.90" },
    secc = { port0 = {
      ci = { charge = { cp = { status = o.cp or "B" } },
             evse = { basic = { offered_current_limit = o.offered or "16.0",
                                grid_current_limit = { actual = o.lane or "16" } } } },
      metering = {
        meter = { available = "1" },
        power = { active_total = { actual = o.power_dw or "0" } },
        current = { ac = { l1 = { actual = o.ma or "0" }, l2 = { actual = o.ma or "0" }, l3 = { actual = o.ma or "0" } } },
        voltage = { ac = { l1 = { actual = "23000" }, l2 = { actual = "23000" }, l3 = { actual = "23000" } } },
        energy = { active_import = { actual = "345600" } },
      },
      salia = { chargemode = o.mode or "manual", max_amp = o.max_amp or "32",
                socketminamp = "6", socketmaxamp = "32", pausecharging = o.pause or "0",
                chargedata = "3600|5000|1.20|C09CC3CF" },
    } },
  }
  posts, post_mode, read_fail = {}, "ok", false
  driver_init, driver_poll, driver_command, driver_default_mode = nil, nil, nil, nil
  dofile(DRIVER_PATH)
  driver_init(conf or { host = "192.0.2.31", port = 80, api_key = "k3y" })
  driver_poll()
end

local THREE = { phase_mode = "3p", voltage = 230 }
local function order(w, cmd) return driver_command("ev_set_current", w, cmd or THREE) end
local function paths()
  local out = {}
  for i, p in ipairs(posts) do out[i] = p.path:gsub("^/api/v1/chargecontrols/1", "") .. (p.body ~= "" and (" " .. p.body) or "") end
  return table.concat(out, ", ")
end
local function lane() return snap.secc.port0.ci.evse.basic.grid_current_limit.actual end

---------------------------------------------------------------------------
-- eCB1
---------------------------------------------------------------------------

-- 1. Power to amps. The first order sets manual mode and the current, and
-- starts a socket that reports itself stopped (stateid 17).
boot_ecb1({ stateid = 17 })
check(#host._emitted.ev == 1, "eCB1 was not detected and read")
check(order(4140), "6 A order failed")
check(paths() == "/mode mode=manual, /mode/manual/ampere manualmodeamp=6, /start",
  "first order should set manual, 6 A and start, got " .. paths())
check(posts[1].headers["Content-Type"] == "application/x-www-form-urlencoded", "eCB1 writes are form-encoded")
-- A socket that reports itself running is not started again.
boot_ecb1()
check(order(4140), "6 A order on a running socket failed")
check(paths() == "/mode mode=manual, /mode/manual/ampere manualmodeamp=6",
  "a running socket needs no start, got " .. paths())
-- The socket stops itself after FTW's start: the next order starts it again.
boot_ecb1({ stateid = 17 })
check(order(6900), "order before self-stop failed")
driver_poll()
cc.stateid = 17
driver_poll()
local before17 = #posts
check(order(6900), "order after self-stop failed")
check(#posts == before17 + 1 and posts[#posts].path:find("/start", 1, true),
  "a socket seen stopped after a start must be started again, got " .. paths())

boot_ecb1()
check(order(4139), "4139 W order failed")
check(paths() == "/stop", "5.99 A must stop, got " .. paths())

boot_ecb1()
check(order(22000, { phase_mode = "3p", voltage = 230, max_amps_per_phase = 10 }), "fuse cap failed")
check(cc.manualmodeamp == 10, "max_amps_per_phase must cap at 10 A")
boot_ecb1()
check(order(22000, { phase_mode = "3p", voltage = 230, max_amps_per_phase = 25, cap_amps_per_phase = 8.2 }), "cap failed")
check(cc.manualmodeamp == 8, "cap_amps_per_phase 8.2 must cap at 8 A")
boot_ecb1({ maxcurrent = 13 })
check(order(22000), "socket max failed")
check(cc.manualmodeamp == 13, "the socket's maxcurrent 13 must cap the order")
boot_ecb1({ evminamp = 8 })
check(order(4830), "evminamp order failed")
check(paths() == "/stop", "7 A is below an 8 A minimum and must stop")
-- A "1p" order on an idle station divides by three: idle proves nothing.
boot_ecb1()
check(order(6900, { phase_mode = "1p", voltage = 230 }), "1p order on an idle station failed")
check(cc.manualmodeamp == 10, "6900 W 1p on an idle station should be P/(3V) = 10 A")
boot_ecb1(nil, { host = "192.0.2.30", port = 80, phases = 1 })
check(order(3680), "order on a one-phase installation failed")
check(cc.manualmodeamp == 16, "3680 W on an idle one-phase installation should be 16 A")
-- A "1p" order with the car on three phases divides by three.
boot_ecb1()
meter["1-0:31.4.0"], meter["1-0:51.4.0"], meter["1-0:71.4.0"] = 10, 10, 10
meter["1-0:1.4.0"] = 6900
cc.stateid = 5
driver_poll()
check(order(3680, { phase_mode = "1p", voltage = 230 }), "1p order on three phases failed")
check(paths() == "/stop", "3680 W over three measured phases is 5.3 A and must stop")

-- 2. Writes only on change; no start without a car.
boot_ecb1()
check(order(6900), "10 A order failed")
local n = #posts
check(order(6900), "repeat failed")
driver_poll()
check(order(6900), "repeat after poll failed")
check(#posts == n, "an unchanged order wrote again: " .. paths())
check(order(4140), "decrease failed")
check(#posts == n + 1 and cc.manualmodeamp == 6, "a decrease writes the current alone")
boot_ecb1({ connected = false, stateid = 1 })
check(order(6900), "order without a car failed")
check(paths() == "/mode mode=manual, /mode/manual/ampere manualmodeamp=10",
  "no start without a car, got " .. paths())
cc.connected, cc.stateid = true, 17
driver_poll()
check(order(6900), "order after plug-in failed")
check(posts[#posts].path:find("/start", 1, true), "the order after plug-in should start a stopped socket")
-- Repeated 0 W orders send one stop.
boot_ecb1()
check(order(0) and order(0) and order(0), "0 W orders failed")
driver_poll()
check(order(0), "0 W after poll failed")
check(paths() == "/stop", "repeated 0 W orders should stop once, got " .. paths())

-- 3. Pause and resume.
boot_ecb1()
check(order(6900), "order before pause failed")
check(driver_command("ev_pause", 0, {}), "pause failed")
check(posts[#posts].path:find("/stop", 1, true), "pause stops")
check(driver_command("ev_resume", 0, {}), "resume failed")
check(posts[#posts].path:find("/start", 1, true) and cc.manualmodeamp == 10, "resume starts at the last order")
-- A resume after a zero order starts at the minimum.
boot_ecb1()
check(order(6900) and order(0), "order and zero order failed")
check(driver_command("ev_resume", 0, {}), "resume after a zero order failed")
check(cc.manualmodeamp == 6 and posts[#posts].path:find("/start", 1, true), "resume after a zero order offers 6 A")
-- A car leaves while FTW has the socket started: stop it once.
boot_ecb1({ stateid = 17 })
check(order(6900), "order before unplug failed")
cc.connected, cc.stateid = false, 1
local before_unplug = #posts
driver_poll()
check(#posts == before_unplug + 1 and posts[#posts].path:find("/stop", 1, true), "no car should stop the socket")
driver_poll(); driver_poll()
check(#posts == before_unplug + 1, "the unplug stop must not repeat")

-- 4. Default mode does nothing until FTW wrote, then settles.
boot_ecb1()
for _ = 1, 3 do check(driver_default_mode() == true, "default mode on a fresh driver failed") end
check(#posts == 0, "default mode on a fresh eCB1 driver wrote")
check(order(6900), "order before default failed")
n = #posts
for _ = 1, 5 do check(driver_default_mode() == true, "default mode failed") end
check(#posts == n + 1 and posts[#posts].path:find("/stop", 1, true), "default mode stops once")

-- 5. A failed or refused write returns false.
boot_ecb1()
post_mode = "refuse"
check(order(6900) == false, "a refused write must return false")
check(#posts == 1, "after a refused mode write nothing else may be written")
boot_ecb1()
post_mode = "down"
check(driver_command("ev_pause", 0, {}) == false, "a stop that never arrived must return false")
boot_ecb1()
check(order(6900), "order before refusal failed")
posts = {}
post_mode = "refuse"
for i = 1, 6 do check(driver_default_mode() == false, "a refused stand-down must return false") end
check(#posts == 1, "default mode should stop once inside a minute, wrote " .. #posts)
host._millis_counter = host._millis_counter + 61000
post_mode = "ok"
check(driver_default_mode() == true and #posts == 2, "an accepted stop returns true")
check(driver_default_mode() == true and #posts == 2, "then it settles")

-- 6. Readings.
boot_ecb1({ stateid = 5, mode = "manual", manualmodeamp = 10, currentpwmamp = 10 })
meter["1-0:1.4.0"] = 6900
meter["1-0:31.4.0"], meter["1-0:51.4.0"], meter["1-0:71.4.0"] = 10, 10, 10
driver_poll()
local ev = host._emitted.ev[#host._emitted.ev]
check(ev.w == 6900 and ev.connected == true and ev.charging == true, "eCB1 power and state")
check(ev.max_a == 10 and ev.current_limit_a == 10 and ev.phases == 3, "eCB1 limits and phases")
check(math.abs(ev.lifetime_wh - 345600) < 1 and ev.device_limit_a == 32, "eCB1 energy and socket limit")
boot_ecb1({ connected = false, stateid = 1 })
ev = host._emitted.ev[#host._emitted.ev]
check(ev.connected == false and ev.charging == false, "an empty socket is not connected")
boot_ecb1()
n = #host._emitted.ev
read_fail = true
driver_poll()
check(#host._emitted.ev == n, "a failed eCB1 read must not emit")
-- Forced controller skips detection.
boot_ecb1(nil, { host = "192.0.2.30", controller = "ecb1" })
for _, call in ipairs(host._calls) do
  check(not (call.func == "http_get" and call.args[1]:find("/api/?reset", 1, true)), "forced eCB1 still probed Salia")
end

---------------------------------------------------------------------------
-- Salia
---------------------------------------------------------------------------

-- 1. Power to amps.
boot_salia()
check(#host._emitted.ev == 1, "Salia was not detected and read")
check(order(4140), "6 A order failed")
check(#posts == 1 and posts[1].path == "/api/" and lane() == "6", "4140 W 3p should set the limit to 6")
check(posts[1].body == '{"grid_current_limit":"6"}', "Salia body, got " .. posts[1].body)
check(posts[1].headers and posts[1].headers.Apikey == "k3y", "Salia writes send the Apikey header")
boot_salia()
check(order(4139), "4139 W order failed")
check(lane() == "0", "5.99 A must set the limit to 0, got " .. lane())
boot_salia()
check(order(22000, { phase_mode = "3p", voltage = 230, max_amps_per_phase = 10 }), "fuse cap failed")
check(lane() == "10", "max_amps_per_phase must cap at 10 A")
boot_salia({ max_amp = "13" })
check(order(22000), "max_amp order failed")
check(lane() == "13", "max_amp 13 must cap the order")
boot_salia({ cp = "C", ma = "10000", power_dw = "69000" })
check(order(3680, { phase_mode = "1p", voltage = 230 }), "1p on three phases failed")
check(lane() == "0", "3680 W over three measured phases must stop")

-- 2. Writes only on change.
boot_salia({ lane = "10" })
check(order(6900), "unchanged order failed")
check(#posts == 0, "a limit the station already holds was written")
check(order(4140), "decrease failed")
check(#posts == 1 and lane() == "6", "a decrease writes at once")
driver_poll()
check(order(4140), "repeat after poll failed")
check(#posts == 1, "the read-back limit should stop a second write")

-- 3. Pause and resume.
boot_salia()
check(order(6900), "order before pause failed")
check(driver_command("ev_pause", 0, {}) and lane() == "0", "pause sets 0")
check(driver_command("ev_resume", 0, {}) and lane() == "10", "resume sets the last order")

-- 4. Default mode does nothing until FTW wrote, then settles.
boot_salia()
for _ = 1, 3 do driver_default_mode() end
check(#posts == 0 and lane() == "16", "default mode on a fresh Salia driver wrote")
check(order(6900), "order before default failed")
for _ = 1, 5 do check(driver_default_mode() == true, "default mode failed") end
check(#posts == 2 and lane() == "0", "default mode sets 0 once")

-- 5. A refused write returns false.
boot_salia()
post_mode = "refuse"
check(order(6900) == false, "a refused limit must return false")
boot_salia()
post_mode = "down"
check(order(6900) == false, "a limit that never arrived must return false")
for i = 1, 6 do check(driver_default_mode() == false, "a failed stand-down must return false") end
check(#posts == 2, "default mode should try once inside a minute, posts " .. #posts)

-- 6. Readings.
boot_salia({ cp = "C", ma = "10000", power_dw = "69000", lane = "10", offered = "10.0" })
ev = host._emitted.ev[#host._emitted.ev]
check(ev.w == 6900 and ev.connected == true and ev.charging == true, "Salia power is deci-watts")
check(ev.max_a == 10 and ev.current_limit_a == 10 and ev.phases == 3, "Salia limits and phases")
check(ev.l1_v == 230 and ev.l1_a == 10, "Salia volts and amps")
check(ev.session_wh == 1200 and ev.lifetime_wh == 345600, "Salia energy")
check(host._sn == "101308379", "Salia serial")
boot_salia({ cp = "B", pause = "1", offered = "0.0" })
check(order(6900), "order while paused failed")
for _ = 1, 400 do driver_poll() end
ev = host._emitted.ev[#host._emitted.ev]
check(ev.reason_no_current_label == "paused at the station", "a pause at the station is named")
check(ev.command_stalled == true, "a limit the station does not offer for 30 s is stalled")
boot_salia()
snap.secc.port0.metering.power = nil
n = #host._emitted.ev
driver_poll()
check(#host._emitted.ev == n, "no power, no emit")

print("PASS test_hardybarth_control")
