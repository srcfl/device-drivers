-- A 6 A start is offered 7 A until the charger charges, then 6 A.
dofile("drivers/tests/lua_harness/host_mock.lua")
local driver = "drivers/lua/easee_cloud.lua"

local function boot(cfg, config_body)
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

local function poll(mode, kw)
    host._http_responses["/observations?ids="] = host.json_encode({
        {id=109,value=mode}, {id=120,value=kw or 0}, {id=121,value=1}, {id=124,value=100},
    })
    driver_poll()
end

local SIX = {phase_mode="3p", voltage=230, max_amps_per_phase=25}
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

-- 2. No boost when the fuse ceiling leaves no amp above 6.
boot()
poll(2)
assert(order(4140, {phase_mode="3p", voltage=230, max_amps_per_phase=6.9}))
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
assert(order(1380, {phase_mode="1p", voltage=230, max_amps_per_phase=16}))
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

print("easee_cloud start boost: ok")
