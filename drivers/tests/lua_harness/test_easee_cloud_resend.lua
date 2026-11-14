-- Easee puts its limit back at its maximum on a resume (32 A reported, #225),
-- and a settings write of an unchanged value never reaches the charger. The
-- driver re-sends its order as a command after a resume and whenever the
-- charger allows or draws more than the order.
dofile("drivers/tests/lua_harness/host_mock.lua")
local driver = "drivers/lua/easee_cloud.lua"

local function boot()
    host.reset()
    host._http_responses["/accounts/login"] = '{"accessToken":"test","expiresIn":3600}'
    host._http_responses["/config"] = '{"maxChargerCurrent":16}'
    host._http_responses["/settings"] = '{}'
    host._http_responses["/commands/"] = '{}'
    host._http_responses["/sessions/ongoing"] = '{}'
    dofile(driver)
    driver_init({email="test@example.invalid", password="test", serial="TEST123"})
end

local function commands()
    local out = {}
    for _, call in ipairs(host._calls) do
        if call.func == "http_post" and call.args[1]:find("/commands/set_dynamic_charger_current", 1, true) then
            local body = host.json_decode(call.args[2])
            assert(body.minutes == 0, "command limit expires")
            table.insert(out, body.amps)
        end
    end
    return out
end

local function poll(mode, dyn, cur)
    local obs = {{id=109,value=mode}, {id=120,value=0}, {id=121,value=1}, {id=124,value=100}}
    if dyn then table.insert(obs, {id=48,value=dyn}) end
    if cur then table.insert(obs, {id=183,value=cur}) end
    host._http_responses["/observations?ids="] = host.json_encode(obs)
    driver_poll()
end
local function later(ms) host._millis_counter = host._millis_counter + ms end

-- 7 A per phase, below the 16 A fuse; not a 6 A start, so no start boost.
local SEVEN = {phase_mode="3p", voltage=230, max_amps_per_phase=16, cap_amps_per_phase=7}

-- 1. A resume is followed by the order as a command.
boot()
poll(2, 7)
assert(driver_command("ev_set_current", 4830, SEVEN))
later(6000); poll(2, 7)          -- the startup phaseMode re-assert
local before = #commands()
assert(driver_command("ev_resume", 0, {}))
poll(2, 7)
assert(#commands() == before, "re-sent before Easee applied the resume")
later(3000); poll(2, 7)
local c = commands()
assert(#c == before + 1 and c[#c] == 7, "no 7 A command after a resume")

-- 2. A charger that allows more than the order gets it again, rate-limited.
boot()
poll(2, 7)
assert(driver_command("ev_set_current", 4830, SEVEN))
later(6000); poll(2, 7)
before = #commands()
poll(3, 32, 7)
c = commands()
assert(#c == before + 1 and c[#c] == 7, "32 A on the charger did not re-send 7 A")
poll(3, 32, 7)
assert(#commands() == before + 1, "re-sent again within 10 s")
later(10000); poll(3, 32, 7)
assert(#commands() == before + 2, "no retry after 10 s")

-- 3. A car drawing well over the order re-sends it even when the reported
-- limit still reads the order.
later(10000); before = #commands()
poll(3, 7, 16)
assert(#commands() == before + 1, "16 A drawn against 7 A did not re-send")

-- 4. Within the order nothing is sent.
later(10000); before = #commands()
poll(3, 7, 7.4)
poll(3, 6, 6)
assert(#commands() == before, "re-sent although the charger kept the order")

-- 5. A disconnected charger is left alone.
later(10000); before = #commands()
poll(1, 32)
assert(#commands() == before, "re-sent to a charger with no car")

print("easee_cloud resend: ok")
