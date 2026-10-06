dofile("drivers/tests/lua_harness/host_mock.lua")
local VIN = "5YJ3E1EA1KF000000"
local now, epoch = 1000, 1760000000000
local body, request_err, wake_err
local gets, posts, saved = {}, {}, {}
local mock_log = host.log
function host.log(level, message)
  assert(not tostring(message):find(VIN, 1, true), "full VIN in log")
  return mock_log(level, message)
end
function host.set_poll_interval(ms) host._poll_interval_ms = ms end
function host.millis() return now end
function host.unix_ms() return epoch + now end
function host.http_get(url)
  assert(not url:find("wakeup=true", 1, true), "wake must bypass the data cache")
  gets[#gets+1] = url
  return body, request_err
end
function host.http_post(url)
  posts[#posts+1] = url
  assert(not url:find("charge_start", 1, true), "telemetry recovery started charging")
  return host.json_encode({response = {result = true}}), wake_err
end
function host.reserve_vehicle_wake()
  local key = host._sn
  local c = saved[key]
  if not c or now - c.start >= 1800000 then c = { start = now, last = 0, count = 0 }; saved[key] = c end
  if c.count >= 3 then return false, 1800000 - (now - c.start) end
  if c.count > 0 and now - c.last < 90000 then return false, 90000 - (now - c.last) end
  c.count, c.last = c.count + 1, now
  return true, 90000
end
local function load(reset_budget)
  if reset_budget then saved = {}; now = 1000 end
  dofile("drivers/lua/tesla_vehicle.lua")
  driver_init({ip="192.0.2.1", vin=VIN})
  gets, posts = {}, {}
  body, request_err, wake_err = nil, nil, nil
  host._emitted = {}
end
local function data(soc, timestamp)
  return host.json_encode({response={charge_state={battery_level=soc, timestamp=timestamp,
    charge_limit_soc=80, charging_state="Complete"}}})
end
local function latest()
  local readings = host._emitted.vehicle
  return readings and readings[#readings]
end

-- Cold boot, HTTP 200 without battery_level: immediate bounded wake, then read.
load(true)
body = data(nil, math.floor(host.unix_ms()/1000))
assert(driver_poll() == 5000)
assert(#posts == 1 and posts[1]:find("/command/wake_up", 1, true))
assert(not latest())
now = now + 5000
body = data(100, math.floor(host.unix_ms()/1000))
assert(driver_poll() == 60000)
assert(latest().soc == 100 and latest().soc_fresh == true and latest().stale == false)
assert(#posts == 1, "read-after-wake issued a second wake")

-- A successful repeated cached payload keeps its BMS timestamp and becomes stale.
local observed = latest().soc_observed_at_ms
now = now + 60000
driver_poll()
assert(latest().soc_fresh == false and latest().soc_observed_at_ms == observed)
now = now + 600000
driver_poll()
assert(latest().soc_fresh == false and latest().stale == true)
assert(latest().soc_observed_at_ms == observed)
assert(#posts == 2)

-- Restart and rename cannot replenish the VIN-keyed wake budget.
load(true)
body = ""
driver_poll()
assert(#posts == 1)
now = now + 1000
load(false)
body = ""
driver_poll()
assert(#posts == 0, "restart renewed wake budget")
for i=1,2 do
  now = now + 90000
  driver_poll()
end
assert(#posts == 2)
now = now + 90000
driver_poll()
assert(#posts == 2, "more than three wakes in a 30-minute window")

-- Ordinary errors recover; proxy busy responses retain the three-minute backoff.
load(true)
request_err = "HTTP 500 failure"
driver_poll()
assert(#posts == 1)
for _, err in ipairs({"HTTP 408 unavailable", "HTTP 503 busy"}) do
  load(true)
  request_err = err
  assert(driver_poll() == 180000 and #posts == 0)
  now = now + 180000
  request_err, body = nil, ""
  assert(driver_poll() == 5000 and #posts == 1)
end

-- Invalid timestamps and malformed successful responses never become fresh SoC.
for _, value in ipairs({0, -1, math.floor((epoch+3600000)/1000)}) do
  load(true)
  body = data(80, value)
  driver_poll()
  assert(not latest() and #posts == 1)
end
load(true)
body = "invalid JSON"
driver_poll()
assert(#posts == 1 and not latest())

-- An old first observation is retained with its actual age, not receipt time.
load(true)
local old_seconds = math.floor((host.unix_ms()-600000)/1000)
body = data(90, old_seconds)
driver_poll()
assert(latest().stale == true)
assert(latest().soc_observed_at_ms == old_seconds*1000.0)

-- A goal refresh is wake-only and schedules an early read even during cooldown.
load(true)
assert(driver_command("wake_up") == true)
local count = #posts
driver_command("wake_up")
assert(#posts == count and host._poll_interval_ms == 5000)

-- HTTP 200 and an outer success must not hide an inner rejection.
local good_post = host.http_post
for _, reply in ipairs({{}, {response={result=false}},
  {result=true,response={result=false}}, {result=false,response={result=true}},
  {response={result=true,response={result=false}}}}) do
  load(true)
  function host.http_post(url)
    posts[#posts+1] = url
    return host.json_encode(reply)
  end
  assert(driver_command("wake_up") == false)
end
host.http_post = good_post

-- A host without durable reservations fails closed; reads continue.
load(true)
local reserve = host.reserve_vehicle_wake
host.reserve_vehicle_wake = nil
body = ""
driver_poll()
assert(#posts == 0)
host.reserve_vehicle_wake = reserve
print("Tesla BLE recovery: cold boot, source age, errors, restart budget and wake-only refresh pass")
