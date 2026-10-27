dofile("drivers/tests/lua_harness/host_mock.lua")
-- Easee's own load balancing can hold the car below FTW's order. Field
-- trace (srcfl/ftw#1763, 23 Oct 2026, UTC): FTW ordered 15 A and the
-- charger read back 15 A (observation 48), while the circuit's allocated
-- current (70-72) and the current signalled to the car (114) were 12 A at
-- the start, then 14 A and 13 A; the car took 8.2-8.9 kW, not 10.4 kW.
local driver = "drivers/lua/easee_cloud.lua"
local RS = "\30"
local SERIAL = "EH123456"

local function later(ms) host._millis_counter = host._millis_counter + ms end

local function boot(extra, ws, config_body)
    host.reset()
    host._millis_step = 0
    host._ws_granted = ws or false
    host._http_responses["/accounts/login"] = '{"accessToken":"test","expiresIn":3600}'
    host._http_responses["/config"] = config_body or '{"maxChargerCurrent":16}'
    host._http_responses["/settings"] = '{}'
    host._http_responses["/commands/"] = '{}'
    host._http_responses["/sessions/ongoing"] = '{}'
    dofile(driver)
    local cfg = {email="test@example.invalid", password="test", serial=SERIAL}
    for k, v in pairs(extra or {}) do cfg[k] = v end
    driver_init(cfg)
end

-- order sends FTW's order, as Core does every tick; amps per phase.
local function order(a, phase_mode)
    local p = phase_mode == "1p" and 1 or 3
    assert(driver_command("ev_set_current", a * 230 * p,
        {phase_mode=phase_mode or "3p", voltage=230, max_amps_per_phase=25, cap_amps_per_phase=25}))
end

-- The trace crosses midnight UTC: 23:xx is 22 October, the rest 23 October.
local function at(clock)
    return (clock:sub(1, 2) == "23" and "2026-10-22T" or "2026-10-23T") .. clock .. "Z"
end

-- obs builds a REST reply. o.alloc is {L1, L2, L3}; false leaves a value out.
local function obs(o)
    local list = {
        {id=109, value=o.mode or 3, timestamp=at("23:53:00")},
        {id=120, value=o.kw or 8.3, timestamp=at(o.power_at or "23:54:30")},
        {id=121, value=1.5, timestamp=at(o.power_at or "23:54:30")},
    }
    if o.order ~= false then
        table.insert(list, {id=48, value=o.order or 15, timestamp=at(o.order_at or "23:50:00")})
    end
    if o.pilot ~= false then
        table.insert(list, {id=114, value=o.pilot or 12, timestamp=at(o.pilot_at or "23:54:22")})
    end
    local alloc = o.alloc == nil and {12, 12, 12} or o.alloc
    for i = 1, 3 do
        if alloc and alloc[i] ~= false and alloc[i] ~= nil then
            table.insert(list, {id=69 + i, value=alloc[i], timestamp=at(o.alloc_at or o.pilot_at or "23:54:22")})
        end
    end
    if o.reason then table.insert(list, {id=96, value=o.reason, timestamp=at(o.reason_at)}) end
    return list
end

local function poll(o)
    host._http_responses["/observations?ids="] = host.json_encode(obs(o or {}))
    driver_poll()
    local rows = host._emitted.ev or {}
    return rows[#rows], #rows
end

local function expect(ev, limit, by, what)
    assert(ev, what .. ": no EV sample")
    assert(ev.current_limit_a == limit and ev.current_limited_by == by,
        string.format("%s: got %s/%s, want %s/%s", what, tostring(ev.current_limit_a),
            tostring(ev.current_limited_by), tostring(limit), tostring(by)))
end


boot()
host.unix_ms = function() return 1792800000000 + host._millis_counter end
order(15)
local e = poll()
assert(e.pilot_a == 12 and e.dynamic_limit_a == 15, "pilot and dynamic setting must stay distinct")
assert(e.pilot_confirmed_at_ms == host.unix_ms(), "specific pilot confirmation missing")
local original = e.pilot_observed_at
later(61000)
e = poll()
assert(e.pilot_observed_at == original and e.pilot_confirmed_at_ms == host.unix_ms(), "unchanged pilot must be reconfirmed by REST")
later(91000)
e = poll({pilot=false, alloc=false})
assert(e.pilot_a == nil and e.pilot_confirmed_at_ms == 0, "other fresh readings refreshed a missing pilot")
e = poll({pilot=0, pilot_at="23:55:00", kw=0, power_at="23:55:10"})
assert(e.pilot_a == 0 and e.current_limit_a == nil, "zero pilot must not invent an explained limitation")
local list = obs({power_at="23:56:10"})
for _, o in ipairs(list) do if o.id == 114 then o.timestamp = "2099-01-01T00:00:00Z" end end
host._http_responses["/observations?ids="] = host.json_encode(list)
driver_poll()
e = (host._emitted.ev or {})[#host._emitted.ev]
assert(e.pilot_a == nil, "future pilot emitted as usable evidence")
print("pilot freshness and separate setting: passed")
