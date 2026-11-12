-- A 6 A start is offered 7 A until the charger charges, then 6 A, and only
-- while Core's cap_amps_per_phase says 7 A fits.
dofile("drivers/tests/lua_harness/host_mock.lua")
local driver = "drivers/lua/easee_cloud.lua"

local sample = 0
local function boot(cfg, config_body)
    sample = 0
    host.reset()
    host._http_responses["/accounts/login"] = '{"accessToken":"test","expiresIn":3600}'
    host._http_responses["/config"] = config_body or '{"maxChargerCurrent":16}'
    host._http_responses["/settings"] = '{}'
    host._http_responses["/commands/"] = '{}'
    host._http_responses["/sessions/ongoing"] = '{}'
    dofile(driver)
    local c = {email="test@example.invalid", password="test", serial="TEST123"}
    for k, v in pairs(cfg or {}) do c[k] = v end
    driver_init(c)
end

local function amps_writes()
    local out = {}
    for _, call in ipairs(host._calls) do
        if call.func == "http_post" and call.args[1]:find("/settings", 1, true) then
            local body = host.json_decode(call.args[2])
            if body.dynamicChargerCurrent ~= nil then table.insert(out, body.dynamicChargerCurrent) end
        end
    end
    return out
end
local function last_amps() local w = amps_writes(); return w[#w] end
local function count_cmd(path)
    local n = 0
    for _, call in ipairs(host._calls) do
        if call.func == "http_post" and call.args[1]:find(path, 1, true) then n = n + 1 end
    end
    return n
end

local function poll(mode, kw, stamp)
    sample = sample + 1
    stamp = stamp or string.format("2026-10-23T10:00:%02dZ", sample)
    host._http_responses["/observations?ids="] = host.json_encode({
        {id=109,value=mode}, {id=120,value=kw or 0,timestamp=stamp}, {id=121,value=1}, {id=124,value=100},
    })
    driver_poll()
end
local function poll_fails()
    host._http_responses["/observations?ids="] = "not json"
    driver_poll()
end
local function later(ms) host._millis_counter = host._millis_counter + ms end

-- Core's cap for this charger is exactly 7 A: floor(7) fits.
local SIX = {phase_mode="3p", voltage=230, max_amps_per_phase=25, cap_amps_per_phase=7}
local function six(cap, max)
    return {phase_mode="3p", voltage=230, max_amps_per_phase=max or 25, cap_amps_per_phase=cap}
end
local function order(w, cmd) return driver_command("ev_set_current", w, cmd or SIX) end

-- 1. Bump on a 6 A start, hold through repeated orders, step down once charging.
boot()
poll(2)
assert(order(4140))
assert(last_amps() == 7, "6 A start was not boosted to 7 A")
assert(order(4140)); assert(last_amps() == 7, "boost dropped before charging")
poll(2)
assert(last_amps() == 7, "boost dropped while still awaiting start")
poll(3, 4.8)
assert(last_amps() == 6, "no step-down to 6 A after charging was seen")
assert(order(4140)); assert(last_amps() == 6, "boost repeated during a running session")
assert(count_cmd("/commands/resume_charging") == 0, "boost sent a resume")

-- 2. No boost when the fuse ceiling leaves no amp above 6, whatever the cap.
boot()
poll(2)
assert(order(4140, six(7, 6.9)))
assert(last_amps() == 6, "boost ignored a 6 A fuse ceiling")
-- ...nor when Core gives no ceiling at all.
boot()
poll(2)
assert(order(4140, {phase_mode="3p", voltage=230}))
assert(last_amps() == 6, "boost without a known fuse ceiling")
-- ...nor when the charger's own static limit is 6 A.
boot(nil, '{"maxChargerCurrent":6}')
poll(2)
assert(order(4140))
assert(last_amps() == 6, "boost above the charger's static limit")

-- ...nor when the charger's static limit could not be read.
boot(nil, '{}')
poll(2)
assert(order(4140))
assert(last_amps() == 6, "boost with an unknown static limit")

-- 3. No boost when more than 6 A is ordered.
boot()
poll(2)
assert(order(5520)); assert(last_amps() == 8, "8 A order changed")
assert(order(10350)); assert(last_amps() == 15, "15 A order changed")

-- 4. Timeout: no charging within the window falls back to 6 A, once.
boot()
poll(2)
assert(order(4140)); assert(last_amps() == 7)
host._millis_counter = host._millis_counter + 91000
poll(2)
assert(last_amps() == 6, "boost outlived its window")
assert(order(4140)); assert(last_amps() == 6, "boost restarted after timeout")

-- 5. A higher order during the boost cancels it; a pause re-arms it.
boot()
poll(2)
assert(order(4140)); assert(last_amps() == 7)
assert(order(6900)); assert(last_amps() == 10, "higher order lost during boost")
host._millis_counter = host._millis_counter + 91000
poll(2)
assert(last_amps() == 10, "cancelled boost still stepped down")
assert(driver_command("ev_pause", 0, {}))
assert(order(4140)); assert(last_amps() == 7, "pause did not re-arm the boost")

-- 6. A charging session lowered to 6 A is not boosted.
boot()
poll(3, 6.9)
assert(order(4140)); assert(last_amps() == 6, "running session was boosted")

-- 7. Disabled by config.
boot({start_boost=false})
poll(2)
assert(order(4140)); assert(last_amps() == 6, "start_boost=false ignored")

-- 8. 1Φ: the boost is per phase too (6 A → 7 A on one phase).
boot()
poll(2)
assert(order(1380, {phase_mode="1p", voltage=230, max_amps_per_phase=16, cap_amps_per_phase=7.5}))
assert(last_amps() == 7, "1p 6 A start not boosted")

-- 9. Default mode clears the boost.
boot()
poll(2)
assert(order(4140)); assert(last_amps() == 7)
driver_default_mode()
assert(last_amps() == 0)
host._millis_counter = host._millis_counter + 91000
poll(2)
assert(last_amps() == 0, "default mode left a pending boost step-down")

-- 10. Core's cap decides. An older Core sends none: no boost.
boot()
poll(2)
assert(order(4140, six(nil)))
assert(last_amps() == 6, "boost without Core's cap")
-- Room for 6.4 A: 7 A would cross it.
boot()
poll(2)
assert(order(4140, six(6.4)))
assert(last_amps() == 6, "boost past Core's 6.4 A cap")
-- 7 A or more fits.
for _, cap in ipairs({7.9, 15}) do
    boot()
    poll(2)
    assert(order(4140, six(cap)))
    assert(last_amps() == 7, "no boost with a " .. cap .. " A cap")
end

-- 11. The cap falls to 6 A during a boost: 6 A at once, and the boost ends.
boot()
poll(2)
assert(order(4140, six(8))); assert(last_amps() == 7)
assert(order(4140, six(6)))
assert(last_amps() == 6, "boost kept 7 A after Core's cap fell to 6 A")
assert(order(4140, six(8)))
assert(last_amps() == 6, "an ended boost started again in the same start")
later(91000)
poll(2)
assert(last_amps() == 6, "ended boost stepped down again")

-- 12. The fuse ceiling falls to 6 A during a boost (Codex P1): 6 A at once.
boot()
poll(2)
assert(order(4140)); assert(last_amps() == 7)
assert(order(4140, six(6, 6)))
assert(last_amps() == 6, "boost kept 7 A after max_amps_per_phase fell to 6 A")

-- 13. Observations fail past the window (Codex P2): the poll still writes
-- 6 A, and the next order does not bring 7 A back.
boot()
poll(2)
assert(order(4140)); assert(last_amps() == 7)
later(91000)
poll_fails()
assert(last_amps() == 6, "boost outlived its window while observations failed")
assert(order(4140)); assert(last_amps() == 6, "order after a failed poll wrote 7 A")

-- 14. No poll at all past the window: the order itself ends the boost.
boot()
poll(2)
assert(order(4140)); assert(last_amps() == 7)
later(91000)
assert(order(4140)); assert(last_amps() == 6, "order past the window wrote 7 A")

-- 15. No boost before a poll has seen the charger not charging. After a
-- driver reload the car may already charge at 6 A.
boot()
assert(order(4140)); assert(last_amps() == 6, "boost before the first poll")
poll_fails()
assert(order(4140)); assert(last_amps() == 6, "boost after only a failed poll")
poll(3, 4.1)
assert(order(4140)); assert(last_amps() == 6, "reloaded driver boosted a running session")
poll(2)
assert(order(4140)); assert(last_amps() == 7, "no boost once a poll saw the charger stop")
-- A first poll that sees the charger waiting allows the boost.
boot()
assert(order(4140)); assert(last_amps() == 6)
poll(2)
assert(order(4140)); assert(last_amps() == 7, "no boost after a poll saw the charger waiting")

-- 16. A pause clears the boost. The phaseMode re-assert that the first order
-- scheduled then writes the 6 A order, not the boost's 7 A.
boot()
poll(2)
assert(order(4140)); assert(last_amps() == 7)
assert(driver_command("ev_pause", 0, {}))
later(5000)
poll(2)
assert(last_amps() == 6, "re-assert after a pause wrote the cleared boost's 7 A")

-- 17. Default mode clears the boost even when its 0 A write fails; the
-- re-assert then retries 0 A instead of writing 7 A.
boot()
poll(2)
assert(order(4140)); assert(last_amps() == 7)
local http_post = host.http_post
host.http_post = function(url, ...)
    if url:find("/settings", 1, true) then return nil, "HTTP 503" end
    return http_post(url, ...)
end
driver_default_mode()
host.http_post = http_post
assert(last_amps() == 7)
later(5000)
poll(2)
assert(last_amps() == 0, "re-assert after default mode wrote the cleared boost's 7 A")

-- 18. A rejected power timestamp cannot establish a stopped charger after
-- reload, or falsely report charging and end a boost. Fresh data recovers.
boot()
poll(2, 0, "invalid")
assert(order(4140)); assert(last_amps() == 6, "invalid first observation enabled boost")
poll(2)
assert(order(4140)); assert(last_amps() == 7)
local rows = #(host._emitted.ev or {})
poll(3, 4.8, "2026-10-23T10:00:01Z")
assert(#(host._emitted.ev or {}) == rows, "stale power emitted during boost")
assert(last_amps() == 7, "stale charging observation ended boost")
poll(3, 4.8)
assert(last_amps() == 6, "fresh charging observation did not end boost")

-- 19. Rejecting old data must not prevent the bounded boost timing out.
boot()
poll(2)
assert(order(4140)); assert(last_amps() == 7)
later(91000)
poll(2, 0, "2026-10-23T10:00:00Z")
assert(last_amps() == 6, "rejected observation extended boost past timeout")
assert(order(4140)); assert(last_amps() == 6, "boost restarted after rejection and timeout")

print("easee_cloud start boost: ok")
