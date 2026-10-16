-- teslamate_vehicle: which car is plugged in. plugged_in gives the cable;
-- a change is dated only when a live update (a healthy message within 10 s)
-- carries it. The geofence, or else the distance from latitude and
-- longitude, gives the place; the coordinates never leave the driver.
dofile("drivers/tests/lua_harness/host_mock.lua")

local VIN = "5YJ3E1EA1KF000000"
-- A public landmark, not anyone's home: Uppsala Cathedral, a car beside
-- it, and Stockholm Central. TeslaMate publishes each value as a string.
local SITE = { 59.8580, 17.6336 }
local clock = 5000

local function boot(site, cfg)
  host.reset()
  host.unix_ms = function() return clock end
  host.site_location = function()
    if not site then return nil end
    return site[1], site[2]
  end
  dofile("drivers/lua/teslamate_vehicle.lua")
  driver_init(cfg or { vin = VIN, car_id = 1 })
end

-- One poll's worth of messages, after `wait_ms` on both clocks.
local function send(pairs_, wait_ms)
  wait_ms = wait_ms or 0
  clock = clock + wait_ms
  host._millis_counter = host._millis_counter + wait_ms
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
assert(r.at_site == nil, "no geofence configured, no at_site")
assert(r.site_distance_m and r.site_distance_m > 20 and r.site_distance_m < 60,
  "beside the site, got " .. tostring(r.site_distance_m))
for k in pairs(r) do
  assert(k ~= "latitude" and k ~= "longitude", "coordinates left the driver: " .. k)
end

-- The broker reconnects and redelivers a retained plugged_in that changed
-- meanwhile. No healthy message comes with it: its time is unknown.
r = send({ "plugged_in", "false" }, 60000)
assert(r.plugged == false and r.plugged_since_ms == nil, "a redelivered retained value is not dated")
r = send({}, 5000)
r = send({}, 6000)
assert(r.plugged_since_ms == nil, "still undated once a healthy message can no longer come")

-- A live update: plugged_in with its healthy message.
local live = clock + 60000
r = send({ "healthy", "true", "plugged_in", "true" }, 60000)
assert(r.plugged == true and r.plugged_since_ms == live, "a live change is dated when it arrived")
r = send({ "plugged_in", "true" }, 30000)
assert(r.plugged_since_ms == live, "a repeat is no change")

-- The healthy message lands in the next poll, 5 s later.
local out = clock + 60000
r = send({ "plugged_in", "false" }, 60000)
assert(r.plugged_since_ms == nil, "waiting for a healthy message")
r = send({ "healthy", "true" }, 5000)
assert(r.plugged == false and r.plugged_since_ms == out, "dated once its healthy message came")

-- The car drives to Stockholm.
r = send({ "latitude", "59.3301", "longitude", "18.0586" })
assert(r.site_distance_m > 50000, "far away, got " .. tostring(r.site_distance_m))

-- Junk is ignored.
r = send({ "plugged_in", "maybe", "latitude", "123" })
assert(r.plugged == false and r.site_distance_m > 50000, "junk does not change the cable or place")

-- No site position: the cable, no distance.
boot(nil)
r = send({ "state", "online", "healthy", "true", "battery_level", "14",
           "plugged_in", "false", "latitude", "59.8583", "longitude", "17.6340" })
assert(r.plugged == false and r.site_distance_m == nil, "no site, no distance")

-- With this site's geofence named, the geofence topic says where the car is,
-- and the weather pin is not used.
boot(SITE, { vin = VIN, car_id = 1, geofence = "Home" })
r = send({ "state", "online", "healthy", "true", "battery_level", "14", "geofence", "Home",
           "latitude", "59.3301", "longitude", "18.0586" })
assert(r.at_site == true and r.site_distance_m == nil, "in the Home geofence")
r = send({ "geofence", "Work" }, 60000)
assert(r.at_site == false, "in another geofence")
r = send({ "geofence", "" }, 60000)
assert(r.at_site == false, "in no geofence")

-- A level of 1 % goes as 0.01: FTW reads a plain 1 as 100 %.
boot(SITE)
r = send({ "state", "online", "healthy", "true", "battery_level", "1" })
assert(r.soc == 0.01, "1 % as 0.01, got " .. tostring(r.soc))

print("OK teslamate_vehicle plug")
