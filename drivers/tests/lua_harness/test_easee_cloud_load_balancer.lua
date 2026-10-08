dofile("drivers/tests/lua_harness/host_mock.lua")
-- Easee's load balancer can cut a charging car below the offer. The reason
-- stays recorded from when the limit began, which may be before the last
-- power change. A limit that still explains the shortfall must reach Core.
local driver = "drivers/lua/easee_cloud.lua"

local function boot()
    host.reset()
    host._millis_step = 0
    host._http_responses["/accounts/login"] = '{"accessToken":"test","expiresIn":3600}'
    host._http_responses["/config"] = '{"maxChargerCurrent":16}'
    host._http_responses["/sessions/ongoing"] = '{}'
    host._http_responses["/settings"] = '{}'
    host._http_responses["/commands/"] = 'null'
    dofile(driver)
    driver_init({email="test@example.invalid", password="test", serial="TEST123"})
end

-- reason_time before power_time: the reason predates the last power change.
local function poll(mode, power_kw, reason, reason_time, offer_a)
    local obs = {
        {id=109, value=mode, timestamp="2026-10-08T05:00:00Z"},
        {id=120, value=power_kw, timestamp="2026-10-08T05:10:00Z"},
        {id=121, value=12.5, timestamp="2026-10-08T05:10:00Z"},
        {id=194, value=230, timestamp="2026-10-08T05:00:00Z"},
        {id=96, value=reason, timestamp=reason_time},
    }
    if offer_a ~= nil then table.insert(obs, {id=48, value=offer_a, timestamp="2026-10-08T05:00:00Z"}) end
    host._http_responses["/observations?ids="] = host.json_encode(obs)
    driver_poll()
    local rows = host._emitted.ev
    assert(rows and #rows > 0, "no EV sample")
    return rows[#rows]
end

local OLD, NEW = "2026-10-08T05:05:00Z", "2026-10-08T05:15:00Z"

-- The reported case: 16 A offered, 8.3 kW on three phases is 12 A per phase.
boot()
local cut = poll(3, 8.3, 29, OLD, 16)
assert(cut.reason_no_current == 29, "an active load-balancing limit was dropped while charging")
assert(cut.reason_no_current_label == "current limited by circuit load balancing",
    "label does not match Easee's table: " .. tostring(cut.reason_no_current_label))
assert(cut.current_limited_by == "load_balancer", "Core was not told the load balancer limits the car")

-- Easee's Equalizer and a partner's dynamic circuit current are load balancing too.
local eq = poll(3, 8.3, 28, OLD, 16)
assert(eq.current_limited_by == "load_balancer" and eq.reason_no_current_label == "current limited by equalizer",
    "an Equalizer limit was not reported")
assert(poll(3, 8.3, 27, OLD, 16).current_limited_by == "load_balancer", "a dynamic circuit limit was not reported")

-- Drawing the whole offer: the old reason no longer explains anything.
local full = poll(3, 11.0, 29, OLD, 16)
assert(full.reason_no_current == nil and full.current_limited_by == nil,
    "an old limit was reported while the car drew the whole offer")

-- A gap under 2 A is within what a car and the estimate may differ by.
assert(poll(3, 9.8, 29, OLD, 16).current_limited_by == nil, "a small gap was read as a limit")

-- An old reason that is not load balancing keeps the existing rule.
local other = poll(3, 8.3, 52, OLD, 16)
assert(other.reason_no_current == nil and other.current_limited_by == nil,
    "an old non-balancing reason was reported while charging")

-- Without a known offer there is nothing to measure the shortfall against.
boot()
local unknown = poll(3, 8.3, 29, OLD, nil)
assert(unknown.reason_no_current == nil and unknown.current_limited_by == nil,
    "an old limit was kept without a known offer")

-- FTW's own last write stands in for a missing offer readback.
assert(driver_command("ev_set_current", 11000, {phase_mode="3p", voltage=230, max_amps_per_phase=16}),
    "ev_set_current failed")
local written = poll(3, 8.3, 29, OLD, nil)
assert(written.current_limited_by == "load_balancer", "FTW's last offer was not used as the offer")

-- A reason newer than the last power change holds as before.
boot()
assert(poll(3, 8.3, 29, NEW, 16).current_limited_by == "load_balancer", "a new limit was dropped")

-- No current at all: the load balancer holds a connected car at zero.
local held = poll(2, 0, 2, OLD, 16)
assert(held.reason_no_current == 2 and held.current_limited_by == "load_balancer",
    "a car held at zero by the load balancer was not reported")
assert(poll(2, 0, 5, OLD, 16).current_limited_by == "load_balancer", "a load-balancing queue was not reported")

-- Charger and car limits are not the load balancer.
assert(poll(2, 0, 52, OLD, 16).current_limited_by == nil, "a charger limit was named the load balancer")
assert(poll(2, 0, 100, OLD, 16).current_limited_by == nil, "a car refusal was named the load balancer")

-- No car, no limit.
assert(poll(1, 0, 29, NEW, 16).current_limited_by == nil, "an unplugged charger reported a limit")

print("Easee load balancer: passed")
