-- Zaptec Cloud control: watts become amps that never exceed Core's budget,
-- pause and resume reach the charger, refusals come back false, stand-alone
-- mode is refused, and the stand-down settles.
dofile("drivers/tests/lua_harness/host_mock.lua")
local driver = "drivers/lua/zaptec_cloud.lua"

local real_post = host.http_post
local post_fail = {}   -- url substring -> error string to return
local post_reply = {}  -- url substring -> 2xx body to return

local function install_post()
    host.http_post = function(url, body, headers)
        for pattern, err in pairs(post_fail) do
            if string.find(url, pattern, 1, true) then
                table.insert(host._calls, {func = "http_post", args = {url, body, headers}})
                return nil, err
            end
        end
        for pattern, reply in pairs(post_reply) do
            if string.find(url, pattern, 1, true) then
                table.insert(host._calls, {func = "http_post", args = {url, body, headers}})
                return reply
            end
        end
        return real_post(url, body, headers)
    end
end

local function state(t)
    local rows = {}
    for id, v in pairs(t) do
        table.insert(rows, {StateId = id, ValueAsString = tostring(v)})
    end
    return host.json_encode(rows)
end

local STATE_URL = "https://api.zaptec.com/api/chargers/c-1/state"
local CONNECTED = {[710] = 2, [718] = 0, [712] = 0, [507] = 0, [508] = 0, [509] = 0, [510] = 16}

local function boot(cfg)
    host.reset()
    post_fail = {}
    post_reply = {["/update"] = "", ["/sendCommand/"] = ""}
    install_post()
    host._http_responses["/oauth/token"] = '{"access_token":"tok","refresh_token":"ref","expires_in":3600}'
    host._http_responses["https://api.zaptec.com/api/chargers"] = '{"Data":[{"Id":"c-1","SerialNo":"ZAP1","InstallationId":"i-1"}]}'
    host._http_responses[STATE_URL] = state(CONNECTED)
    host._http_responses["/update"] = ""
    host._http_responses["/sendCommand/"] = ""
    dofile(driver)
    local c = {email = "owner@example.invalid", password = "pw"}
    for k, v in pairs(cfg or {}) do c[k] = v end
    driver_init(c)
end

local function poll(obs)
    host._http_responses[STATE_URL] = state(obs)
    driver_poll()
end

local function posts(path)
    local out = {}
    for _, call in ipairs(host._calls) do
        if call.func == "http_post" and string.find(call.args[1], path, 1, true) then
            table.insert(out, call)
        end
    end
    return out
end

local function current_writes()
    local out = {}
    for _, call in ipairs(posts("/api/chargers/c-1/update")) do
        table.insert(out, host.json_decode(call.args[2]).maxChargeCurrent)
    end
    return out
