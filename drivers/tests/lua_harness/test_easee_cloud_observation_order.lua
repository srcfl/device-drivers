dofile("drivers/tests/lua_harness/host_mock.lua")
host.reset()
host._millis_step = 0
host._http_responses["/accounts/login"] = '{"accessToken":"test","expiresIn":3600}'
host._http_responses["/config"] = '{"maxChargerCurrent":16}'
host._http_responses["/sessions/ongoing"] = '{}'
dofile("drivers/lua/easee_cloud.lua")
driver_init({email="test@example.invalid",password="test",serial="TEST123"})
local function poll(w, stamp, mode)
 host._http_responses["/observations?ids="] = host.json_encode({
  {id=109,value=mode or 3,timestamp="2026-10-17T03:49:10Z"},
  {id=120,value=w,timestamp=stamp},
  {id=121,value=12.5,timestamp="2026-10-17T03:49:10Z"},
 })
 driver_poll()
 local rows=host._emitted.ev or {}
 return #rows, rows[#rows]
end
local count, row = poll(10.242,"2026-10-17T03:49:08.1Z")
assert(count==1 and row.w==10242,"initial measured power missing")
local n = poll(0,"2026-10-17T03:49:07Z")
assert(n==count,"older cloud zero replaced a newer power observation")
n = poll(0,"2026-10-17T05:49:08.1000000+02:00")
assert(n==count,"contradictory value at the same physical time was accepted")
n = poll(0,nil)
assert(n==count,"missing source time became fresh zero power")
n = poll(0,"invalid")
assert(n==count,"malformed source time became fresh power")
n = poll(0,"2026-02-30T03:49:08Z")
assert(n==count,"impossible date was accepted")
n,row = poll(10.242,"2026-10-17T05:49:08.1000000+02:00")
assert(n==count+1 and row.control_power_confirmed,"unchanged valid sample no longer confirmed")
count=n
n,row = poll(0,"2026-10-17T03:49:09.1Z",4)
assert(n==count+1 and row.w==0,"a newer observed stop was ignored")
count=n
n = poll(10.242,"2026-10-17T03:49:08.1Z")
assert(n==count,"old positive power resurrected a stopped charge")
n,row = poll(6.2,"2026-10-17T03:49:10Z")
assert(n==count+1 and row.w==6200,"fresh subsequent power did not recover")

-- Additions in easee_cloud 1.4.1. Each reply below is five seconds apart.
local function later(ms) host._millis_counter = host._millis_counter + ms end
local function fresh()
 host.reset()
 host._millis_step = 0
 host._http_responses["/accounts/login"] = '{"accessToken":"test","expiresIn":3600}'
 host._http_responses["/config"] = '{"maxChargerCurrent":16}'
 host._http_responses["/sessions/ongoing"] = '{}'
 dofile("drivers/lua/easee_cloud.lua")
 driver_init({email="test@example.invalid",password="test",serial="TEST123"})
end
local function emitted() return #(host._emitted.ev or {}) end

-- An impossible date is unreadable, not just older.
fresh()
poll(4.2,"2026-02-30T03:49:08Z")
assert(emitted()==0,"an impossible date was read as a time")

-- A time Core cannot read is not used for 30 s, then used as before, so an
-- odd stamp format cannot keep the driver silent.
fresh()
count = poll(10.242,"2026-10-17T03:49:08Z")
for i=1,6 do later(5000); n = poll(10.242,"2026-10-17T03:49:20") end
assert(n==count,"an unreadable time was used before 30 s")
later(5000); n = poll(10.242,"2026-10-17T03:49:20")
assert(n==count+1,"an unreadable time kept the driver silent past 30 s")
later(5000); n = poll(9.1,"2026-10-17T03:49:25")
assert(n==count+2,"replies stopped again while the time stays unreadable")
later(5000); n = poll(9.0,"2026-10-17T03:49:30Z")
assert(n==count+3,"a readable time after them was not used")
-- Now and then a failed poll among them does not hold the driver silent.
fresh()
count = poll(10.242,"2026-10-17T03:49:08Z")
for i=1,12 do
 later(5000)
 if i % 4 == 0 then host._http_responses["/observations?ids="] = nil; driver_poll()
 else n = poll(10.242,"2026-10-17T03:49:20") end
end
assert(n>count,"failed polls among unreadable replies kept the driver silent")

-- A late "disconnected" reply is held to the same order.
fresh()
count = poll(10.242,"2026-10-17T03:49:08Z")
later(5000); n, row = poll(0,"2026-10-17T03:40:00Z",1)
assert(n==count,"a late disconnected reply was used")
-- A real disconnect starts the order again: after a reboot the charger's
-- next session may carry older times.
later(5000); n, row = poll(0,"2026-10-17T03:49:30Z",1)
assert(n==count+1 and row.connected==false,"a disconnect was not used")
later(5000); n = poll(4.1,"2026-10-17T03:30:00Z")
assert(n==count+2,"the order did not start again after a disconnect")

-- The 30 s count is of replies that go back one after another: a good reply
-- in between, or a failed poll, starts it again.
fresh()
count = poll(10.242,"2026-10-17T03:49:08Z")
later(5000); n = poll(0,"2026-10-17T03:49:00Z")
assert(n==count)
later(10000); n = poll(10.242,"2026-10-17T03:49:08Z")
assert(n==count+1)
later(20000); n = poll(0,"2026-10-17T03:49:00Z")
assert(n==count+1,"an earlier rejection counted toward the 30 s after a good reply")
host._http_responses["/observations?ids="] = nil
for i=1,12 do later(5000); driver_poll() end
later(5000); n = poll(0,"2026-10-17T03:49:00Z")
assert(n==count+1,"a rejection before an outage counted toward the 30 s")

-- A rejected reply does not cost one of the ten session checks an hour.
fresh()
local session = host.json_encode({Id=7,Start="2026-10-17T01:00:00.000Z",MeterValue=1})
host._http_responses["/sessions/ongoing"] = host.json_encode({sessionId=7,sessionStart="2026-10-17T01:00:00Z"})
local function with_session(w, stamp)
 host._http_responses["/observations?ids="] = host.json_encode({
  {id=109,value=3,timestamp="2026-10-17T03:49:10Z"}, {id=120,value=w,timestamp=stamp},
  {id=121,value=12.5,timestamp="2026-10-17T03:49:10Z"}, {id=223,value=session},
 })
 driver_poll()
end
local function lookups()
 local k=0
 for _, call in ipairs(host._calls) do
  if call.func=="http_get" and tostring(call.args[1]):find("/sessions/ongoing",1,true) then k=k+1 end
 end
 return k
end
with_session(10.242,"2026-10-17T03:49:08Z")
for i=1,4 do
 later(5000); with_session(0,"2026-10-17T03:49:00Z")
 later(60000); with_session(10.242,"2026-10-17T03:49:08Z")
end
assert(lookups()==1,"rejected replies made the driver check the session again: "..lookups())
print("Easee observation ordering: passed")
