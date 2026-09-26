dofile("drivers/tests/lua_harness/host_mock.lua")

local VIN = "5YJ3E1EA1KF000000"
local AUTH = "https://fleet-auth.prd.vn.cloud.tesla.com/oauth2/v3/token"
local EU = "https://fleet-api.prd.eu.vn.cloud.tesla.com"

local routes = {}
local posted = {}
local gets = {}

local function json(tbl)
  return host.json_encode(tbl)
end

local function route_get(url)
  table.insert(gets, url)
  if routes[url] ~= nil then
    local r = routes[url]
    if type(r) == "table" and r.err then
      error(r.err)
    end
    return r
  end
  for pattern, body in pairs(routes) do
    if type(pattern) == "string" and url:find(pattern, 1, true) then
      if type(body) == "table" and body.err then
        error(body.err)
      end
      return body
    end
  end
  error("http_get: no mock for " .. tostring(url))
end

local function route_post(url, body, headers)
  table.insert(posted, {url = url, body = body, headers = headers})
  if routes[url] ~= nil then
    local r = routes[url]
    if type(r) == "table" and r.err then
      return nil, r.err
    end
    return r
  end
  for pattern, resp in pairs(routes) do
    if type(pattern) == "string" and url:find(pattern, 1, true) then
      if type(resp) == "table" and resp.err then
        return nil, resp.err
      end
      return resp
    end
  end
  error("http_post: no mock for " .. tostring(url))
end

host.http_get = function(url)
  return route_get(url)
end
host.http_post = function(url, body, headers)
  return route_post(url, body, headers)
end

local function vehicle_doc(state)
  return json({
    response = {
      vin = VIN,
      state = state,
      display_name = "Home",
    }
  })
end

local function charge_doc(fields)
  fields = fields or {}
  local cs = {
    battery_level = fields.soc or 67,
    charge_limit_soc = fields.limit or 80,
    charging_state = fields.state or "Charging",
    minutes_to_full_charge = fields.ttf or 42,
    charge_amps = fields.amps or 16,
    charger_actual_current = fields.actual or 15,
    timestamp = fields.ts or 1710000000000,
  }
  return json({
    response = {
      vin = VIN,
      state = "online",
      charge_state = cs,
      vehicle_config = { car_type = "modely" },
    }
  })
end

local function token_doc(refresh)
  return json({
    access_token = "access-1",
    refresh_token = refresh or "refresh-2",
    expires_in = 28800,
    token_type = "Bearer",
  })
end

local function boot(cfg)
  host.reset()
  routes = {}
  posted = {}
  gets = {}
  host.http_get = function(url) return route_get(url) end
  host.http_post = function(url, body, headers) return route_post(url, body, headers) end
  routes[AUTH] = token_doc()
  routes[EU .. "/api/1/vehicles/" .. VIN] = vehicle_doc("online")
  routes[EU .. "/api/1/vehicles/" .. VIN .. "/vehicle_data?endpoints=charge_state"] = charge_doc()
  dofile("drivers/lua/tesla_cloud.lua")
  driver_init(cfg or {
    client_id = "app-1",
    client_secret = "secret-1",
    refresh_token = "refresh-1",
    vin = VIN,
    region = "eu",
  })
end

