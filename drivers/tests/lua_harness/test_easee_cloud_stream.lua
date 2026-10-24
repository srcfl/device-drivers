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
local function negotiations() return count("http_post", "/negotiate") end

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

local function setup(granted)
    host.reset()
    host._millis_step = 0
    host._ws_granted = granted
    host._http_responses["/accounts/login"] =
        '{"accessToken":"tok-a","refreshToken":"ref-a","expiresIn":3600}'
    host._http_responses["/config"] = '{"maxChargerCurrent":16}'
    host._http_responses["/sessions/ongoing"] = '{}'
    host._http_responses["/negotiate?negotiateVersion=1"] =
        '{"negotiateVersion":1,"connectionId":"c-1","connectionToken":"ct/1+",' ..
        '"availableTransports":[{"transport":"WebSockets","transferFormats":["Text","Binary"]}]}'
    rest(3, 7.2, "2026-10-24T10:00:00Z")
    dofile(driver)
    driver_init({email="test@example.invalid", password="test", serial=SERIAL})
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
assert(negotiations() == 1 and count("ws_open") == 1, "retried the stream without a grant")
assert(rest_reads() == 6, "REST did not read on every poll")
local granted_hint = false
for _, line in ipairs(host._logs) do
    if line:find("capabilities.websocket", 1, true) then granted_hint = true end
end
assert(granted_hint, "the log does not say how to enable the stream")

-- 2. Negotiate, open, handshake and subscribe.
setup(true)
connect()
local neg
for _, call in ipairs(host._calls) do
    if call.func == "http_post" and call.args[1]:find("/negotiate", 1, true) then neg = call end
end
assert(neg.args[1] == "https://streams.easee.com/hubs/products/negotiate?negotiateVersion=1", neg.args[1])
assert(neg.args[3].Authorization == "Bearer tok-a", "negotiate without the access token")
assert(host._ws_url == "wss://streams.easee.com/hubs/products?id=ct%2F1%2B", host._ws_url)
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
local negs = negotiations()
assert(poll(2000) == 5000, "a closed stream kept the stream cadence")
assert(rest_reads() == reads + 1, "no REST read after the stream closed")
local _, before = samples()
assert(poll(5000) == 5000)
assert(negotiations() == negs + 1, "no reconnect after 5 s")
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
host._ws_open_error = 'ws dial: Get "wss://streams.easee.com/hubs/products?id=ct%2F1%2B": bad handshake'
negs = negotiations()
local tries = {}
for t = 1, 20 do
    poll(1000)
    if negotiations() > negs then tries[#tries + 1] = t; negs = negotiations() end
end
assert(#tries == 2 and tries[2] - tries[1] == 10, "no back-off between failed reconnects")
local open_failed = false
for _, line in ipairs(host._logs) do
    assert(not line:find("ct%2F1", 1, true) and not line:find("ct/1", 1, true), "connection token in the log: " .. line)
    if line:find("bad handshake", 1, true) then open_failed = true end
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
negs = negotiations()
later(3541000)
poll()
assert(negotiations() == negs + 1, "a renewed token did not reconnect the stream")
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

print("Easee SignalR stream: passed")
