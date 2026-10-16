-- VAG plug state: plugged, with no cable time (the portal writes every 15
-- minutes), and a level of 1 % as 0.01.
-- Args: connected.zip unplugged.zip again.zip unknown.zip

dofile("drivers/tests/lua_harness/host_mock.lua")

local paths = { arg[1], arg[2], arg[3], arg[4] }
for i = 1, 4 do
    assert(paths[i], "usage: test_vag_vehicle_plug.lua connected.zip unplugged.zip again.zip unknown.zip")
end
local function read_bin(path)
    local f = assert(io.open(path, "rb"))
    local data = f:read("*a")
    f:close()
    return data
end

local VIN = "WVWZZZTESTVIN0001"
local REQ = "req-continuous-1"
local META = "/datarequest/vehicles/" .. VIN .. "/metadata/partial"
local LIST = "/datadelivery/vehicles/" .. VIN .. "/" .. REQ .. "/list"
local DL = "/datadelivery/vehicles/" .. VIN .. "/" .. REQ .. "/download"
local FILES = {
    { name = "2026-09-26T07-00-00_partial.zip", createdOn = "2026-09-26T07:00:00Z" },
    { name = "2026-09-26T07-15-00_partial.zip", createdOn = "2026-09-26T07:15:00Z" },
    { name = "2026-09-26T07-30-00_partial.zip", createdOn = "2026-09-26T07:30:00Z" },
    { name = "2026-09-26T07-45-00_partial.zip", createdOn = "2026-09-26T07:45:00Z" },
}

local downloads = {}
local orig_http_get = host.http_get
function host.http_get(url, headers)
    if string.find(url, DL, 1, true) then
        local body = downloads[headers and headers.filename]
        if body == nil then return nil, "HTTP 404" end
        return body
    end
    return orig_http_get(url, headers)
end

host.reset()
dofile("drivers/lua/vag_vehicle.lua")
driver_init({ vin = VIN, brand = "volkswagen", cookie = "SESSION=test; Path=/" })
host._http_responses[META] = host.json_encode({ Identifier = REQ })

local listed = {}
local function next_file(i)
    downloads[FILES[i].name] = read_bin(paths[i])
    listed[#listed + 1] = FILES[i]
    host._http_responses[LIST] = host.json_encode(listed)
    driver_poll()
    local rows = host._emitted.vehicle
    return rows[#rows]
end

local r = next_file(1)
assert(r.plugged == true and r.plugged_since_ms == nil, "connected, no time")

r = next_file(2)
assert(r.plugged == false and r.plugged_since_ms == nil, "disconnected, no time")

driver_poll()
r = host._emitted.vehicle[#host._emitted.vehicle]
assert(r.plugged == false, "a replay keeps the plug state")

r = next_file(3)
assert(r.plugged == true, "plugged in again")

r = next_file(4)
assert(r.plugged == nil, "an unknown plug state is not unplugged")
assert(r.soc == 0.01, "1 % as 0.01, got " .. tostring(r.soc))

print("vag_vehicle plug: ok")
