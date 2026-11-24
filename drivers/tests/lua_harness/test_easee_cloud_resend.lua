-- Easee puts its limit back at its maximum on a resume (32 A reported, #225),
-- and a settings write of an unchanged value never reaches the charger. The
-- driver re-sends its order as a command after a resume and whenever the
-- charger allows or draws more than the order.
dofile("drivers/tests/lua_harness/host_mock.lua")
local driver = "drivers/lua/easee_cloud.lua"

-- POSTs to a URL containing fail_url fail like a 503, after being recorded.
local fail_url
local real_post = host.http_post
host.http_post = function(url, body, headers)
    local resp = real_post(url, body, headers)
    if fail_url and url:find(fail_url, 1, true) then return nil, "HTTP 503" end
    return resp
end

local function boot()
    host.reset()
    fail_url = nil
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
            assert(body.minutes == 0, "minutes must be 0: Easee holds that limit until the next one")
            table.insert(out, body.amps)
        end
    end
    return out
end

-- Power carries an advancing source time: the driver rejects power without one.
local observation_sequence = 0
local function poll(mode, dyn, cur)
    observation_sequence = observation_sequence + 1
    local stamp = string.format("2026-01-01T08:00:00.%06dZ", observation_sequence)
    local obs = {{id=109,value=mode}, {id=120,value=0,timestamp=stamp}, {id=121,value=1}, {id=124,value=100}}
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

-- 6. A failed re-send after a resume is retried every 10 s, not every poll.
boot()
poll(2, 7)
assert(driver_command("ev_set_current", 4830, SEVEN))
later(6000); poll(2, 7)
fail_url = "/commands/set_dynamic_charger_current"
assert(driver_command("ev_resume", 0, {}))
later(3000); poll(2, 7)
before = #commands()
later(5000); poll(2, 7)
assert(#commands() == before, "retried a failed re-send within 10 s")
later(5000); poll(2, 7)
assert(#commands() == before + 1, "no retry 10 s after a failed re-send")
fail_url = nil
later(10000); poll(2, 7)
later(10000); poll(2, 7)
assert(#commands() == before + 2, "kept re-sending after one went through")

-- 7. A 0 A order is held as a 0 A command too: Easee accepts it, as its
-- pause does.
boot()
poll(2, 7)
driver_default_mode()
before = #commands()
poll(2, 32)
c = commands()
assert(#c == before + 1 and c[#c] == 0, "32 A on the charger did not re-send 0 A")
poll(2, 32)
later(10000); poll(2, 0)
assert(#commands() == before + 1, "re-sent 0 A within 10 s or to a charger at 0 A")

-- 8. A cut whose settings write failed is the order to re-send, not the
-- earlier, higher one.
local TWELVE = {phase_mode="3p", voltage=230, max_amps_per_phase=16, cap_amps_per_phase=12}
boot()
poll(2, 12)
assert(driver_command("ev_set_current", 8280, TWELVE))
later(6000); poll(2, 12)
fail_url = "/settings"
assert(not driver_command("ev_set_current", 5520, TWELVE))
poll(3, 12, 12)
c = commands()
assert(c[#c] == 8, "a failed cut to 8 A re-sent " .. tostring(c[#c]) .. " A")

print("easee_cloud resend: ok")
