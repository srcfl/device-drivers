dofile("drivers/tests/lua_harness/host_mock.lua")
local driver = "drivers/lua/easee_cloud.lua"
local serial = "TEST123"
local start = "2026-01-01T08:00:00.000Z"
local function boot(ended)
    host.reset()
    host._http_responses["/accounts/login"] = '{"accessToken":"test","expiresIn":3600}'
    host._http_responses["/config"] = '{}'
    host._http_responses["/sessions/ongoing"] = host.json_encode({sessionId=100,sessionStart="2026-01-01T08:00:00Z",sessionEnd=ended and "2026-01-01T09:00:00Z" or nil})
    dofile(driver)
    driver_init({email="test@example.invalid",password="test",serial=serial})
end
local function poll(mode, session, energy, lifetime)
    local obs = {
        {id=109,value=mode}, {id=120,value=mode == 3 and 4.3 or 0},
        {id=121,value=energy or 9}, {id=124,value=lifetime or 1009},
    }
    if session ~= nil then table.insert(obs,{id=223,value=session}) end
    host._http_responses["/observations?ids="] = host.json_encode(obs)
    driver_poll()
    local rows=host._emitted.ev
    assert(rows and #rows>0, "no EV sample")
    return rows[#rows]
end
local canonical = "100:2026-01-01T08:00:00Z"
local current = host.json_encode({Id=100,Start=start,MeterValue=1000})
boot()
assert(poll(3,current).session_id == canonical,"current session missing")
assert(poll(4,current).session_id == canonical,"car stopping erased its session")
boot()
assert(poll(3,current).session_id == canonical,"identity changed on driver restart")
assert(poll(2,current).session_id == canonical,"a pause lost the confirmed session")
assert(poll(6,current).session_id == canonical,"ready mode lost the confirmed session")
boot()
assert(poll(2,current).session_id == canonical,"paused open session was not verified after restart")
boot(true)
assert(poll(2,current).session_id == canonical,"sessionEnd during a pause blocked restoration")
boot(true)
assert(poll(3,current).session_id == canonical,"sessionEnd during charging blocked restoration")
boot()
assert(poll(3,current,9,1000).session_id == canonical,"lagging lifetime counter blocked a verified active session")
for i=1,20 do assert(poll(3,current).session_id == canonical) end
local lookups=0
for _, call in ipairs(host._calls) do
    if call.func=="http_get" and call.args[1]:find("/sessions/ongoing",1,true) then lookups=lookups+1 end
end
assert(lookups==1,"validated session repeatedly queried the rate-limited API")
local next = host.json_encode({Id=101,Start="2026-01-02T08:00:00.000Z",MeterValue=1009})
host._millis_counter = host._millis_counter + 60000
host._http_responses["/sessions/ongoing"] = host.json_encode({sessionId=101,sessionStart="2026-01-02T08:00:00Z"})
assert(poll(3,next,1,1010).session_id == "101:2026-01-02T08:00:00Z","new session did not get its own verified identity")
assert(poll(1,current).session_id == nil,"disconnected charger has session identity")
assert(poll(3,current,1,1010).session_id == nil,"a prior session bypassed active-session confirmation")
assert(poll(3,nil).session_id == nil,"missing identity invented")
assert(poll(3,'not-json').session_id == nil,"malformed identity accepted")
assert(poll(3,'{"Id":100,"Start":"yesterday","MeterValue":1000}').session_id == nil,"invalid session time accepted")

local before = #host._emitted.ev
host._http_responses["/observations?ids="] = '{}'
driver_poll()
assert(#host._emitted.ev == before,"empty observations invented an unplug")
host._http_responses["/observations?ids="] = 'not-json'
driver_poll()
assert(#host._emitted.ev == before,"broken JSON invented fresh telemetry")
host._http_responses["/observations?ids="] = nil
driver_poll()
assert(#host._emitted.ev == before,"failed read invented fresh telemetry")
boot()
host._http_responses["/sessions/ongoing"] = host.json_encode({sessionId=99,sessionStart="2026-01-01T08:00:00Z"})
for i=1,59 do
    host._millis_counter = host._millis_counter + 61000
    assert(poll(3,current).session_id == nil,"mismatched session accepted during retries")
end
lookups=0
for _, call in ipairs(host._calls) do
    if call.func=="http_get" and call.args[1]:find("/sessions/ongoing",1,true) then lookups=lookups+1 end
end
assert(lookups==10,"ongoing-session API exceeded ten requests per hour: "..lookups)

-- Stopping energy flow is not removing the cable. A real observed unplug
-- does revoke this identity even if the cloud endpoints still carry old data.
boot(true)
assert(poll(3,current).session_id == canonical)
assert(poll(4,current).session_id == canonical,"car pause lost its identity")
assert(poll(2,current).session_id == canonical,"waiting car lost its identity")
assert(poll(6,current).session_id == canonical,"ready car lost its identity")
assert(poll(1,current).session_id == nil,"unplug retained identity")
host._millis_counter = host._millis_counter + 61000
assert(poll(2,current).session_id == nil,"new connection reused departed session")
host._http_responses["/sessions/ongoing"] = host.json_encode({sessionId=101,sessionStart="2026-01-02T08:00:00Z"})
assert(poll(3,next,1,1010).session_id == "101:2026-01-02T08:00:00Z","new active session did not regain proof")

-- The two APIs may encode the same UTC instant differently.
for _, pair in ipairs({
    {observation="2026-01-01T08:00:00.000+00:00", ongoing="2026-01-01T08:00:00Z"},
    {observation="2026-01-01T08:00:00Z", ongoing="2026-01-01T08:00:00.000+00:00"},
}) do
    boot()
    host._http_responses["/sessions/ongoing"] = host.json_encode({sessionId=100,sessionStart=pair.ongoing})
    local observation = host.json_encode({Id=100,Start=pair.observation})
    assert(poll(3,observation).session_id == canonical,"equivalent UTC times did not match")
end
boot()
host._http_responses["/sessions/ongoing"] = host.json_encode({sessionId=100,sessionStart="2026-01-01T08:00:01.000+00:00"})
assert(poll(3,current).session_id == nil,"different start times passed session proof")

-- Valid JSON can still have the wrong shape. Keep fresh charger readings
-- when either session endpoint sends a scalar or a document without an ID.
for _, payload in ipairs({"true", "false", "42", '"error"', "null", "[]", "{}"}) do
    boot()
    local sample = poll(3, payload)
    assert(sample.session_id == nil, "wrong-shaped observation accepted: " .. payload)
    assert(sample.connected and sample.w == 4300, "session payload dropped fresh charger readings")

    boot()
    host._http_responses["/sessions/ongoing"] = payload
    sample = poll(3, current)
    assert(sample.session_id == nil, "wrong-shaped ongoing session accepted: " .. payload)
    assert(sample.connected and sample.w == 4300, "ongoing payload dropped fresh charger readings")
end
print("Easee current-session identity: passed")

boot()
host._http_responses["/observations?ids="] = host.json_encode({
 {id=109,value=3,timestamp="2026-01-01T08:02:00Z"},
 {id=120,value=6.9,timestamp="2026-01-01T08:03:00Z"},
 {id=121,value=9,timestamp="2026-01-01T08:00:00Z"},
 {id=96,value=5,timestamp="2026-01-01T08:01:00Z"},
 {id=223,value=current},
})
driver_poll()
local sample=host._emitted.ev[#host._emitted.ev]
assert(sample.power_observed_at == "2026-01-01T08:03:00Z")
assert(sample.power_max_age_s == 180)
assert(sample.energy_observed_at == "2026-01-01T08:00:00Z")
assert(sample.state_observed_at == "2026-01-01T08:02:00Z")
assert(sample.reason_observed_at == "2026-01-01T08:01:00Z")
assert(sample.reason_no_current == nil and sample.reason_no_current_label == nil, "charging reported an old no-current reason")

local emitted=#host._emitted.ev
host._http_responses["/observations?ids="] = host.json_encode({{id=109,value=0}})
driver_poll()
assert(#host._emitted.ev == emitted,"cloud offline state invented an unplug")

boot()
host._http_responses["/observations?ids="] = host.json_encode({
 {id=109,value=3,timestamp="2026-01-01T08:02:00Z"},
 {id=120,value=6.9,timestamp="2026-01-01T08:03:00Z"},
 {id=121,value=9,timestamp="2026-01-01T08:00:00Z"},
 {id=96,value=5,timestamp="2026-01-01T08:04:00Z"},
})
driver_poll()
sample=host._emitted.ev[#host._emitted.ev]
assert(sample.reason_no_current == 5, "old power hid a newer no-current reason")

-- A car may be replaced while the charger is offline. Historical observation
-- 223 must not reuse proof from before the outage when telemetry returns.
for _, failed in ipairs({host.json_encode({{id=109,value=0}}), 'not-json', '{}'}) do
    boot()
    assert(poll(3,current).session_id == canonical)
    local count=#host._emitted.ev
    host._http_responses["/observations?ids="] = failed
    driver_poll()
    assert(#host._emitted.ev == count,"outage emitted a new physical state")
    host._millis_counter = host._millis_counter + 61000
    host._http_responses["/sessions/ongoing"] = host.json_encode({sessionId=101,sessionStart="2026-01-02T08:00:00Z"})
    assert(poll(2,current).session_id == nil,"offline proof restored an old vehicle")
    host._millis_counter = host._millis_counter + 61000
    assert(poll(3,next,1,1010).session_id == "101:2026-01-02T08:00:00Z","current vehicle did not regain proof")
end

-- Mismatched paused telemetry must leave quota for when charging starts.
boot()
host._http_responses["/sessions/ongoing"] = '{}'
for i=1,10 do
    assert(poll(2,current).session_id == nil)
    host._millis_counter = host._millis_counter + 61000
end
lookups=0
for _, call in ipairs(host._calls) do
    if call.func=="http_get" and call.args[1]:find("/sessions/ongoing",1,true) then lookups=lookups+1 end
end
assert(lookups <= 2,"paused retries exhausted the lookup quota: "..lookups)
host._http_responses["/sessions/ongoing"] = host.json_encode({sessionId=100,sessionStart="2026-01-01T08:00:00Z"})
assert(poll(3,current).session_id == canonical,"charging could not verify its session after paused retries")
