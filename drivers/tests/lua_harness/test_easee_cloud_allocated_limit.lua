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

-- 1. The field trace: allocation and pilot below the 15 A order and newer
-- than it. The allocation explains the pilot, so the load balancer is named.
-- Before FTW's first order after a restart there is no order to be below.
boot()
expect(poll(), nil, nil, "no order from FTW yet")
order(15)
expect(poll(), 12, "load_balancer", "start at 12 A")
expect(poll({pilot=15, alloc={15, 15, 15}, pilot_at="23:55:14", kw=10.37, power_at="23:55:30"}),
    nil, nil, "back at the order")
expect(poll({pilot=14, alloc={14, 14, 14}, pilot_at="00:00:21", kw=9.6, power_at="00:00:25"}),
    14, "load_balancer", "fall to 14 A")
expect(poll({pilot=13, alloc={13, 13, 13}, pilot_at="00:00:32", kw=8.85, power_at="00:00:40"}),
    13, "load_balancer", "fall to 13 A")

-- When Easee lets the car take the order again, the cloud reports the
-- car's old draw for a few seconds; the old limit still applies to it.
later(5000)
expect(poll({pilot=15, alloc={15, 15, 15}, pilot_at="00:01:00", kw=8.85, power_at="00:00:40"}),
    13, "load_balancer", "released, the car not up yet")
later(15000)
expect(poll({pilot=15, alloc={15, 15, 15}, pilot_at="00:01:00", kw=8.85, power_at="00:00:40"}),
    nil, nil, "released 20 s ago")
boot()
order(15)
expect(poll(), 12, "load_balancer", "limited again")
expect(poll({pilot=15, alloc={15, 15, 15}, pilot_at="00:01:00", kw=10.37, power_at="00:01:05"}),
    nil, nil, "released, the car at the order")

-- 2. Below the order, but nothing says why: the current is reported, the
-- cause is not. An allocation above the pilot does not explain it, and an
-- old ReasonForNoCurrent is not proof either.
boot()
order(15)
expect(poll({pilot=13, alloc={15, 15, 15}}), 13, nil, "allocation at the order")
expect(poll({pilot=13, alloc=false}), 13, nil, "no allocation")
expect(poll({pilot=13, alloc=false, reason=29, reason_at="23:40:00"}), 13, nil, "old load-balancing reason")
expect(poll({pilot=13, alloc=false, reason=77, reason_at="23:56:25"}), 13, nil, "charger reason")
expect(poll({pilot=12, alloc={13, 14, 14}}), 12, nil, "allocation above the pilot")

-- 3. A three-phase car takes the lowest phase's share. A one-phase charger
-- uses one phase, which the driver does not know, so the highest counts.
-- A phase with no allocation is not one the car uses.
boot()
order(15)
expect(poll({pilot=12, alloc={12, 14, 14}}), 12, "load_balancer", "lowest phase")
expect(poll({pilot=12, alloc={12, 12, false}}), 12, nil, "three-phase with a phase missing")
expect(poll({pilot=12, alloc={12, 0, 0}}), 12, "load_balancer", "one-phase wiring, three-phase setting")
expect(poll({pilot=8, alloc={12, 0, 0}}), 8, nil, "unused phases do not explain a lower pilot")
boot({phases=1})
order(15, "1p")
expect(poll({pilot=12, alloc={12, 0, 0}}), 12, "load_balancer", "one phase")
expect(poll({pilot=12, alloc={12, 16, 16}}), 12, nil, "one phase, the charger's phase unknown")
expect(poll({pilot=12, alloc={0, 0, 0}}), 12, nil, "one phase, no allocation")

-- 4. At or near the order, not charging, or no positive pilot: no limit.
boot()
order(15)
expect(poll({pilot=15, alloc={15, 15, 15}}), nil, nil, "at the order")
expect(poll({pilot=14.6, alloc={14, 14, 14}, order=15}), nil, nil, "within half an amp")
expect(poll({mode=2, kw=0, pilot=0, alloc={0, 0, 0}, power_at="23:55:00"}), nil, nil, "waiting to start")
expect(poll({mode=3, kw=0, pilot=0, alloc={0, 0, 0}, power_at="23:55:00"}), nil, nil, "zero pilot")
expect(poll({mode=4, kw=0, pilot=12, alloc={12, 12, 12}, power_at="23:55:00"}), nil, nil, "car finished")
expect(poll({order=false, power_at="23:55:00", kw=0}), nil, nil, "no readback of the order")

-- 5. Right after FTW raises the order, an older pilot has not answered it
-- yet. It counts once it changes after the order, or once the order has
-- stood 30 s.
boot()
order(10)
expect(poll({order=10, pilot=10, alloc={10, 10, 10}}), nil, nil, "at the old order")
order(15)
expect(poll({order=15, order_at="23:58:00", pilot=10, alloc={10, 10, 10}}), nil, nil, "not answered yet")
later(29000)
expect(poll({order=15, order_at="23:58:00", pilot=10, alloc={10, 10, 10}}), nil, nil, "29 s")
later(1000)
expect(poll({order=15, order_at="23:58:00", pilot=10, alloc={10, 10, 10}}), 10, "load_balancer", "30 s")
order(16)
expect(poll({order=16, order_at="23:59:00", pilot=12, pilot_at="23:59:04", alloc={12, 12, 12}}),
    12, "load_balancer", "answered at once")
expect(poll({order=16, order_at="23:59:00", pilot=12, pilot_at="23:59:00", alloc={12, 12, 12}}),
    12, "load_balancer", "recorded in the same second as the order")
expect(poll({order=16, order_at="23:59:00", pilot=12, pilot_at="23:59:04", alloc={12, 12, 12},
    alloc_at="23:58:30"}), 12, nil, "allocation older than the new order")

-- 6. While the charger still reads back an older order than FTW's last, the
-- pilot may be following the new one: no limit. Nor is the charger's own
-- static limit its load balancing.
boot()
order(15)
later(60000)
order(10)
expect(poll({order=15, pilot=10, pilot_at="23:58:00", alloc={10, 10, 10}}), nil, nil, "readback still at the old order")
boot(nil, false, '{"maxChargerCurrent":10}')
order(15)
expect(poll({pilot=10, alloc={10, 10, 10}}), 10, nil, "the charger's own 10 A limit")

-- 7. The stream: pushed allocation and pilot reach the next sample.
local function push(...)
    local frame = ""
    for _, m in ipairs({...}) do frame = frame .. (type(m) == "string" and m or host.json_encode(m)) .. RS end
    table.insert(host._ws_inbox, frame)
end
local function update(id, value, clock)
    return {type=1, target="ProductUpdate", arguments={{mid=SERIAL, dataType=3, id=id, timestamp=at(clock), value=value}}}
end
boot(nil, true)
order(15)
host._http_responses["/observations?ids="] = host.json_encode(obs({pilot=15, alloc={15, 15, 15}, kw=10.37}))
driver_poll()
push("{}")
later(5000); driver_poll()
push({type=3, invocationId="0"})
later(5000)
assert(driver_poll() == 2000, "stream did not come up")
push(update(70, "12", "00:00:21"), update(71, "12", "00:00:21"), update(72, "12", "00:00:21"),
    update(114, "12", "00:00:21"))
later(2000); driver_poll()
local rows = host._emitted.ev
expect(rows[#rows], 12, "load_balancer", "pushed allocation and pilot")

print("easee_cloud allocated limit: ok")
