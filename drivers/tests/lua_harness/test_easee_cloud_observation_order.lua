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
print("Easee observation ordering: passed")
