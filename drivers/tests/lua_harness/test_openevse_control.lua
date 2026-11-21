-- OpenEVSE: power orders become a claim with whole amps, a claim is written
-- only when it changes, default mode claims "disabled" once, and a refused
-- claim fails.
dofile("drivers/tests/lua_harness/host_mock.lua")
local DRIVER_PATH = "drivers/lua/openevse.lua"
local CLAIM = "/claims/1179910145"

-- A small OpenEVSE WiFi module.
local status, config, held, posts, post_mode, status_fail, seen_headers

host.http_get = function(url, hdrs)
  table.insert(host._calls, { func = "http_get", args = { url, hdrs } })
  seen_headers = hdrs
  if url:find("/status", 1, true) then
    if status_fail then return nil, "timeout" end
    return host.json_encode(status)
  end
  if url:find("/config", 1, true) then return host.json_encode(config) end
  if url:find(CLAIM, 1, true) then
    if not held then return nil, 'HTTP 404: {"msg":"Not found"}' end
    return host.json_encode(held)
  end
  return nil, "HTTP 404"
end

host.http_post = function(url, body, hdrs)
  table.insert(host._calls, { func = "http_post", args = { url, body, hdrs } })
  if not url:find(CLAIM, 1, true) then return nil, "HTTP 404" end
  posts[#posts + 1] = host.json_decode(body)
  if post_mode == "down" then return nil, "connection refused" end
  if post_mode == "refuse" then return nil, 'HTTP 400: {"msg":"Could not make claim"}' end
  held = posts[#posts]
  return '{"msg":"done"}'
end

local function boot(over, cfg_over, conf)
  host.reset()
  status = { state = 2, vehicle = 1, power = 0, amp = 0, voltage = 230, pilot = 32,
             session_energy = 1200, watthour = 345000 }
  for k, v in pairs(over or {}) do status[k] = v end
  config = { min_current_hard = 6, max_current_soft = 32, max_current_hard = 32,
             is_threephase = false, wifi_serial = "WIFI123", firmware = "7.1.3" }
  for k, v in pairs(cfg_over or {}) do config[k] = v end
  held, posts, post_mode, status_fail, seen_headers = nil, {}, "ok", false, nil
  driver_init, driver_poll, driver_command, driver_default_mode = nil, nil, nil, nil
  dofile(DRIVER_PATH)
  driver_init(conf or { host = "192.0.2.20", port = 80, phases = 1 })
  driver_poll()
end

local ONE = { phase_mode = "1p", voltage = 230 }
local function order(w, cmd) return driver_command("ev_set_current", w, cmd or ONE) end
local function last_post() return posts[#posts] end
local function check(cond, msg) if not cond then error(msg, 2) end end

-- 1. Power to amps.
boot()
check(order(3680), "16 A order failed")
check(last_post().state == "active" and last_post().charge_current == 16, "3680 W 1p should claim 16 A")
check(last_post().auto_release == false, "the claim must not end when the car leaves")

boot()
check(order(1379), "below-minimum order failed")
check(last_post().state == "disabled" and last_post().charge_current == nil,
  "5.99 A must claim disabled, never 6 A")

-- Without phases = 1 the installation counts as three-phase, even for a
-- "1p" order: OpenEVSE cannot show a car on one phase.
boot(nil, nil, { host = "192.0.2.20", port = 80 })
check(order(6900, ONE), "1p order without phases failed")
check(last_post().charge_current == 10, "6900 W 1p without phases = 1 should be P/(3V) = 10 A")
boot(nil, nil, { host = "192.0.2.20", port = 80 })
check(order(4140, { voltage = 230 }), "order without phase_mode failed")
check(last_post().charge_current == 6, "4140 W without phase_mode should be 6 A")

-- A three-phase setup always divides by three.
boot(nil, { is_threephase = true })
check(order(4140, ONE), "three-phase order failed")
check(last_post().charge_current == 6, "4140 W on a three-phase charger should be 6 A")

boot()
check(order(7360, { phase_mode = "1p", voltage = 230, max_amps_per_phase = 20 }), "fuse cap failed")
check(last_post().charge_current == 20, "max_amps_per_phase 20 must cap the claim")
boot()
check(order(7360, { phase_mode = "1p", voltage = 230, max_amps_per_phase = 25, cap_amps_per_phase = 9.5 }), "cap failed")
check(last_post().charge_current == 9, "cap_amps_per_phase 9.5 must cap at 9 A")
boot(nil, { max_current_soft = 24 })
check(order(11000), "soft limit order failed")
check(last_post().charge_current == 24, "max_current_soft 24 must cap the claim")
boot(nil, { max_current_hard = 16, max_current_soft = 32 })
check(order(11000), "hard limit order failed")
check(last_post().charge_current == 16, "max_current_hard 16 must cap the claim")
boot(nil, { min_current_hard = 10 })
check(order(2070), "minimum order failed")
check(last_post().state == "disabled", "9 A is below a 10 A minimum and must claim disabled")

-- 2. Writes only on change.
boot()
check(order(2300), "10 A order failed")
local n = #posts
check(order(2300), "repeat order failed")
driver_poll()
check(order(2300), "repeat order after a poll failed")
check(#posts == n, "an unchanged claim was written again")
check(order(1380), "decrease failed")
check(#posts == n + 1 and last_post().charge_current == 6, "a decrease claims at once")
-- The charger rebooted and dropped every claim: claim again.
held = nil
driver_poll()
check(order(1380), "order after reboot failed")
check(#posts == n + 2, "a claim the charger lost must be written again")

-- 3. Pause and resume.
boot()
check(order(2300), "order before pause failed")
check(driver_command("ev_pause", 0, {}), "pause failed")
check(last_post().state == "disabled", "pause claims disabled")
check(driver_command("ev_resume", 0, {}), "resume failed")
check(last_post().state == "active" and last_post().charge_current == 10, "resume claims the last order")
boot()
check(driver_command("ev_start", 0, {}), "start failed")
check(last_post().charge_current == 6, "start without an order claims the minimum")
-- A resume after a zero order claims the minimum.
boot()
check(order(2300) and order(0), "order and zero order failed")
check(driver_command("ev_resume", 0, {}) and last_post().charge_current == 6, "resume after a zero order claims 6 A")
-- A stale order (over 30 s) resumes at the minimum; a cap below it refuses.
boot()
check(order(2300) and driver_command("ev_pause", 0, {}), "order and pause failed")
host._millis_counter = host._millis_counter + 31000
check(driver_command("ev_resume", 0, {}) and last_post().charge_current == 6, "a late resume claims 6 A")
boot()
check(order(7360, { phase_mode = "1p", voltage = 230, max_amps_per_phase = 25, cap_amps_per_phase = 5 }), "5 A cap failed")
n = #posts
check(driver_command("ev_resume", 0, {}) == false and #posts == n, "a 5 A cap leaves no room to resume")

-- 4. Default mode does nothing until FTW wrote, then settles.
boot()
for _ = 1, 3 do check(driver_default_mode() == true, "default mode on a fresh driver failed") end
check(#posts == 0, "default mode on a fresh driver wrote a claim")
check(order(2300), "order before default failed")
n = #posts
for _ = 1, 5 do check(driver_default_mode() == true, "default mode failed") end
check(#posts == n + 1 and last_post().state == "disabled", "default mode claims disabled once")
boot()
held = { state = "disabled", auto_release = false }
driver_poll()
check(driver_command("ev_pause", 0, {}), "pause on a disabled claim failed")
for _ = 1, 3 do driver_default_mode() end
check(#posts == 0, "default mode wrote a claim the charger already held")

-- 5. A failed or refused claim returns false.
boot()
post_mode = "down"
check(order(2300) == false, "a claim that never arrived must return false")
boot()
post_mode = "refuse"
check(order(2300) == false, "a refused claim must return false")
check(driver_command("ev_pause", 0, {}) == false, "a refused pause must return false")
boot()
check(order(2300), "order before refusal failed")
posts = {}
post_mode = "refuse"
for i = 1, 6 do check(driver_default_mode() == false, "a refused stand-down must return false") end
check(#posts == 1, "default mode should claim once inside a minute, wrote " .. #posts)
host._millis_counter = host._millis_counter + 61000
post_mode = "ok"
check(driver_default_mode() == true and held.state == "disabled", "an accepted claim returns true")
check(driver_default_mode() == true and #posts == 2, "then it settles")
-- A car leaves while FTW's claim has the charger on: claim disabled once.
boot({ state = 3 })
check(order(2300), "order before unplug failed")
status.vehicle, status.state = 0, 1
n = #posts
driver_poll()
check(#posts == n + 1 and last_post().state == "disabled" and last_post().auto_release == false,
  "no car after FTW's claim should claim disabled, keeping auto_release off")
driver_poll(); driver_poll()
check(#posts == n + 1, "the unplug claim must not repeat")
-- An unknown phase setup divides by three, even with phases = 1.
boot(nil, { is_threephase = "unknown" })
check(order(4140), "order with unknown phases failed")
check(last_post().charge_current == 6, "phases = 1 with an unknown phase setup divides by three, got "
  .. tostring(last_post().charge_current))

-- 6. Readings.
boot({ state = 3, power = 3600, amp = 15652, pilot = 16 })
local ev = host._emitted.ev[#host._emitted.ev]
check(ev.w == 3600 and ev.connected == true and ev.charging == true, "power and state")
check(ev.current_limit_a == 16 and ev.max_a == nil, "pilot is the limit; no claim yet")
check(ev.session_wh == 1200 and ev.lifetime_wh == 345000, "energy")
check(ev.device_limit_a == 32 and ev.phases == 1, "limits and phases from /config")
check(host._sn == "WIFI123", "serial number not set")
-- Older firmware without power: voltage times amp in mA.
boot({ state = 3, power = "x", amp = 16000 })
ev = host._emitted.ev[#host._emitted.ev]
check(math.abs(ev.w - 3680) < 0.5, "power from voltage and mA, got " .. tostring(ev.w))
boot({ state = 254, vehicle = 1 })
check(order(2300), "order while sleeping failed")
for _ = 1, 400 do driver_poll() end
ev = host._emitted.ev[#host._emitted.ev]
check(ev.max_a == 10 and ev.current_limit_a == 0, "a sleeping charger offers nothing")
check(ev.reason_no_current_label == "sleeping", "state 254 is labelled")
check(ev.command_stalled == true, "an active claim that stays asleep is stalled")
boot()
local before = #host._emitted.ev
status_fail = true
driver_poll()
check(#host._emitted.ev == before, "a failed status read must not emit")

-- 7. Basic auth when a password is set.
boot(nil, nil, { host = "192.0.2.20", port = 80, password = "secret" })
check(seen_headers and seen_headers.Authorization == "Basic b3BlbmV2c2VhZG1pbjpzZWNyZXQ=",
  "blank user should send openevseadmin:secret")
boot(nil, nil, { host = "192.0.2.20", port = 80, username = "me", password = "pw" })
check(seen_headers and seen_headers.Authorization == "Basic bWU6cHc=", "user me:pw")
boot()
check(seen_headers == nil, "no password, no Authorization header")

print("PASS test_openevse_control")