end
local function last_current() local w = current_writes(); return w[#w] end
local function count(path) return #posts(path) end
local function later(ms) host._millis_counter = host._millis_counter + ms end
local function order(w, cmd) return driver_command("ev_set_current", w, cmd) end
local THREE = {phase_mode = "3p", voltage = 230, max_amps_per_phase = 25}

-- 1. Watts become amps per phase, rounded down, capped, and 0 below 6 A.
boot()
poll(CONNECTED)
assert(order(11040, THREE)); assert(last_current() == 16, "11 040 W on 3 phases is 16 A")
assert(order(11040, {phase_mode = "3p", voltage = 230, max_amps_per_phase = 10}))
assert(last_current() == 10, "Core's per-phase cap was exceeded")
assert(order(4500, THREE)); assert(last_current() == 6.5, "6.52 A must round down to 6.5 A")
assert(order(3000, THREE)); assert(last_current() == 0, "4.3 A is below the 6 A minimum, so 0 A")
boot(); poll(CONNECTED)
assert(order(90000, {phase_mode = "3p", voltage = 230})); assert(last_current() == 32, "never above 32 A")

-- 2. One phase only when Core and the charger both say one.
boot()
poll({[710] = 3, [718] = 0, [712] = 0, [507] = 10, [508] = 10, [509] = 10, [510] = 16})
assert(order(7360, {phase_mode = "1p", voltage = 230, max_amps_per_phase = 32}))
assert(last_current() == 10.6, "a 1p order on a charger drawing 3 phases must use 3 phases")
poll({[710] = 3, [718] = 0, [712] = 0, [507] = 16, [508] = 0, [509] = 0, [510] = 16})
assert(order(3680, {phase_mode = "1p", voltage = 230, max_amps_per_phase = 32}))
assert(last_current() == 16, "a 1p order on a 1-phase car is 16 A")
-- An idle charger proves nothing: a 1p order on a 3-phase installation uses 3.
boot()
poll(CONNECTED)
assert(order(7360, {phase_mode = "1p", voltage = 230, max_amps_per_phase = 32}))
assert(last_current() == 10.6, "a 1p order on an idle charger must assume 3 phases")
-- A failed poll forgets the phase currents.
boot()
poll({[710] = 3, [718] = 0, [712] = 0, [507] = 16, [508] = 0, [509] = 0, [510] = 16})
host._http_responses[STATE_URL] = "not json"
driver_poll()
assert(order(3680, {phase_mode = "1p", voltage = 230, max_amps_per_phase = 32}))
assert(last_current() == 0, "stale phase currents after a failed poll")
-- So does a poll whose request fails.
boot()
poll({[710] = 3, [718] = 0, [712] = 0, [507] = 16, [508] = 0, [509] = 0, [510] = 16})
local real_get = host.http_get
host.http_get = function(url, headers)
    if url == STATE_URL then return nil, "HTTP 503: down" end
    return real_get(url, headers)
end
driver_poll()
host.http_get = real_get
assert(order(3680, {phase_mode = "1p", voltage = 230, max_amps_per_phase = 32}))
assert(last_current() == 0, "stale phase currents after a failed request")
-- A missing cap falls back to Core's last one.
boot()
poll(CONNECTED)
assert(order(11040, {phase_mode = "3p", voltage = 230, max_amps_per_phase = 10}))
assert(order(11040, {phase_mode = "3p", voltage = 230})); assert(last_current() == 10, "missing cap ignored Core's last")
assert(order(11040, nil)); assert(last_current() == 10)
-- A one-phase config does not outvote three phases measured.
boot({phases = 1})
poll({[710] = 3, [718] = 0, [712] = 0, [507] = 10, [508] = 10, [509] = 10, [510] = 16})
assert(order(7360, {voltage = 230, max_amps_per_phase = 32}))
assert(last_current() == 10.6, "phases = 1 in config must not outvote three live phases")
-- An installation set to one phase in config counts when Core gives no mode.
boot({phases = 1})
poll(CONNECTED)
assert(order(3680, {voltage = 230, max_amps_per_phase = 20})); assert(last_current() == 16)

-- 3. Writes only on change; a small rise waits, a fall goes out at once.
boot()
poll(CONNECTED)
assert(order(11040, THREE))
local n = #current_writes()
assert(order(11040, THREE)); assert(#current_writes() == n, "an unchanged order was written again")
assert(order(11040 + 0.3 * 690, THREE)); assert(#current_writes() == n, "a 0.3 A rise did not wait")
assert(order(11040 - 0.3 * 690, THREE)); assert(#current_writes() == n + 1, "a fall must go out at once")
assert(last_current() == 15.7)
later(61000)
assert(order(11040, THREE)); assert(last_current() == 16, "the held rise never went out")

-- 4. Pause writes 0 A and sends 506; resume offers the last order and sends 507.
boot()
poll({[710] = 3, [718] = 0, [712] = 0, [507] = 16, [508] = 16, [509] = 16, [510] = 16})
assert(order(11040, THREE))
assert(driver_command("ev_pause", 0, nil))
assert(last_current() == 0, "pause must set 0 A")
assert(count("/sendCommand/506") == 1, "pause must send 506")
poll({[710] = 5, [718] = 1, [712] = 0, [507] = 0, [508] = 0, [509] = 0, [510] = 0})
assert(driver_command("ev_resume", 0, nil))
assert(last_current() == 6, "resume offers the minimum; Core's next order sets the level")
assert(count("/sendCommand/507") == 1, "resume must send 507")
-- A resume right after a pause, before any new poll, still sends 507.
boot()
poll({[710] = 3, [718] = 0, [712] = 0, [507] = 16, [508] = 16, [509] = 16, [510] = 16})
assert(order(11040, THREE)); assert(driver_command("ev_pause", 0, nil))
assert(driver_command("ev_resume", 0, nil))
assert(count("/sendCommand/507") == 1, "a resume on a stale 'charging' poll skipped 507")
-- A positive order on a paused charger resumes it, with no ev_resume.
boot()
poll({[710] = 3, [718] = 0, [712] = 0, [507] = 16, [508] = 16, [509] = 16, [510] = 16})
assert(order(11040, THREE)); driver_default_mode()
poll({[710] = 5, [718] = 1, [712] = 0, [507] = 0, [508] = 0, [509] = 0, [510] = 0})
assert(order(11040, THREE))
assert(last_current() == 16 and count("/sendCommand/507") == 1, "a positive order left the charger paused")
assert(order(11040, THREE)); assert(count("/sendCommand/507") == 1, "resume resent while not paused")
-- The same after the driver's own pause, before any poll.
boot()
poll(CONNECTED)
assert(order(11040, THREE)); assert(driver_command("ev_pause", 0, nil))
assert(order(11040, THREE)); assert(count("/sendCommand/507") == 1)
-- A pause Zaptec turned away (no car) does not mark the charger paused:
-- once a car plugs in, a positive order whose resume gets 528 holds.
boot()
poll({[710] = 1, [718] = 0, [712] = 0, [507] = 0, [508] = 0, [509] = 0, [510] = 16})
post_fail["/sendCommand/506"] = 'HTTP 400: {"Code":528}'
assert(driver_command("ev_pause", 0, nil))
post_fail = {}
poll(CONNECTED)
post_fail["/sendCommand/507"] = 'HTTP 400: {"Code":528}'
assert(order(11040, THREE), "a 528 resume after a turned-away pause must hold")
post_fail = {}
-- A failing resume is retried no faster than every 30 s. Each try sends 507
-- twice: a server error gets one more request before it counts.
boot()
poll({[710] = 5, [718] = 1, [712] = 0, [507] = 0, [508] = 0, [509] = 0, [510] = 0})
post_fail["/sendCommand/507"] = 'HTTP 500: {"Code":520}'
assert(order(11040, THREE) == false, "a resume that never reached the charger must fail")
assert(count("/sendCommand/507") == 2, "a server error was not retried once")
assert(order(11040, THREE)); assert(count("/sendCommand/507") == 2, "resume retried at once")
later(31000)
assert(order(11040, THREE) == false); assert(count("/sendCommand/507") == 4)
post_fail = {}
-- Resume never offers more than Core's last cap, and nothing below 6 A.
boot()
poll(CONNECTED)
assert(order(17250, {phase_mode = "3p", voltage = 230, max_amps_per_phase = 25}))
assert(order(0, {phase_mode = "3p", voltage = 230, max_amps_per_phase = 4}))
assert(driver_command("ev_pause", 0, nil))
local before = #current_writes()
assert(driver_command("ev_resume", 0, nil))
assert(#current_writes() == before, "resume offered current above Core's last cap")
-- Resume with no earlier order offers the minimum.
boot()
poll({[710] = 5, [718] = 1, [712] = 0, [507] = 0, [508] = 0, [509] = 0, [510] = 0})
assert(driver_command("ev_start", 0, nil)); assert(last_current() == 6)

-- 5. "Already in that state" counts as done; other refusals come back false.
boot()
poll({[710] = 2, [718] = 0, [712] = 0, [507] = 0, [508] = 0, [509] = 0, [510] = 16})
post_fail["/sendCommand/507"] = 'HTTP 400: {"Code":528,"Details":"Charging is not Paused nor Scheduled"}'
assert(driver_command("ev_resume", 0, nil), "code 528 means nothing to resume")
post_fail = {}
poll({[710] = 1, [718] = 0, [712] = 0, [507] = 0, [508] = 0, [509] = 0, [510] = 16})
post_fail["/sendCommand/506"] = 'HTTP 400: {"Code":999}'
assert(driver_command("ev_pause", 0, nil), "a pause with no car holds")
post_fail = {}
poll(CONNECTED)
post_fail["/update"] = "HTTP 500: oops"
assert(order(11040, THREE) == false, "a failed current write must return false")
post_fail = {}
assert(order(11040, THREE)); assert(last_current() == 16)
-- 520 means the command never reached the charger.
boot()
poll(CONNECTED)
post_fail["/update"] = "HTTP 500: down"
post_fail["/sendCommand/506"] = 'HTTP 500: {"Code":520}'
assert(driver_command("ev_pause", 0, nil) == false, "a pause that reached nothing must fail")
post_fail = {}
-- 528 on resume holds only when the driver did not pause the charger itself.
boot()
poll(CONNECTED)
assert(driver_command("ev_pause", 0, nil))
post_fail["/sendCommand/507"] = 'HTTP 400: {"Code":528}'
assert(driver_command("ev_resume", 0, nil) == false, "a refused resume after our own pause must fail")
post_fail = {}
-- A 200 that carries an error Code is an error.
boot()
poll(CONNECTED)
post_reply["/update"] = '{"Code":520,"Details":"no contact"}'
assert(order(11040, THREE) == false, "a 200 with an error Code must fail")
post_reply["/update"] = '{"Code":0}'
assert(order(11040, THREE), "Code 0 is success")
-- A 401 signs in again once and retries.
boot()
poll(CONNECTED)
local logins = count("/oauth/token")
local fail_once = true
local inner = host.http_post
host.http_post = function(url, body, headers)
    if fail_once and string.find(url, "/update", 1, true) then
        fail_once = false
        table.insert(host._calls, {func = "http_post", args = {url, body, headers}})
        return nil, "HTTP 401: expired"
    end
    return inner(url, body, headers)
end
assert(order(11040, THREE), "a 401 must sign in again and retry")
assert(count("/oauth/token") > logins, "no new sign-in after 401")
assert(last_current() == 16)

-- 6. Stand-alone mode: current orders and resumes are refused and the reason shows.
boot()
poll({[710] = 2, [718] = 0, [712] = 1, [507] = 0, [508] = 0, [509] = 0, [510] = 16})
assert(order(11040, THREE) == false, "stand-alone mode must refuse a current order")
assert(driver_command("ev_resume", 0, nil) == false, "stand-alone mode must refuse a resume")
assert(#current_writes() == 0, "nothing may be written in stand-alone mode")
local ev = host._emitted["ev"][#host._emitted["ev"]]
assert(ev.reason_no_current_label and ev.reason_no_current_label:find("stand%-alone"),
    "the stand-alone reason must reach Core")

-- 7. The stand-down writes 0 A and pauses once, then settles until a new order.
boot()
poll(CONNECTED)
assert(order(11040, THREE))
driver_default_mode()
assert(last_current() == 0); assert(count("/sendCommand/506") == 1)
local writes = #current_writes()
for _ = 1, 5 do driver_default_mode() end
assert(#current_writes() == writes, "the stand-down did not settle")
assert(order(11040, THREE))
driver_default_mode()
assert(last_current() == 0, "a new order must re-arm the stand-down")
-- A refused stand-down says so, waits a minute before it tries again, and
-- says so again until it holds.
boot()
poll(CONNECTED)
assert(order(11040, THREE))
post_fail["/update"] = "HTTP 503: down"
post_fail["/sendCommand/506"] = 'HTTP 500: {"Code":520}'
assert(driver_default_mode() == false, "a refused stand-down must not report held")
local tries = count("/update")
for _ = 1, 5 do assert(driver_default_mode() == false) end
assert(count("/update") == tries, "a refused stand-down retried at once")
later(61000)
assert(driver_default_mode() == false)
-- Each try is the write and one more after the server error.
assert(count("/update") == tries + 2, "the stand-down never retried")
post_fail = {}
later(61000)
assert(driver_default_mode() == true, "a stand-down that held must report it")
assert(driver_default_mode() == true and count("/update") == tries + 3, "a held stand-down wrote again")
-- A pause that held is enough even when the 0 A write failed.
boot()
poll(CONNECTED)
assert(order(11040, THREE))
post_fail["/update"] = "HTTP 503: down"
assert(driver_default_mode() == true, "a held pause is a stand-down")
post_fail = {}
-- ...and a resume after it offers the minimum, not the old 16 A.
local n_before = #current_writes()
assert(driver_command("ev_resume", 0, nil))
assert(#current_writes() == n_before + 1 and last_current() == 6, "resume after a held pause offered a stale current")

-- Core runs the stand-down at every start: a charger FTW never steered in
-- this run keeps the owner's setting.
boot()
poll(CONNECTED)
for _ = 1, 3 do assert(driver_default_mode() == true) end
assert(#current_writes() == 0 and count("/sendCommand/506") == 0,
    "the stand-down touched a charger FTW never steered")

-- 8. Telemetry: no invented numbers, power and phases as measured.
boot()
poll({[710] = 3, [718] = 0, [712] = 0, [507] = 16, [508] = 16, [509] = 16, [510] = 16, [513] = 11000, [553] = 2.5})
ev = host._emitted["ev"][#host._emitted["ev"]]
assert(ev.w == 11000 and ev.charging == true and ev.phases == 3 and ev.max_a == 16)
assert(ev.session_wh == 2500)
poll({[710] = 2})
ev = host._emitted["ev"][#host._emitted["ev"]]
assert(ev.w == nil, "a missing power reading must stay nil")
assert(ev.max_a == nil, "a missing max current must stay nil")

-- 9. Every request names FTW in its User-Agent.
boot()
poll(CONNECTED)
assert(order(11040, THREE)); assert(driver_command("ev_pause", 0, nil))
local sent = posts("/api/chargers/")
assert(#sent >= 2, "expected a current write and a command")
for _, call in ipairs(posts("/oauth/token")) do table.insert(sent, call) end
for _, call in ipairs(sent) do
    assert(call.args[3] and tostring(call.args[3]["User-Agent"]):find("FTW%-zaptec_cloud"),
        "missing User-Agent on " .. call.args[1])
end

-- 10. A one-phase car on an idle three-phase charger starts at the minimum.
-- Field case (JimmyE, Zaptec Go, 20 A fuse, Volvo V60 on one phase): Core
-- asked for 6-17 A on one phase, each order came out as 0 A, and the car
-- never started.
local ONE = function(cap) return {phase_mode = "1p", voltage = 230, max_amps_per_phase = cap} end
boot()
poll(CONNECTED)
assert(order(1380, ONE(6))); assert(last_current() == 6, "6 A on one phase must start the car")
assert(order(3910, ONE(17))); assert(last_current() == 6, "an idle charger starts at the minimum, not 17 A")
assert(order(2760, ONE(12))); assert(last_current() == 6)
assert(order(1000, ONE(17))); assert(last_current() == 0, "4.3 A on one phase is below the minimum")
assert(order(3910, ONE(5))); assert(last_current() == 0, "a cap below the minimum must stay 0 A")
assert(order(3000, THREE)); assert(last_current() == 0, "a three-phase order is unchanged")
-- While the car ramps up, nothing on any phase yet: still the minimum.
poll({[710] = 3, [718] = 0, [712] = 0, [507] = 0.4, [508] = 0, [509] = 0, [510] = 6})
assert(order(2760, ONE(12))); assert(last_current() == 6, "a ramping car was cut to 0 A")
-- Once it draws on one phase it gets its full one-phase current.
poll({[710] = 3, [718] = 0, [712] = 0, [507] = 5.8, [508] = 0, [509] = 0, [510] = 6})
assert(order(3910, ONE(17))); assert(last_current() == 17, "a one-phase car drawing did not get 17 A")
-- A car seen on three phases never gets a one-phase start.
boot()
poll({[710] = 3, [718] = 0, [712] = 0, [507] = 6, [508] = 6, [509] = 6, [510] = 6})
assert(order(3910, ONE(17))); assert(last_current() == 0, "a three-phase car got the one-phase start")
-- Without a fresh poll there is no start either.
boot()
assert(order(1380, ONE(6))); assert(last_current() == 0, "a start before any poll")

-- 11. A charger minimum above 6 A is the floor; nothing positive goes below it.
boot()
poll({[710] = 2, [718] = 0, [712] = 0, [507] = 0, [508] = 0, [509] = 0, [510] = 16, [511] = 10})
assert(order(2760, ONE(12))); assert(last_current() == 10, "the start must use the charger's 10 A minimum")
assert(order(1380, ONE(12))); assert(last_current() == 0, "6 A is below this charger's minimum")
poll({[710] = 3, [718] = 0, [712] = 0, [507] = 10, [508] = 0, [509] = 0, [510] = 10, [511] = 10})
assert(order(2070, ONE(12))); assert(last_current() == 0, "9 A would set the maximum below the minimum")
assert(order(2760, ONE(12))); assert(last_current() == 12)
assert(driver_command("ev_pause", 0, nil))
poll({[710] = 5, [718] = 1, [712] = 0, [507] = 0, [508] = 0, [509] = 0, [510] = 0, [511] = 10})
assert(driver_command("ev_resume", 0, nil)); assert(last_current() == 10, "resume below the charger's minimum")
local logged_min = false
for _, line in ipairs(host._logs) do
    if tostring(line):find("minimum current is 10 A", 1, true) then logged_min = true end
end
assert(logged_min, "the charger's minimum was not logged")

-- 12. A server error or a lost connection gets one more request; a refusal does not.
boot()
poll(CONNECTED)
local failed_once = false
local inner_post = host.http_post
host.http_post = function(url, body, headers)
    if not failed_once and string.find(url, "/update", 1, true) then
        failed_once = true
        table.insert(host._calls, {func = "http_post", args = {url, body, headers}})
        return nil, "HTTP 503: busy"
    end
    return inner_post(url, body, headers)
end
assert(order(11040, THREE), "a 503 followed by success must hold")
assert(count("/update") == 2 and last_current() == 16)
host.http_post = inner_post
boot()
poll(CONNECTED)
failed_once = false
inner_post = host.http_post
host.http_post = function(url, body, headers)
    if not failed_once and string.find(url, "/sendCommand/506", 1, true) then
        failed_once = true
        table.insert(host._calls, {func = "http_post", args = {url, body, headers}})
        return nil, "connection reset by peer"
    end
    return inner_post(url, body, headers)
end
assert(order(11040, THREE)); assert(driver_command("ev_pause", 0, nil))
assert(count("/sendCommand/506") == 2, "a lost connection was not retried")
host.http_post = inner_post
boot()
poll(CONNECTED)
post_fail["/update"] = 'HTTP 400: {"Code":529}'
assert(order(11040, THREE) == false); assert(count("/update") == 1, "a refusal was retried")
post_fail = {}

-- 13. The driver asks the host for time a cloud call needs.
local asked = nil
host.set_command_timeout_s = function(s) asked = s end
boot()
assert(asked == 20, "the driver did not ask for 20 s per call")
host.set_command_timeout_s = nil

-- 14. driver_release hands the charger back when the owner removes the driver.
-- After FTW paused it: the owner's 16 A and a resume.
boot()
poll(CONNECTED)
assert(order(11040, THREE)); assert(driver_command("ev_pause", 0, nil))
poll({[710] = 5, [718] = 1, [712] = 0, [507] = 0, [508] = 0, [509] = 0, [510] = 0})
assert(driver_release() == true)
assert(last_current() == 16, "release must put back the owner's 16 A")
assert(count("/sendCommand/507") == 1, "release must resume a charger FTW paused")
-- After a stand-down in this run.
boot()
poll(CONNECTED)
assert(order(11040, THREE)); driver_default_mode()
assert(driver_release() == true); assert(last_current() == 16 and count("/sendCommand/507") == 1)
-- The owner's maximum is the one found before FTW's first write.
boot()
poll(CONNECTED)
assert(order(4500, THREE)); assert(last_current() == 6.5)
poll({[710] = 3, [718] = 0, [712] = 0, [507] = 6.5, [508] = 6.5, [509] = 6.5, [510] = 6.5})
assert(driver_release() == true); assert(last_current() == 16, "release used FTW's own 6.5 A")
assert(count("/sendCommand/507") == 0, "release resumed a charger FTW never paused")
-- Left at 0 A by an earlier run: no cap (32 A) and a resume.
boot()
poll({[710] = 5, [718] = 1, [712] = 0, [507] = 0, [508] = 0, [509] = 0, [510] = 0})
assert(driver_release() == true)
assert(last_current() == 32, "a charger left below its minimum must get the 32 A hand-back")
assert(count("/sendCommand/507") == 1)
-- A charger FTW never touched is left alone.
boot()
poll(CONNECTED)
assert(driver_release() == true)
assert(#current_writes() == 0 and count("/sendCommand/507") == 0, "release touched a charger FTW never steered")
-- No car to resume (528) is fine; a refused write is not.
boot()
poll(CONNECTED)
assert(order(11040, THREE)); assert(driver_command("ev_pause", 0, nil))
post_fail["/sendCommand/507"] = 'HTTP 400: {"Code":528}'
assert(driver_release() == true, "528 on release means nothing to resume")
post_fail = {}
boot()
poll(CONNECTED)
assert(order(11040, THREE))
post_fail["/update"] = "HTTP 503: down"
assert(driver_release() == false, "a refused hand-back must report false")
post_fail = {}

print("zaptec_cloud control: ok")
