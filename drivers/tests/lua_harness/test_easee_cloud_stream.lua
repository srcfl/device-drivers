dofile("drivers/tests/lua_harness/host_mock.lua")
-- Easee's SignalR stream: the handshake, a pushed update, REST once a
-- minute, reconnects, and the REST fallback and back. host_mock.lua fakes
-- FTW's host.ws_* functions.
local driver = "drivers/lua/easee_cloud.lua"
local RS = "\30"
local SERIAL = "EH123456"

local function later(ms) host._millis_counter = host._millis_counter + ms end
local function poll(ms) later(ms or 0); return driver_poll() end

local function count(func, needle)
    local n = 0
    for _, call in ipairs(host._calls) do
        if call.func == func and (needle == nil or tostring(call.args[1]):find(needle, 1, true)) then
            n = n + 1
        end
    end
    return n
end
local function rest_reads() return count("http_get", "/observations?ids=") end
local function attempts() return count("ws_open") end

-- http_calls_to counts HTTP requests of any kind to a host.
local function http_calls_to(name)
    local n = 0
    for _, call in ipairs(host._calls) do
        local target = call.args[1]
        if type(target) == "table" then target = target.url end
        if (call.func == "http_get" or call.func == "http_post" or call.func == "http_request") and
            tostring(target):find(name, 1, true) then
            n = n + 1
        end
    end
    return n
end

