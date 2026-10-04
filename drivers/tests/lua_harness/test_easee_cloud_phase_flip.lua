dofile("drivers/tests/lua_harness/host_mock.lua")
-- A mid-session phase flip only takes effect when the charger restarts the
-- session. resume_charging in the same command as the pause continues that
-- session, so the car stays on one phase until a poll shows charging stopped.
local driver = "drivers/lua/easee_cloud.lua"
host.reset()
host._millis_step = 0
host._http_responses["/accounts/login"] = '{"accessToken":"test","expiresIn":3600}'
host._http_responses["/config"] = '{}'
host._http_responses["/sessions/ongoing"] = '{}'
host._http_responses["/commands/"] = '{}'
host._http_responses["/settings"] = '{}'
dofile(driver)
driver_init({email="test@example.invalid",password="test",serial="TEST123"})

local function posts(path)
    local n = 0
    for _, call in ipairs(host._calls) do
        if call.func == "http_post" and string.find(call.args[1], path, 1, true) then
            n = n + 1
        end
    end
    return n
end
local function offer(w)
    local ok = driver_command("ev_set_current", w,
        {phase_mode="auto", voltage=230, max_amps_per_phase=16})
    assert(ok, "ev_set_current failed at " .. tostring(w) .. " W")
end
local function advance(ms) host._millis_counter = host._millis_counter + ms end
local function poll(mode, power_kw)
    host._http_responses["/observations?ids="] = host.json_encode({
        {id=109,value=mode,timestamp="2026-09-25T00:21:00Z"},
        {id=120,value=power_kw,timestamp="2026-09-25T00:21:20Z"},
        {id=121,value=1,timestamp="2026-09-25T00:21:20Z"},
    })
    driver_poll()
end

advance(1000)
offer(3000)
assert(posts("pause_charging") == 0, "first command of a session paused the charger")

advance(120000) -- past the 90 s phase hold
offer(9000)
assert(posts("pause_charging") == 1, "mid-session flip did not pause")
assert(posts("resume_charging") == 0, "resumed in the same command as the flip pause")

advance(1000)
poll(3, 3.5)
offer(9000)
assert(posts("resume_charging") == 0, "resumed while the poll still showed charging")

advance(1000)
poll(2, 0)
advance(1000)
poll(0, 0)
offer(9000)
assert(posts("resume_charging") == 0, "offline poll left an old stop observation valid")

advance(1000)
poll(2, 0)
host._http_responses["/observations?ids="] = "not JSON"
driver_poll()
offer(9000)
assert(posts("resume_charging") == 0, "failed poll left an old stop observation valid")

advance(1000)
poll(2, 0)
offer(9000)
assert(posts("resume_charging") == 1, "did not resume once a poll showed charging had stopped")
advance(5000)
offer(9000)
assert(posts("resume_charging") == 1, "resumed again after the flip completed")

print("Easee phase flip: passed")
