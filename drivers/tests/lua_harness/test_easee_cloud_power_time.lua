dofile("drivers/tests/lua_harness/host_mock.lua")
-- Easee records TotalPower only when it changes. A steady charge must not
-- keep reporting that old change time as when the power was observed.
local driver = "drivers/lua/easee_cloud.lua"
host.reset()
host._millis_step = 0
host._http_responses["/accounts/login"] = '{"accessToken":"test","expiresIn":3600}'
host._http_responses["/config"] = '{"maxChargerCurrent":8}'
host._http_responses["/sessions/ongoing"] = '{}'
dofile(driver)
driver_init({email="test@example.invalid",password="test",serial="TEST123"})

local function poll(mode, power_kw, power_time)
    host._http_responses["/observations?ids="] = host.json_encode({
        {id=109,value=mode,timestamp="2026-09-25T00:21:00Z"},
        {id=120,value=power_kw,timestamp=power_time},
        {id=121,value=12.5,timestamp=power_time},
    })
    driver_poll()
    local rows = host._emitted.ev
    assert(rows and #rows > 0, "no EV sample")
    return rows[#rows], #rows
end

local first = poll(3, 4.92, "2026-09-25T00:21:20Z")
assert(first.power_observed_at == "2026-09-25T00:21:20Z", "a new value lost its source time")
assert(first.control_power_observed_at == "2026-09-25T00:21:20Z" and first.control_power_available,
    "control evidence lost the measured source time")
assert(first.device_limit_a == 8 and first.device_limit_age_s == 0, "static ceiling was lost")
assert(first.max_a == nil, "static ceiling replaced dynamic readback")
local steady = poll(3, 4.92, "2026-09-25T00:21:20Z")
assert(steady.power_observed_at == nil,
    "an unchanged value kept its old change time: " .. tostring(steady.power_observed_at))
assert(steady.control_power_observed_at == first.control_power_observed_at,
    "cached cloud power became a new control measurement")
assert(first.control_power_confirmed and steady.control_power_confirmed,
    "a poll of a charger the cloud still hears from must confirm the unchanged value")
local changed = poll(3, 6.30, "2026-09-25T00:29:20Z")
assert(changed.power_observed_at == "2026-09-25T00:29:20Z", "a changed value lost its source time")

-- An offline charger (op_mode 0) emits no sample, so nothing looks fresh.
local _, before = poll(3, 6.30, "2026-09-25T00:29:20Z")
local _, after = poll(0, 6.30, "2026-09-25T00:29:20Z")
assert(after == before, "an offline charger emitted a sample")
print("Easee power time: passed")

host._millis_counter = host._millis_counter + 60000
host._http_responses["/config"] = '{"maxChargerCurrent":16}'
poll(3, 6.30, "2026-09-25T00:29:20Z") -- optional settings refresh follows power emit
local refreshed = poll(3, 6.30, "2026-09-25T00:29:20Z")
assert(refreshed.device_limit_a == 16 and refreshed.device_limit_age_s == 0, "ceiling did not refresh")
host._millis_counter = host._millis_counter + 180000
host._http_responses["/config"] = '{}'
local missing = poll(3, 6.30, "2026-09-25T00:29:20Z")
assert(missing.device_limit_age_s == 180, "missing read made cached limit look fresh")
