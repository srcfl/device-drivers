-- teslamate_vehicle: which car is plugged in. plugged_in gives the cable,
-- a change the driver sees arrive gives plugged_since_ms, latitude and
-- longitude give the distance from the site, never the coordinates.
dofile("drivers/tests/lua_harness/host_mock.lua")

local VIN = "5YJ3E1EA1KF000000"
-- A public landmark, not anyone's home: Uppsala Cathedral, a car beside
-- it, and Stockholm Central. TeslaMate publishes each value as a string.
local SITE = { 59.8580, 17.6336 }
local clock = 5000

local function boot(site)
  host.reset()
  host.unix_ms = function() return clock end
  host.site_location = function()
    if not site then return nil end
    return site[1], site[2]
  end
  dofile("drivers/lua/teslamate_vehicle.lua")
  driver_init({ vin = VIN, car_id = 1 })
end

local function send(pairs_)
  local msgs = {}
  for i = 1, #pairs_, 2 do
    msgs[#msgs + 1] = { topic = "teslamate/cars/1/" .. pairs_[i], payload = pairs_[i + 1] }
  end
  host._mqtt_buffer = msgs
  driver_poll()
  local rows = host._emitted.vehicle
  return rows and rows[#rows]
end

-- The retained values at subscribe: plugged in beside the site.
boot(SITE)
local r = send({ "state", "online", "healthy", "true", "battery_level", "14",
                 "plugged_in", "true", "latitude", "59.8583", "longitude", "17.6340" })
assert(r.plugged == true, "plugged_in true")
assert(r.plugged_since_ms == nil, "a retained value at subscribe is no change")
assert(r.site_distance_m and r.site_distance_m > 20 and r.site_distance_m < 60,
  "beside the site, got " .. tostring(r.site_distance_m))
for k in pairs(r) do
  assert(k ~= "latitude" and k ~= "longitude", "coordinates left the driver: " .. k)
end

-- Unplugged and plugged in again while the driver listens: it dates each.
clock = 7000
r = send({ "plugged_in", "false" })
assert(r.plugged == false and r.plugged_since_ms == 7000, "cable out when the change arrived")
clock = 9000
r = send({ "healthy", "true", "plugged_in", "true" })
assert(r.plugged == true and r.plugged_since_ms == 9000, "cable in when the change arrived")
clock = 11000
r = send({ "plugged_in", "true" })
assert(r.plugged_since_ms == 9000, "a repeat is no change")

-- The car drives to Stockholm.
r = send({ "latitude", "59.3301", "longitude", "18.0586" })
assert(r.site_distance_m > 50000, "far away, got " .. tostring(r.site_distance_m))

-- Junk is ignored.
r = send({ "plugged_in", "maybe", "latitude", "123" })
assert(r.plugged == true and r.site_distance_m > 50000, "junk does not change the cable or place")

-- No site position: the cable, no distance.
boot(nil)
r = send({ "state", "online", "healthy", "true", "battery_level", "14",
           "plugged_in", "false", "latitude", "59.8583", "longitude", "17.6340" })
assert(r.plugged == false and r.site_distance_m == nil, "no site, no distance")

print("OK teslamate_vehicle plug")
