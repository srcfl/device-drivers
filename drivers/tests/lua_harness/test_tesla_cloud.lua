dofile("drivers/tests/lua_harness/host_mock.lua")

local VIN = "5YJ3E1EA1KF000000"
local AUTH = "https://fleet-auth.prd.vn.cloud.tesla.com/oauth2/v3/token"
local EU = "https://fleet-api.prd.eu.vn.cloud.tesla.com"
local STATUS = EU .. "/api/1/vehicles/" .. VIN
local DATA = STATUS .. "/vehicle_data?endpoints=charge_state"

-- Mirrors the driver's pacing constants.
local POLL_MS           = 60000
local CHARGING_EVERY_MS = 240000
local IDLE_EVERY_MS     = 1200000
local ASLEEP_EVERY_MS   = 300000
local STALE_AFTER_MS    = 1500000
local ERROR_RETRY_MS    = 300000
local BACKOFF_MS        = 900000

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
  error("http_post: no mock for " .. tostring(url))
end

local function vehicle_doc(state)
  return json({
    response = {
      vin = VIN,
      state = state,
      -- The owner's name for the car. It must never become the model.
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
  routes[STATUS] = vehicle_doc("online")
  routes[DATA] = charge_doc()
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

local function emitted()
  local rows = host._emitted.vehicle
  return rows and #rows or 0
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

-- The host keeps the interval last set with host.set_poll_interval.
local function last_poll_interval()
  local ms = nil
  for _, call in ipairs(host._calls) do
    if call.func == "set_poll_interval" then ms = call.args[1] end
  end
  return ms
end

local function advance(ms)
  host._millis_counter = host._millis_counter + ms
end

-- Online and charging: one read, a fresh DerVehicle, the model from the VIN.
boot()
assert(host._make == "Tesla", "set_make Tesla")
assert(host._sn == VIN, "set_sn from config VIN")
assert(host._model == "Model 3", "model from the VIN, got " .. tostring(host._model))
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
assert(host._model == "Model 3", "display_name must not become the model")
assert(count_posts("/oauth2/v3/token") == 1, "one token refresh")
assert(count_posts("/wake_up") == 0, "must not wake")
assert(count_posts("/command/") == 0, "must not command the car")
assert(count_gets("/vehicle_data") == 1, "vehicle_data once while online")
assert(last_poll_interval() == POLL_MS, "poll interval after a read")

-- Rotated refresh_token is persisted.
local persisted = false
for _, call in ipairs(host._calls) do
  if call.func == "persist_secret" and call.args[1] == "refresh_token" and call.args[2] == "refresh-2" then
    persisted = true
  end
end
assert(persisted, "rotated refresh_token not persisted")

-- Between reads a poll calls nothing and replays. The replay is not stale:
-- a stale flag would drop the car from Core until the next read.
local gets_before = #gets
driver_poll()
assert(#gets == gets_before, "a poll before the next read is due must not call Tesla")
local replay = last_vehicle()
assert(replay.soc == 67, "replay keeps SoC")
assert(replay.soc_fresh == false, "replay is not a new observation")
assert(replay.stale == false, "replay inside the window must not be stale")

-- Charging: the next read comes after CHARGING_EVERY_MS, not before.
advance(CHARGING_EVERY_MS - 10000)
driver_poll()
assert(count_gets("/vehicle_data") == 1, "no read before the charging interval")
advance(20000)
driver_poll()
assert(count_gets("/vehicle_data") == 2, "read again once the charging interval has passed")
assert(last_vehicle().soc_fresh == true, "a new read is fresh")

-- Awake but not charging: leave the car IDLE_EVERY_MS to fall asleep.
boot()
routes[DATA] = charge_doc({ state = "Stopped" })
driver_poll()
assert(count_gets("/vehicle_data") == 1, "idle: first read")
advance(CHARGING_EVERY_MS + 1000)
driver_poll()
assert(count_gets("/vehicle_data") == 1, "an idle car is not read every few minutes")
advance(IDLE_EVERY_MS)
driver_poll()
assert(count_gets("/vehicle_data") == 2, "idle car read again after IDLE_EVERY_MS")

-- Asleep: a state check only, no vehicle_data; replay while young, then stop.
boot()
driver_poll()
assert(last_vehicle() and last_vehicle().soc_fresh == true, "prime cache")
routes[STATUS] = vehicle_doc("asleep")
routes[DATA] = { err = "should not fetch" }
gets = {}
advance(CHARGING_EVERY_MS + 1000)
local before = emitted()
driver_poll()
assert(count_gets("/api/1/vehicles/" .. VIN) == 1, "asleep: one state check")
assert(count_gets("/vehicle_data") == 0, "asleep car must not call vehicle_data")
assert(emitted() == before + 1, "replay cache while young")
assert(last_vehicle().soc_fresh == false, "replay is not fresh")
assert(last_vehicle().stale == false, "young replay is not stale")
assert(last_vehicle().soc == 67, "replay keeps SoC")
gets = {}
advance(ASLEEP_EVERY_MS - 10000)
driver_poll()
assert(#gets == 0, "asleep: no request before the next state check")
advance(20000)
before = emitted()
driver_poll()
assert(count_gets("/api/1/vehicles/" .. VIN) == 1, "asleep: state checked again")
assert(emitted() == before + 1, "still young: replay")
advance(STALE_AFTER_MS)
before = emitted()
driver_poll()
assert(emitted() == before, "stop emitting when stale")
assert(count_gets("/vehicle_data") == 0, "an asleep car is never read")
assert(count_posts("/wake_up") == 0, "asleep poll must not wake")

-- A car that just woke is not read on that check: its own short wakes end
-- by themselves, and a live call would stretch them.
boot()
routes[STATUS] = vehicle_doc("asleep")
driver_poll()
assert(count_gets("/vehicle_data") == 0, "asleep at start")
routes[STATUS] = vehicle_doc("online")
advance(ASLEEP_EVERY_MS + 1000)
driver_poll()
assert(count_gets("/vehicle_data") == 0, "first check after waking does not read")
advance(ASLEEP_EVERY_MS + 1000)
driver_poll()
assert(count_gets("/vehicle_data") == 1, "still awake at the next check: read")
assert(last_vehicle() and last_vehicle().soc_fresh == true, "read after waking is fresh")

-- 408 on vehicle_data does not invent a SoC.
boot()
routes[DATA] = { err = "HTTP 408 vehicle unavailable" }
driver_poll()
assert(emitted() == 0, "408 invented telemetry")

-- 429 backs off longer than a plain error.
boot()
routes[DATA] = { err = "HTTP 429 too many requests" }
driver_poll()
assert(count_gets("/vehicle_data") == 1, "429: first read")
advance(ERROR_RETRY_MS + 1000)
driver_poll()
assert(count_gets("/vehicle_data") == 1, "429: no read inside the back-off")
advance(BACKOFF_MS)
driver_poll()
assert(count_gets("/vehicle_data") == 2, "429: read after the back-off")

-- Missing battery_level is not a zero SoC.
boot()
routes[DATA] = json({
  response = { vin = VIN, charge_state = { charging_state = "Stopped" } }
})
driver_poll()
assert(emitted() == 0, "empty charge_state invented SoC")

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
driver_poll()
assert(host._sn == VIN, "discovered VIN")
assert(host._model == "Model 3", "model from the discovered VIN")
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
routes[DATA] = json({
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

-- Config cannot send the secrets or requests to another host.
boot({
  client_id = "app-1",
  client_secret = "secret-1",
  refresh_token = "refresh-1",
  vin = VIN,
  region = "eu",
  base_url = "https://attacker.example",
  auth_url = "https://attacker.example/oauth2/v3/token",
  access_token = "planted",
})
driver_poll()
assert(#posted == 1 and posted[1].url == AUTH, "token POST must go to Tesla's auth host")
for i = 1, #gets do
  assert(gets[i]:find(EU, 1, true) == 1, "GET went to " .. gets[i])
end
assert(last_vehicle() and last_vehicle().soc_fresh == true, "reads through Tesla's hosts")

-- A refresh token Tesla rejects: one POST, then back off. The poll interval
-- must not stay at the 500 ms startup value, or the driver would post to
-- Tesla's auth host twice a second.
boot()
routes[AUTH] = { err = "HTTP 400: invalid_grant" }
driver_poll()
assert(count_posts("/oauth2/v3/token") == 1, "one refresh attempt")
assert(last_poll_interval() == POLL_MS, "failed refresh left the startup poll interval")
for _ = 1, 5 do
  advance(POLL_MS)
  driver_poll()
end
assert(count_posts("/oauth2/v3/token") == 1, "no second refresh inside the back-off")
advance(BACKOFF_MS)
driver_poll()
assert(count_posts("/oauth2/v3/token") == 2, "retry after the back-off")
assert(emitted() == 0, "failed auth invented telemetry")
assert(count_posts("/wake_up") == 0)
assert(count_posts("/charge_start") == 0)

-- No refresh token: no POST, no emit, and the poll interval is still set.
boot({ client_id = "app-1", vin = VIN, region = "eu" })
driver_poll()
assert(count_posts("/oauth2/v3/token") == 0, "no refresh without a token")
assert(last_poll_interval() == POLL_MS, "missing token left the startup poll interval")
assert(emitted() == 0)

print("OK tesla_cloud")
