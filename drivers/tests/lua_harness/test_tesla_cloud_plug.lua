-- tesla_cloud: which car is plugged in. The cable from charge_state, the
-- place from location_data in the same read, never the coordinates, and no
-- cable time: reads minutes apart cannot date a plug-in.
dofile("drivers/tests/lua_harness/host_mock.lua")

local VIN = "5YJ3E1EA1KF000000"
local AUTH = "https://fleet-auth.prd.vn.cloud.tesla.com/oauth2/v3/token"
local STATUS = "https://fleet-api.prd.eu.vn.cloud.tesla.com/api/1/vehicles/" .. VIN
local DATA = STATUS .. "/vehicle_data?endpoints=charge_state"
local WITH_PLACE = DATA .. "%3Blocation_data"

-- Charge-state values as a Model Y on an IEC cable reported them on
-- 15 October 2026 (Tesla Custom Integration attributes of
-- binary_sensor.<car>_charger), and Tesla's documented values with no cable.
local PLUGGED = { conn_charge_cable = "IEC", charge_port_latch = "Engaged", charging_state = "Stopped" }
local UNPLUGGED = { conn_charge_cable = "<invalid>", charge_port_latch = "Disengaged", charging_state = "Disconnected" }
-- A public landmark, not anyone's home: Uppsala Cathedral, a car parked
-- beside it, and one at Stockholm Central.
local SITE = { 59.8580, 17.6336 }
local BESIDE = { 59.8583, 17.6340 }
local STOCKHOLM = { 59.3301, 18.0586 }

local routes, gets = {}, {}
local site = SITE

local function doc(cable, ts, pos)
  local cs = { battery_level = 14, charge_limit_soc = 80, timestamp = ts }
  for k, v in pairs(cable) do cs[k] = v end
  local r = { vin = VIN, state = "online", charge_state = cs }
  if pos then
    r.drive_state = { latitude = pos[1], longitude = pos[2], timestamp = ts }
  end
  return host.json_encode({ response = r })
end

local function boot()
  host.reset()
  routes, gets = {}, {}
  host.http_get = function(url)
    gets[#gets + 1] = url
    local r = routes[url]
    if r == nil then error("http_get: no mock for " .. url) end
    if type(r) == "table" then return nil, r.err end
    return r
  end
  host.http_post = function(url)
    if url == AUTH then
      return host.json_encode({ access_token = "a", refresh_token = "r2", expires_in = 28800 })
    end
    error("http_post: " .. url)
  end
  host.site_location = function()
    if not site then return nil end
    return site[1], site[2]
  end
  routes[STATUS] = host.json_encode({ response = { vin = VIN, state = "online" } })
  dofile("drivers/lua/tesla_cloud.lua")
  driver_init({ client_id = "c", refresh_token = "r", vin = VIN, region = "eu" })
end

local function read(body)
  routes[WITH_PLACE] = body
  host._millis_counter = host._millis_counter + 1300000
  driver_poll()
  local rows = host._emitted.vehicle
  return rows[#rows]
end

-- Plugged in beside the site: the cable, a short distance, no coordinates.
boot()
local r = read(doc(PLUGGED, 1000, BESIDE))
assert(gets[#gets] == WITH_PLACE, "one read asks for location_data, got " .. tostring(gets[#gets]))
assert(r.plugged == true, "conn_charge_cable IEC is a cable")
assert(r.plugged_since_ms == nil, "no cable time")
assert(r.site_distance_m and r.site_distance_m > 20 and r.site_distance_m < 60,
  "beside the site, got " .. tostring(r.site_distance_m))
for k in pairs(r) do
  assert(k ~= "latitude" and k ~= "longitude" and k ~= "drive_state", "coordinates left the driver: " .. k)
end

-- Unplugged, then plugged in again: the cable follows, still with no time.
r = read(doc(UNPLUGGED, 2000, BESIDE))
assert(r.plugged == false and r.plugged_since_ms == nil, "cable out")
host._millis_counter = host._millis_counter + 60000
driver_poll()
r = host._emitted.vehicle[#host._emitted.vehicle]
assert(r.plugged == false and r.soc_fresh == false, "a replay keeps the cable")
r = read(doc(PLUGGED, 3000, BESIDE))
assert(r.plugged == true and r.plugged_since_ms == nil, "cable in")

-- Elsewhere.
r = read(doc(PLUGGED, 5000, STOCKHOLM))
assert(r.site_distance_m > 50000, "Stockholm is far from Uppsala, got " .. tostring(r.site_distance_m))

-- No cable field: the charging state says it.
r = read(doc({ charging_state = "Disconnected" }, 6000, BESIDE))
assert(r.plugged == false, "Disconnected is no cable")

-- No site position: the read asks for charge_state alone and gives no distance.
site = nil
boot()
routes[DATA] = doc(PLUGGED, 1000, nil)
host._millis_counter = host._millis_counter + 1300000
driver_poll()
r = host._emitted.vehicle[#host._emitted.vehicle]
assert(gets[#gets] == DATA, "no site, no location_data")
assert(r.plugged == true and r.site_distance_m == nil, "cable without place")
site = SITE

-- A token without the vehicle_location scope: Tesla refuses location_data,
-- the driver reads charge_state alone and does not ask again.
boot()
routes[WITH_PLACE] = { err = "HTTP 403: missing scopes" }
routes[DATA] = doc(PLUGGED, 1000, nil)
host._millis_counter = host._millis_counter + 1300000
driver_poll()
r = host._emitted.vehicle[#host._emitted.vehicle]
assert(r and r.plugged == true and r.site_distance_m == nil, "the level still arrives without the scope")
local asked = 0
for _, url in ipairs(gets) do if url == WITH_PLACE then asked = asked + 1 end end
host._millis_counter = host._millis_counter + 1300000
driver_poll()
local again = 0
for _, url in ipairs(gets) do if url == WITH_PLACE then again = again + 1 end end
assert(asked == 1 and again == 1, "location_data is not asked again soon after a refusal")
-- A day later the owner may have granted the scope.
routes[WITH_PLACE] = doc(PLUGGED, 9000, BESIDE)
host._millis_counter = host._millis_counter + 86400000
driver_poll()
r = host._emitted.vehicle[#host._emitted.vehicle]
assert(gets[#gets] == WITH_PLACE and r.site_distance_m and r.site_distance_m < 60,
  "location_data asked again after a day")

-- An asleep car is not read for its cable or place either.
boot()
routes[STATUS] = host.json_encode({ response = { vin = VIN, state = "asleep" } })
host._millis_counter = host._millis_counter + 1300000
driver_poll()
for _, url in ipairs(gets) do
  assert(not url:find("vehicle_data", 1, true), "an asleep car was read")
end

-- A level of 1 % goes as 0.01: FTW reads a plain 1 as 100 %.
boot()
routes[WITH_PLACE] = host.json_encode({ response = { vin = VIN, state = "online",
  charge_state = { battery_level = 1, charge_limit_soc = 80, conn_charge_cable = "IEC", timestamp = 1000 } } })
host._millis_counter = host._millis_counter + 1300000
driver_poll()
r = host._emitted.vehicle[#host._emitted.vehicle]
assert(r.soc == 0.01, "1 % as 0.01, got " .. tostring(r.soc))

print("OK tesla_cloud plug")
