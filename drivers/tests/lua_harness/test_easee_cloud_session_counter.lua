dofile("drivers/tests/lua_harness/host_mock.lua")
-- Easee's session energy moves in steps of about 1 kWh, so the driver says
-- so and FTW's energy record uses power. The figure itself stays.
local driver = "drivers/lua/easee_cloud.lua"
host.reset()
host._millis_step = 0
host._http_responses["/accounts/login"] = '{"accessToken":"test","expiresIn":3600}'
host._http_responses["/config"] = '{"maxChargerCurrent":16}'
host._http_responses["/sessions/ongoing"] = '{}'
dofile(driver)
driver_init({email="test@example.invalid",password="test",serial="TEST123"})
host._http_responses["/observations?ids="] = host.json_encode({
    {id=109,value=3,timestamp="2026-11-08T02:00:00Z"},
    {id=120,value=9.6,timestamp="2026-11-08T02:00:00Z"},
    {id=121,value=12.0,timestamp="2026-11-08T02:00:00Z"},
})
driver_poll()
local rows = host._emitted.ev
assert(rows and #rows > 0, "no EV sample")
local sample = rows[#rows]
assert(sample.session_wh_coarse == true, "the coarse session counter was not declared")
assert(sample.session_wh == 12000, "session energy lost: " .. tostring(sample.session_wh))
print("Easee session counter: passed")
