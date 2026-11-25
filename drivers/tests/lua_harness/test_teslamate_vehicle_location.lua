-- teslamate_vehicle: the car's position from TeslaMate's `location` topic.
-- TeslaMate now marks latitude and longitude as deprecated and publishes
-- location as JSON {"latitude": <float>, "longitude": <float>}. The driver
-- reads both. The newest message sets the position. A location the driver
-- cannot read leaves the last position as it was.
dofile("drivers/tests/lua_harness/host_mock.lua")

local VIN = "5YJ3E1EA1KF000000"
-- Public landmarks, not anyone's home: Uppsala Cathedral as the site, a
-- spot beside it, and Stockholm Central.
local SITE = { 59.8580, 17.6336 }
local BESIDE = '{"latitude":59.8583,"longitude":17.6340}'
local STOCKHOLM = '{"latitude":59.3301,"longitude":18.0586}'

local function boot(site, cfg)
  host.reset()
  host.site_location = function()
    if not site then return nil end
    return site[1], site[2]
  end
  dofile("drivers/lua/teslamate_vehicle.lua")
  driver_init(cfg or { vin = VIN, car_id = 1 })
end

-- One poll's worth of messages, in arrival order, after `wait_ms`.
local function send(pairs_, wait_ms)
  host._millis_counter = host._millis_counter + (wait_ms or 0)
  local msgs = {}
  for i = 1, #pairs_, 2 do
    msgs[#msgs + 1] = { topic = "teslamate/cars/1/" .. pairs_[i], payload = pairs_[i + 1] }
  end
  host._mqtt_buffer = msgs
  driver_poll()
  local rows = host._emitted.vehicle
  return rows and rows[#rows]
end

local function near(r, label)
  assert(r.site_distance_m and r.site_distance_m > 20 and r.site_distance_m < 60,
    label .. ": beside the site, got " .. tostring(r.site_distance_m))
end

local function far(r, label)
  assert(r.site_distance_m and r.site_distance_m > 50000,
    label .. ": in Stockholm, got " .. tostring(r.site_distance_m))
end

local function awake(extra)
  local msgs = { "state", "online", "healthy", "true", "battery_level", "40" }
  for _, v in ipairs(extra or {}) do msgs[#msgs + 1] = v end
  return msgs
end

-- location alone gives the distance, and the coordinates stay in the driver.
boot(SITE)
local r = send(awake({ "location", BESIDE }))
near(r, "location alone")
assert(r.at_site == nil, "no geofence configured, no at_site")
for k in pairs(r) do
  assert(k ~= "latitude" and k ~= "longitude" and k ~= "location",
    "coordinates left the driver: " .. k)
end
r = send({ "location", STOCKHOLM }, 60000)
far(r, "location moves the car")

-- A location is a place, not a reading of the car: it does not refresh the
-- level, the same as latitude and longitude.
local emitted = #host._emitted.vehicle
r = send({ "location", BESIDE }, 60000)
assert(#host._emitted.vehicle == emitted + 1, "one row per poll")
assert(r.soc_fresh == false, "a location alone is not a fresh reading")
near(r, "location replayed with the old level")

-- Spaces and key order do not matter, and extra keys are ignored.
r = send({ "location", '{ "longitude" : 18.0586 , "heading": 90, "latitude" : 59.3301 }' })
far(r, "keys in any order")

-- The old topics still work, for TeslaMate versions without location.
boot(SITE)
r = send(awake({ "latitude", "59.8583", "longitude", "17.6340" }))
near(r, "old topics")

-- When both arrive, the newest message wins, in either order.
boot(SITE)
r = send(awake({ "latitude", "59.8583", "longitude", "17.6340", "location", STOCKHOLM }))
far(r, "location after the old topics")
r = send({ "location", STOCKHOLM, "latitude", "59.8583", "longitude", "17.6340" }, 60000)
near(r, "old topics after location")
r = send({ "location", STOCKHOLM }, 60000)
far(r, "a later location")
r = send({ "latitude", "59.8583", "longitude", "17.6340" }, 60000)
near(r, "later old topics")

-- A location the driver cannot read leaves the last position untouched.
-- Each case starts in Stockholm; none may move the car or invent 0,0.
local bad = {
  { "not JSON", "59.8583,17.6340" },
  { "cut short", '{"latitude":59.8583,"longitude":' },
  { "empty", "" },
  { "nil text", "nil" },
  { "JSON null", "null" },
  { "a bare number", "59.8583" },
  { "a list", "[59.8583,17.6340]" },
  { "empty object", "{}" },
  { "no longitude", '{"latitude":59.8583}' },
  { "no latitude", '{"longitude":17.6340}' },
  { "null latitude", '{"latitude":null,"longitude":17.6340}' },
  { "text, not numbers", '{"latitude":"59.8583","longitude":"17.6340"}' },
  { "booleans", '{"latitude":true,"longitude":false}' },
  { "NaN", '{"latitude":NaN,"longitude":17.6340}' },
  { "infinite", '{"latitude":59.8583,"longitude":1e999}' },
  { "latitude past the pole", '{"latitude":91,"longitude":17.6340}' },
  { "longitude past 180", '{"latitude":59.8583,"longitude":181}' },
}
local function unmoved(payload, label)
  boot(SITE)
  local before = send(awake({ "location", STOCKHOLM }))
  far(before, label .. " (before)")
  r = send({ "location", payload }, 60000)
  assert(r.site_distance_m == before.site_distance_m,
    label .. ": moved the car from " .. tostring(before.site_distance_m) ..
    " to " .. tostring(r.site_distance_m))
end
for _, case in ipairs(bad) do unmoved(case[2], case[1]) end

-- A payload the host cannot even treat as text is ignored too.
unmoved({ latitude = 59.8583, longitude = 17.6340 }, "a table payload")

-- A bad location before any position gives no distance at all, not 0,0.
boot(SITE)
r = send(awake({ "location", '{"latitude":59.8583}' }))
assert(r.site_distance_m == nil, "no position yet, no distance, got " .. tostring(r.site_distance_m))
r = send({ "location", "garbage" }, 60000)
assert(r.site_distance_m == nil, "still no position")

-- 0 is a real coordinate, read the same way as on the old topics.
-- (0, 0) lies in the Gulf of Guinea, so the car is far from Uppsala.
boot(SITE)
r = send(awake({ "location", '{"latitude":0,"longitude":0}' }))
assert(r.site_distance_m and r.site_distance_m > 6000000,
  "location 0,0 is read as a position, got " .. tostring(r.site_distance_m))
boot(SITE)
r = send(awake({ "latitude", "0", "longitude", "0" }))
assert(r.site_distance_m and r.site_distance_m > 6000000,
  "old topics 0,0 read as a position, got " .. tostring(r.site_distance_m))

-- NaN on the old topics is ignored as before.
boot(SITE)
local before = send(awake({ "location", STOCKHOLM }))
r = send({ "latitude", "nan", "longitude", "NaN" }, 60000)
assert(r.site_distance_m == before.site_distance_m, "NaN on the old topics moved the car")

-- With this site's geofence named, the geofence decides and the position
-- is not used, whichever topic carried it.
boot(SITE, { vin = VIN, car_id = 1, geofence = "Home" })
r = send(awake({ "geofence", "Home", "location", STOCKHOLM }))
assert(r.at_site == true and r.site_distance_m == nil, "the geofence decides")

-- Cleanup forgets the position.
boot(SITE)
send(awake({ "location", STOCKHOLM }))
driver_cleanup()
host._emitted.vehicle = nil
driver_init({ vin = VIN, car_id = 1 })
r = send(awake())
assert(r.site_distance_m == nil, "no position after cleanup")

print("OK teslamate_vehicle location")
