dofile("drivers/tests/lua_harness/host_mock.lua")

local function offer(config_phases, mode, watts, voltage, max_a)
    host.reset()
    host._millis_step = 0
    host._http_responses["/accounts/login"] = '{"accessToken":"test","expiresIn":3600}'
    host._http_responses["/config"] = '{"phaseMode":2,"maxChargerCurrent":16}'
    host._http_responses["/settings"] = '{}'
    host._http_responses["/commands/"] = '{}'
    dofile("drivers/lua/easee_cloud.lua")
    driver_init({email="test@example.invalid", password="test", serial="TEST123", phases=config_phases})
    assert(driver_command("ev_set_current", watts, {phase_mode=mode, voltage=voltage, max_amps_per_phase=max_a}))
    local settings = {}
    for _, call in ipairs(host._calls) do
        if call.func == "http_post" and call.args[1]:match("/settings$") then
            for k,v in pairs(host.json_decode(call.args[2])) do settings[k]=v end
        end
    end
    return settings
end

local cases = {
    {nil, "2p", 4600, 230, 16, 2, 10},
    {2, "auto", 4600, 230, 16, 2, 10},
    {2, "3p", 4600, 230, 16, 2, 10},
    {nil, "2p", 6400, 230, 16, 2, 13}, -- whole amps must fit the watt ceiling
    {nil, "2p", 10000, 240, 10, 2, 10},
    {nil, "2p", 2760, 230, 16, 2, 6},
    {nil, "2p", 2759, 230, 16, 2, 0},
    {nil, "2p", 4600, 230, 5, 2, 0},
    {2, "1p", 2300, 230, 16, 1, 10},
    {nil, "3p", 6900, 230, 16, 3, 10},
}
for _, c in ipairs(cases) do
    local settings = offer(c[1], c[2], c[3], c[4], c[5])
    assert(settings.phaseMode == c[6], "wrong Easee phase mode for " .. c[2])
    assert(settings.dynamicChargerCurrent == c[7], "wrong current for " .. c[2] .. ": " .. tostring(settings.dynamicChargerCurrent))
end

-- The car's count must remain two after a write and in the power diagnostic.
offer(nil, "2p", 4600, 230, 16)
host._http_responses["/sessions/ongoing"] = '{}'
host._http_responses["/observations?ids="] = host.json_encode({
    {id=109, value=3, timestamp="2026-10-21T18:00:00Z"},
    {id=120, value=4.6, timestamp="2026-10-21T18:00:00Z"},
    {id=121, value=1, timestamp="2026-10-21T18:00:00Z"},
    {id=194, value=230, timestamp="2026-10-21T18:00:00Z"},
})
driver_poll()
local ev = host._emitted.ev[#host._emitted.ev]
assert(ev.phases == 2 and math.abs(ev.actual_amps_per_phase - 10) < 0.000001,
    "two-phase current diagnostic used three phases")

-- Auto read from Easee alone does not prove the car uses two phases.
offer(nil, "3p", 6900, 230, 16)
assert(driver_command("ev_set_current", 6900, {phase_mode="3p", voltage=230, max_amps_per_phase=16}))
print("Easee two-phase commands: passed")
