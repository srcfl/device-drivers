-- Zaptec Cloud control: watts become amps that never exceed Core's budget,
-- pause and resume reach the charger, refusals come back false, stand-alone
-- mode is refused, and the stand-down settles.
dofile("drivers/tests/lua_harness/host_mock.lua")
local driver = "drivers/lua/zaptec_cloud.lua"

local real_post = host.http_post
local post_fail = {}   -- url substring -> error string to return

local function install_post()
    host.http_post = function(url, body, headers)
        for pattern, err in pairs(post_fail) do
            if string.find(url, pattern, 1, true) then
                table.insert(host._calls, {func = "http_post", args = {url, body, headers}})
                return nil, err
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
assert(order(90000, {phase_mode = "3p", voltage = 230})); assert(last_current() == 32, "never above 32 A")

-- 2. One phase only when Core and the charger both say one.
boot()
poll({[710] = 3, [718] = 0, [712] = 0, [507] = 10, [508] = 10, [509] = 10, [510] = 16})
assert(order(7360, {phase_mode = "1p", voltage = 230, max_amps_per_phase = 32}))
assert(last_current() == 10.6, "a 1p order on a charger drawing 3 phases must use 3 phases")
poll({[710] = 3, [718] = 0, [712] = 0, [507] = 16, [508] = 0, [509] = 0, [510] = 16})
assert(order(3680, {phase_mode = "1p", voltage = 230, max_amps_per_phase = 32}))
assert(last_current() == 16, "a 1p order on a 1-phase car is 16 A")
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
assert(last_current() == 16, "resume must offer the last asked current")
assert(count("/sendCommand/507") == 1, "resume must send 507")
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
-- A refused stand-down waits before it tries again.
boot()
poll(CONNECTED)
post_fail["/update"] = "HTTP 503: down"
driver_default_mode()
local tries = count("/update")
for _ = 1, 5 do driver_default_mode() end
assert(count("/update") == tries, "a refused stand-down retried at once")
later(301000)
driver_default_mode()
assert(count("/update") == tries + 1, "the stand-down never retried")

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

print("zaptec_cloud control: ok")
