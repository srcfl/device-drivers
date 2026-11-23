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
n = poll(0,"2026-10-17T05:49:08.10000000000+02:00")
assert(n==count,"contradictory value at the same physical time was accepted")
n = poll(0,nil)
assert(n==count,"missing source time became fresh zero power")
n = poll(0,"invalid")
assert(n==count,"malformed source time became fresh power")
n = poll(0,"2026-02-30T03:49:08Z")
assert(n==count,"impossible date was accepted")
n,row = poll(10.242,"2026-10-17T05:49:08.10000000000+02:00")
assert(n==count+1 and row.control_power_confirmed,"unchanged valid sample no longer confirmed")
count=n
n,row = poll(0,"2026-10-17T03:49:09.1Z",4)
assert(n==count+1 and row.w==0,"a newer observed stop was ignored")
count=n
n = poll(10.242,"2026-10-17T03:49:08.1Z")
assert(n==count,"old positive power resurrected a stopped charge")
n,row = poll(6.2,"2026-10-17T03:49:10Z")
assert(n==count+1 and row.w==6200,"fresh subsequent power did not recover")

-- Compare timestamps through the REST poll so both ordering and equality
-- are checked at calendar boundaries.
local boundaries = {
    {
        name = "month end with positive offset",
        older = "2027-04-30T23:59:59Z",
        utc = "2027-05-01T00:00:00Z",
        equivalent = "2027-05-01T05:30:00+05:30",
    },
    {
        name = "leap day with negative offset",
        older = "2028-02-28T23:59:59Z",
        utc = "2028-02-29T00:00:00Z",
        equivalent = "2028-02-28T20:30:00-03:30",
    },
    {
        name = "end of leap day",
        older = "2028-02-29T23:59:59Z",
        utc = "2028-03-01T00:00:00Z",
        equivalent = "2028-03-01T05:30:00+05:30",
    },
}
for _, boundary in ipairs(boundaries) do
    count = n
    n, row = poll(7.2, boundary.utc)
    assert(n == count + 1 and row.w == 7200, boundary.name .. ": newer UTC sample was rejected")
    count = n
    n = poll(0, boundary.older)
    assert(n == count, boundary.name .. ": earlier sample was accepted")
    n = poll(0, boundary.equivalent)
    assert(n == count, boundary.name .. ": conflicting sample at the same instant was accepted")
    n, row = poll(7.2, boundary.equivalent)
    assert(n == count + 1 and row.control_power_confirmed,
        boundary.name .. ": equivalent timestamp did not confirm power")
end
print("Easee observation ordering: passed")