local function samples()
    local rows = host._emitted.ev or {}
    return rows[#rows], #rows
end

local function rest(mode, power_kw, at)
    host._http_responses["/observations?ids="] = host.json_encode({
        {id=109, value=mode, timestamp="2026-10-24T09:00:00Z"},
        {id=120, value=power_kw, timestamp=at},
        {id=121, value=12.5, timestamp=at},
    })
end

-- push queues one WebSocket frame holding the given SignalR messages.
local function push(...)
    local frame = ""
    for _, m in ipairs({...}) do
        frame = frame .. (type(m) == "string" and m or host.json_encode(m)) .. RS
    end
    table.insert(host._ws_inbox, frame)
end

local function update(id, value, at, mid)
    return {type=1, target="ProductUpdate",
        arguments={{mid=mid or SERIAL, dataType=3, id=id, timestamp=at, value=value}}}
end

local function sent(i)
    local text = host._ws_sent[i]
    assert(text and text:sub(-1) == RS, "frame " .. i .. " missing or without the record separator")
    return host.json_decode(text:sub(1, -2)), text
end

local function setup(granted, serial)
    host.reset()
    host._millis_step = 0
    host._ws_granted = granted
    host._http_responses["/accounts/login"] =
        '{"accessToken":"tok-a","refreshToken":"ref-a","expiresIn":3600}'
    host._http_responses["/config"] = '{"maxChargerCurrent":16}'
    host._http_responses["/sessions/ongoing"] = '{}'
    rest(3, 7.2, "2026-10-24T10:00:00Z")
    dofile(driver)
    driver_init({email="test@example.invalid", password="test", serial=serial or SERIAL})
end

-- tick is a stream poll: the server's ping, then 2 s.
local function tick() push('{"type":6}'); return poll(2000) end

local function until_rest()
    local before = rest_reads()
    repeat tick() until rest_reads() > before
end

local function logged(text)
    for _, line in ipairs(host._logs) do
        if line:find(text, 1, true) then return true end
    end
    return false
end

-- connect walks a fresh driver from the first poll to a stream that is up.
local function connect()
    local first = #host._ws_sent
    assert(poll() == 5000, "a stream that is not up yet changed the REST cadence")
    local _, handshake = sent(first + 1)
    assert(handshake == '{"protocol":"json","version":1}' .. RS, "wrong handshake: " .. handshake)
    push("{}")
    assert(poll(5000) == 5000)
    local sub = sent(first + 2)
    assert(sub.type == 1 and sub.target == "SubscribeWithCurrentState", "no subscription")
    assert(sub.arguments[1] == SERIAL and sub.arguments[2] == true, "subscription lacks serial or current state")
    push(update(109, "3", "2026-10-24T10:00:01Z"), update(120, "7.2", "2026-10-24T10:00:01Z"),
        {type=3, invocationId=sub.invocationId})
    assert(poll(5000) == 2000, "stream did not come up")
end

-- 1. Without a WebSocket grant the driver polls REST every 5 s, as before,
-- and gives up the stream after one try.
setup(false)
assert(poll() == 5000)
for _ = 1, 5 do assert(poll(5000) == 5000) end
assert(attempts() == 1, "retried the stream without a grant")
assert(http_calls_to("streams.easee.com") == 0, "sent HTTP to the stream host")
assert(rest_reads() == 6, "REST did not read on every poll")
local granted_hint = false
for _, line in ipairs(host._logs) do
    if line:find("capabilities.websocket", 1, true) then granted_hint = true end
end
assert(granted_hint, "the log does not say how to enable the stream")

-- 2. Open, handshake and subscribe.
setup(true)
connect()
-- No negotiate: a WebSocket connects directly, so no load-balancer cookie
-- has to match a negotiated token.
assert(http_calls_to("streams.easee.com") == 0, "negotiated before connecting")
assert(host._ws_url == "wss://streams.easee.com/hubs/products", host._ws_url)
assert(host._ws_headers.Authorization == "Bearer tok-a", "stream opened without the access token")

-- 3. A pushed change reaches the next sample with its source time, without
-- a REST read; an unchanged value is confirmed as before.
local reads = rest_reads()
push(update(120, "3.5", "2026-10-24T10:00:30Z"))
assert(poll(2000) == 2000)
local ev = samples()
assert(ev.w == 3500 and ev.charging, "pushed power did not reach the sample")
assert(ev.power_observed_at == "2026-10-24T10:00:30Z", "a pushed change lost its source time")
assert(ev.control_power_observed_at == "2026-10-24T10:00:30Z" and ev.control_power_confirmed,
    "a pushed change is not control evidence")
assert(ev.power_max_age_s == 180, "power_max_age_s changed")
poll(2000)
local steady = samples()
assert(steady.power_observed_at == nil and steady.control_power_confirmed,
    "an unchanged streamed value is not confirmed")
assert(steady.control_power_observed_at == "2026-10-24T10:00:30Z", "unchanged power became a new sample")
assert(rest_reads() == reads, "REST read while the stream was up")

-- Values arrive as strings; other chargers and other ids are ignored.
push(update(103, "True", "2026-10-24T10:00:31Z"), update(120, "9.9", "2026-10-24T10:00:32Z", "EH999999"),
    update(500, "1", "2026-10-24T10:00:32Z"))
poll(2000)
ev = samples()
assert(ev.cable_locked == true, "a streamed boolean was not read")
assert(ev.w == 3500, "an update for another charger changed this one")

-- 4. REST reads once a minute while the stream is up. Its older power
-- sample does not replace the newer pushed one.
for _ = 1, 30 do push('{"type":6}'); poll(2000) end
assert(rest_reads() == reads + 1, "REST did not read once a minute: " .. (rest_reads() - reads))
ev = samples()
assert(ev.w == 3500, "an older REST sample replaced a newer pushed one")
local pings = 0
for _, text in ipairs(host._ws_sent) do if text == '{"type":6}' .. RS then pings = pings + 1 end end
assert(pings >= 3, "the driver did not ping the server")

-- REST spelling the same instant differently is not a new sample.
rest(3, 3.5, "2026-10-24T10:00:30.000+00:00")
for _ = 1, 30 do push('{"type":6}'); poll(2000) end
ev = samples()
assert(rest_reads() == reads + 2, "REST did not read in the second minute")
assert(ev.power_observed_at == nil and ev.control_power_observed_at == "2026-10-24T10:00:30Z",
    "a re-spelled source time became a new sample: " .. tostring(ev.control_power_observed_at))

-- 5. The server closes the stream: REST every poll until a reconnect,
-- which the driver tries 5 s later.
host._ws_server_close()
reads = rest_reads()
local negs = attempts()
assert(poll(2000) == 5000, "a closed stream kept the stream cadence")
assert(rest_reads() == reads + 1, "no REST read after the stream closed")
local _, before = samples()
assert(poll(5000) == 5000)
assert(attempts() == negs + 1, "no reconnect after 5 s")
local _, after = samples()
assert(after == before + 1 and rest_reads() == reads + 2, "REST fallback did not report")
push("{}")
poll(5000)
local resub = sent(#host._ws_sent)
push({type=3, invocationId=resub.invocationId})
assert(poll(5000) == 2000, "the stream did not come back")

-- 6. A stream that goes silent falls back to REST.
reads = rest_reads()
local silent_polls = 0
while poll(2000) == 2000 do
    silent_polls = silent_polls + 1
    assert(silent_polls < 40, "a silent stream stayed up")
end
assert(silent_polls >= 28, "dropped a quiet stream too soon: " .. silent_polls)

-- Failed reconnects back off: 5 s, then 10 s.
host._ws_open_error = "ws dial: websocket: bad handshake (HTTP 401)"
negs = attempts()
local tries = {}
for t = 1, 20 do
    poll(1000)
    if attempts() > negs then tries[#tries + 1] = t; negs = attempts() end
end
assert(#tries == 2 and tries[2] - tries[1] == 10, "no back-off between failed reconnects")
local open_failed = false
for _, line in ipairs(host._logs) do
    assert(not line:find("tok-a", 1, true), "access token in the log: " .. line)
    if line:find("bad handshake (HTTP 401)", 1, true) then open_failed = true end
end
assert(open_failed, "the failed open was not logged")

-- 7. While the stream is up, a REST read vouches for 90 s. With REST down
-- the driver stops reporting after that, as it does without the stream.
setup(true)
connect()
host._http_responses["/observations?ids="] = nil
local _, rows = samples()
local reported = 0
for _ = 1, 60 do
    push('{"type":6}')
    poll(2000)
    local _, n = samples()
    if n > rows then reported = reported + 1; rows = n end
end
assert(reported > 0 and reported <= 43, "reported without a REST read for too long: " .. reported)
local _, frozen = samples()
push('{"type":6}')
poll(2000)
assert(select(2, samples()) == frozen, "kept reporting without a REST read")
rest(3, 7.2, "2026-10-24T10:00:00Z")
for _ = 1, 6 do push('{"type":6}'); poll(2000) end
assert(select(2, samples()) > frozen, "a good REST read did not resume reporting")

-- REST answering that the cloud lost the charger stops reports at once.
rest(0, 7.2, "2026-10-24T10:00:00Z")
for _ = 1, 40 do push('{"type":6}'); poll(2000) end
_, frozen = samples()
push('{"type":6}')
poll(2000)
assert(select(2, samples()) == frozen, "reported a charger the cloud no longer hears")

-- 8. A renewed access token reconnects the stream with it.
setup(true)
connect()
host._http_responses["/accounts/refresh_token"] =
    '{"accessToken":"tok-b","refreshToken":"ref-b","expiresIn":3600}'
negs = attempts()
later(3541000)
poll()
assert(attempts() == negs + 1, "a renewed token did not reconnect the stream")
assert(host._ws_headers.Authorization == "Bearer tok-b", "the stream kept the old token")

-- 9. A refused subscription stops the stream and REST carries on.
setup(true)
poll()
push("{}")
poll(5000)
push({type=3, invocationId=sent(2).invocationId, error="Not authorized"})
reads = rest_reads()
assert(poll(5000) == 5000, "a refused subscription came up")
assert(rest_reads() == reads + 1, "REST stopped after a refused subscription")
assert(not host._ws_is_open, "a refused stream stayed open")

-- 10. Without the stream a REST reply is the whole state, as in 1.3.8: an
-- id it leaves out does not keep an earlier reply's value. A reply whose
-- power time goes back is not used (srcfl/device-drivers#183), but a stamp
-- from the future holds a value for 30 s at most.
setup(false)
poll()
host._http_responses["/observations?ids="] = host.json_encode({
    {id=109, value=1, timestamp="2026-10-24T10:01:00Z"},
})
poll(5000)
ev = samples()
assert(ev.connected == false and ev.w == 0 and ev.session_wh == 0, "an omitted id kept its old value")
assert(ev.control_power_available == false and ev.control_power_confirmed == false,
    "an omitted power reading was confirmed")
rest(3, 7.2, "2026-10-24T13:00:00Z")
poll(5000)
rest(3, 0, "2026-10-24T10:05:00Z")
local _, held = samples()
poll(5000)
local _, after_back = samples()
assert(after_back == held, "a reply whose power time went back was used")
for _ = 1, 5 do poll(5000) end
assert(samples().w == 7200, "the order started again before 30 s")
poll(5000)
assert(samples().w == 0, "a REST stamp from the future held its value for over 30 s")

-- 11. A change REST sees first is owed by the stream. A push still on its
-- way keeps the stream up; one that never comes stops it after 10 s.
setup(true)
connect()
rest(3, 5.0, "2026-10-24T10:00:40Z")
until_rest()
assert(samples().w == 5000, "REST's newer value was not used")
push(update(120, "5.0", "2026-10-24T10:00:40Z"))
for _ = 1, 8 do assert(tick() == 2000, "a push on its way stopped the stream") end
rest(3, 6.0, "2026-10-24T10:01:40Z")
until_rest()
local waited = 0
while tick() == 2000 do
    waited = waited + 1
    assert(waited < 10, "a stream that missed a change stayed up")
end
assert(waited == 4, "a missed change stopped the stream after " .. waited .. " polls, not 10 s")
assert(logged("missed a change REST saw"), "the missed change was not logged")

-- 12. A pushed reading Core cannot read is skipped and owed; a pushed
-- op_mode 0 stops reports and says why.
setup(true)
connect()
push(update(120, "", "2026-10-24T10:00:50Z"), update(121, "13.0", "2026-10-24 10:00:50"))
tick()
ev = samples()
assert(ev.w == 7200 and ev.session_wh == 12500, "an unreadable push changed the sample")
waited = 0
while tick() == 2000 do
    waited = waited + 1
    assert(waited < 10, "an unreadable push left the stream up")
end
setup(true)
connect()
local _, shown = samples()
push(update(109, "0", "2026-10-24T10:00:50Z"))
tick()
assert(select(2, samples()) == shown, "reported a charger the stream says is offline")
assert(logged("not reporting streamed state: charger offline"), "the stop was not logged")

-- 13. Protocol edges: a message split across frames, a close message, a
-- refused handshake, a subscription that never completes, and a
-- connection the host reports closed without the end marker.
setup(true)
poll()
push("{}")
poll(5000)
local whole = host.json_encode(update(120, "4.4", "2026-10-24T10:00:02Z")) .. RS
table.insert(host._ws_inbox, whole:sub(1, 20))
table.insert(host._ws_inbox, whole:sub(21) .. host.json_encode({type=3, invocationId=sent(2).invocationId}) .. RS)
assert(poll(5000) == 2000, "the stream did not come up")
assert(samples().w == 4400, "a message split across frames was lost")
push({type=7, error="Server is shutting down", allowReconnect=true})
assert(poll(2000) == 5000, "a close message did not stop the stream")
assert(logged("server closed: Server is shutting down"), "the close was not logged")

setup(true)
poll()
push({error="Requested protocol 'json' is not available"})
assert(poll(5000) == 5000 and not host._ws_is_open, "a refused handshake stayed open")
assert(logged("handshake refused"), "the refused handshake was not logged")

setup(true)
poll()
for _ = 1, 5 do poll(5000) end
assert(host._ws_is_open, "gave up on the subscription before 30 s")
poll(5000)
assert(not host._ws_is_open, "a stream that never subscribed stayed open")

setup(true)
connect()
host._ws_is_open = false
assert(tick() == 5000, "a connection the host reports closed stayed up")

-- 14. A lower-case serial in the config subscribes in upper case and
-- matches Easee's mid.
setup(true, "eh123456")
connect()
push(update(120, "1.1", "2026-10-24T10:00:03Z"))
tick()
assert(samples().w == 1100, "an update for the configured charger was ignored")

-- 15. A WebSocket allowlist without streams.easee.com disables the stream.
setup(true)
host._ws_allowed_hosts = {"websocket-api.tibber.com"}
poll()
for _ = 1, 3 do poll(5000) end
assert(count("ws_open") == 1 and not host._ws_is_open, "retried a host the allowlist refuses")
assert(logged("no SignalR stream (no WebSocket grant)"), "the refusal was not logged")

-- 16. Only state, power and energy are owed; REST's diagnostic readings
-- may change without a push. A push of the owed value settles the debt
-- even with a coarser time.
local function rest_with_voltage(volts, at)
    host._http_responses["/observations?ids="] = host.json_encode({
        {id=109, value=3, timestamp="2026-10-24T10:00:01Z"},
        {id=120, value=7.2, timestamp="2026-10-24T10:00:01Z"},
        {id=121, value=12.5, timestamp="2026-10-24T10:00:00Z"},
        {id=194, value=volts, timestamp=at},
    })
end
setup(true)
rest_with_voltage(230.0, "2026-10-24T10:00:00Z")
connect()
rest_with_voltage(231.5, "2026-10-24T10:00:55Z")
until_rest()
for _ = 1, 8 do assert(tick() == 2000, "a diagnostic reading REST saw first stopped the stream") end
assert(samples().w == 7200, "the diagnostic-only REST read changed power")
host._http_responses["/observations?ids="] = host.json_encode({
    {id=109, value=3, timestamp="2026-10-24T10:00:01Z"},
    {id=120, value=5.5, timestamp="2026-10-24T10:01:40.500Z"},
    {id=121, value=12.5, timestamp="2026-10-24T10:00:00Z"},
})
until_rest()
push(update(120, "5.5", "2026-10-24T10:01:40Z"))
for _ = 1, 8 do assert(tick() == 2000, "a push of the owed value with a coarser time stopped the stream") end

-- Once up, the stream's order wins: a pushed sample applies even when its
-- time is older than the one before it.
push(update(120, "4.0", "2026-10-24T10:01:30Z"))
tick()
assert(samples().w == 4000, "a pushed sample did not apply")

-- The replayed current state does not undo a newer REST read.
setup(true)
rest(3, 0, "2026-10-24T10:00:05Z")
connect()
ev = samples()
assert(ev.w == 0, "the replay replaced a newer REST read: " .. tostring(ev.w))

-- 17. An older ReasonForNoCurrent is hidden while the car charges, also
-- when the two times are written with different precision.
setup(false)
host._http_responses["/observations?ids="] = host.json_encode({
    {id=96, value=100, timestamp="2026-10-24T10:00:30Z"},
    {id=109, value=3, timestamp="2026-10-24T10:00:00Z"},
    {id=120, value=7.2, timestamp="2026-10-24T10:00:30.120Z"},
    {id=121, value=12.5, timestamp="2026-10-24T10:00:30.120Z"},
})
poll()
assert(samples().reason_no_current == nil, "an older reason showed while charging")

print("Easee SignalR stream: passed")