local function last_vehicle()
  local rows = host._emitted.vehicle
  if not rows or #rows == 0 then return nil end
  return rows[#rows]
end

local function count_gets(needle)
  local n = 0
  for i = 1, #gets do
    if gets[i]:find(needle, 1, true) then n = n + 1 end
  end
  return n
end

local function count_posts(needle)
  local n = 0
  for i = 1, #posted do
    if posted[i].url:find(needle, 1, true) then n = n + 1 end
  end
  return n
end

boot()
assert(host._make == "Tesla", "set_make Tesla")
assert(host._sn == VIN, "set_sn from config VIN")
driver_poll()
local sample = last_vehicle()
assert(sample, "online car must emit DerVehicle")
assert(sample.soc == 67, "soc")
assert(sample.charge_limit_pct == 80, "charge_limit_pct")
assert(sample.charging_state == "Charging", "charging_state")
assert(sample.time_to_full_min == 42, "time_to_full_min")
assert(sample.charge_amps == 16, "charge_amps")
assert(sample.charger_actual_current == 15, "charger_actual_current")
assert(sample.stale == false, "fresh emit is not stale")
assert(sample.soc_fresh == true, "soc_fresh")
assert(host._model == "Home" or host._model == "modely", "model from vehicle")
assert(count_posts("/oauth2/v3/token") == 1, "one token refresh")
assert(count_posts("/wake_up") == 0, "must not wake")
assert(count_posts("/command/") == 0, "must not command the car")
assert(count_gets("/vehicle_data") == 1, "vehicle_data once while online")

-- Rotated refresh_token is persisted.
local persisted = false
for _, call in ipairs(host._calls) do
  if call.func == "persist_secret" and call.args[1] == "refresh_token" and call.args[2] == "refresh-2" then
    persisted = true
  end
end
assert(persisted, "rotated refresh_token not persisted")

-- Asleep: status only, no vehicle_data, cache marked stale then dropped.
boot()
driver_poll()
assert(last_vehicle() and last_vehicle().soc_fresh == true, "prime cache")
local after_fresh = #(host._emitted.vehicle)
gets = {}
routes[EU .. "/api/1/vehicles/" .. VIN] = vehicle_doc("asleep")
routes[EU .. "/api/1/vehicles/" .. VIN .. "/vehicle_data?endpoints=charge_state"] = { err = "should not fetch" }
driver_poll()
assert(count_gets("/vehicle_data") == 0, "asleep car must not call vehicle_data")
assert(#(host._emitted.vehicle) == after_fresh + 1, "replay cache while young")
assert(last_vehicle().stale == true, "replay is stale")
assert(last_vehicle().soc_fresh == false, "replay is not fresh")
assert(last_vehicle().soc == 67, "replay keeps SoC")

host._millis_counter = host._millis_counter + 900001
local before_stale = #(host._emitted.vehicle)
driver_poll()
assert(#(host._emitted.vehicle) == before_stale, "stop emitting when stale")
assert(count_posts("/wake_up") == 0, "asleep poll must not wake")

-- 408 on vehicle_data does not invent a SoC.
boot()
routes[EU .. "/api/1/vehicles/" .. VIN .. "/vehicle_data?endpoints=charge_state"] = { err = "HTTP 408 vehicle unavailable" }
driver_poll()
assert(host._emitted.vehicle == nil or #(host._emitted.vehicle) == 0, "408 invented telemetry")

-- Missing battery_level is not a zero SoC.
boot()
routes[EU .. "/api/1/vehicles/" .. VIN .. "/vehicle_data?endpoints=charge_state"] = json({
  response = { vin = VIN, charge_state = { charging_state = "Stopped" } }
})
driver_poll()
assert(host._emitted.vehicle == nil or #(host._emitted.vehicle) == 0, "empty charge_state invented SoC")

-- Discover VIN from the account list.
boot({
  client_id = "app-1",
  refresh_token = "refresh-1",
  region = "eu",
})
assert(host._sn == nil, "no VIN at init")
routes[EU .. "/api/1/vehicles"] = json({
  response = {
    { vin = VIN, state = "online", display_name = "Home" },
  }
})
-- Status by VIN is unknown until discovered; list is the first lookup.
routes[EU .. "/api/1/vehicles/"] = nil
driver_poll()
assert(host._sn == VIN, "discovered VIN")
assert(last_vehicle() and last_vehicle().soc == 67, "emit after discover")

-- Region NA builds the North America Fleet URL.
boot({
  client_id = "app-1",
  refresh_token = "refresh-1",
  vin = VIN,
  region = "na",
})
local NA = "https://fleet-api.prd.na.vn.cloud.tesla.com"
routes[NA .. "/api/1/vehicles/" .. VIN] = vehicle_doc("online")
routes[NA .. "/api/1/vehicles/" .. VIN .. "/vehicle_data?endpoints=charge_state"] = charge_doc({ soc = 41 })
driver_poll()
assert(last_vehicle() and last_vehicle().soc == 41, "NA region")
for i = 1, #gets do
  assert(not gets[i]:find("fleet-api.prd.eu", 1, true), "NA poll hit EU: " .. gets[i])
end

-- time_to_full_charge hours → minutes.
boot()
routes[EU .. "/api/1/vehicles/" .. VIN .. "/vehicle_data?endpoints=charge_state"] = json({
  response = {
    vin = VIN,
    charge_state = {
      battery_level = 50,
      charge_limit_soc = 80,
      charging_state = "Charging",
      time_to_full_charge = 1.5,
    }
  }
})
driver_poll()
assert(last_vehicle().time_to_full_min == 90, "hours converted to minutes")

-- Failed auth does not POST wake or charge_start.
boot({ client_id = "app-1", vin = VIN, region = "eu" })
driver_poll()
assert(count_posts("/wake_up") == 0)
assert(count_posts("/charge_start") == 0)
assert(host._emitted.vehicle == nil or #(host._emitted.vehicle) == 0)

print("OK tesla_cloud")
