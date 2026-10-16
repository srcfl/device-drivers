dofile("drivers/tests/lua_harness/host_mock.lua")

-- Recorded on 15 October 2026 from a Model Y on the Tesla Custom
-- Integration (VIN replaced). The message the site's automation published:
local RECORDED = '{"available":true,"soc_pct":14.0,"charge_limit_pct":80.0,' ..
  '"charging_state":"Stopped","observed_at":1792082304.0,"source_age_s":1476.321958065033}'
-- The entities behind it at that moment:
--   sensor.tesla_model_y_battery = 14
--   sensor.tesla_model_y_data_last_update_time = 2026-10-15T16:38:24+00:00
--   number.tesla_model_y_charge_limit = 80
--   binary_sensor.tesla_model_y_charger = on, updated 16:38:24.065320+00:00,
--     {charging_state: Stopped, conn_charge_cable: IEC, device_class: plug}
-- The same moment rendered by the automation in the driver's header, with
-- the car's tracker in zone home and a fresh reading:
local OBSERVED = 1792082304.0
local CABLE_CHANGED = 1792082304.06532
-- JSON as Home Assistant's to_json writes it: numbers as floats. The
-- harness's decoder reads an integer above 2^31 wrongly in 32-bit Lua.
local function json(m)
  local keys = {}
  for k in pairs(m) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    local v, out = m[k], nil
    if type(v) == "number" then out = string.format("%.6f", v)
    elseif type(v) == "boolean" then out = tostring(v)
    else out = string.format("%q", tostring(v)) end
    parts[#parts + 1] = string.format("%q", k) .. ":" .. out
  end
  return "{" .. table.concat(parts, ",") .. "}"
end
local function message(over)
  local m = {
    available = true, soc_pct = 14.0, charge_limit_pct = 80.0,
    charging_state = "Stopped", observed_at = OBSERVED, source_age_s = 20.0,
    plugged = true, plugged_since = CABLE_CHANGED, at_site = true,
  }
  for k, v in pairs(over or {}) do
    if v == "nil" then m[k] = nil else m[k] = v end
  end
  return json(m)
end

-- The harness runs 32-bit Lua (LUA_32BITS), where an epoch in seconds is
-- exact only to 128 s and one in ms to about 131 s. FTW runs 64-bit floats.
-- So times step by 128 s here, and an expected ms value takes the same JSON
-- path the driver's input takes.
local STEP = 128
local function ms(seconds)
  return math.floor(host.json_decode('{"v":' .. string.format("%.6f", seconds) .. '}').v * 1000)
end

local VIN = "5YJ3E1EA1KF000000"
local TOPIC = "ftw/vehicle/tesla-ha/state"
-- The box's clock, 20 s after the reading.
local box_ms = (OBSERVED + 20) * 1000

local function boot(cfg)
  host.reset()
  host.unix_ms = function() return box_ms end
  dofile("drivers/lua/home_assistant_vehicle.lua")
  driver_init(cfg or { topic = TOPIC, vin = VIN, make = "Tesla", model = "Model Y" })
end

local function send(payload, topic)
  host._mqtt_buffer = { { topic = topic or TOPIC, payload = payload } }
  driver_poll()
end

local function last()
  local rows = host._emitted.vehicle
  if not rows or #rows == 0 then return nil end
  return rows[#rows]
end

local function count()
  return host._emitted.vehicle and #host._emitted.vehicle or 0
end

local function subscribed()
  for i = 1, #host._calls do
    if host._calls[i].func == "mqtt_subscribe" then return host._calls[i].args[1] end
  end
end

boot()
assert(host._make == "Tesla" and host._model == "Model Y" and host._sn == VIN, "identity from config")
assert(subscribed() == TOPIC, "subscribes to the configured topic")

-- The recorded message, as the site's automation sends it today: no cable
-- or place fields, and a reading 25 minutes old.
send(RECORDED)
local r = last()
assert(r, "the recorded message emits")
assert(r.soc == 14, "14 % as a percent, which every FTW reads alike, got " .. tostring(r.soc))
assert(r.charge_limit_pct == 80, "80 % limit")
assert(r.charging_state == "Stopped", "charging state")
assert(r.soc_observed_at_ms == ms(OBSERVED), "the car's reading time")
assert(r.stale == true and r.soc_fresh == false, "a 25-minute-old reading is not fresh")
assert(r.plugged == nil and r.plugged_since_ms == nil and r.at_site == nil,
  "an automation without cable or place says nothing about them")

-- The same moment with the cable and place mapped.
boot()
send(message())
r = last()
assert(r.soc_fresh == true and r.stale == false, "a 20 s old reading is fresh")
assert(r.plugged == true, "plugged from binary_sensor.<car>_charger")
assert(r.plugged_since_ms == ms(CABLE_CHANGED), "plugged_since_ms from last_changed, got " .. tostring(r.plugged_since_ms))
assert(r.at_site == true, "at_site from the tracker in zone home")

-- A replay keeps the cable and place and the reading's time, not fresh.
driver_poll()
r = last()
assert(r.soc_fresh == false and r.plugged == true and r.plugged_since_ms == ms(CABLE_CHANGED) and r.at_site == true,
  "replay keeps the last word")

-- Unplugged at the site, then away: the newest message wins.
box_ms = (OBSERVED + 10 * STEP) * 1000
send(message({ observed_at = OBSERVED + STEP, plugged = false, plugged_since = OBSERVED + STEP }))
r = last()
assert(r.plugged == false and r.plugged_since_ms == ms(OBSERVED + STEP) and r.at_site == true,
  "cable out")
send(message({ observed_at = OBSERVED + 8 * STEP, plugged = false, at_site = false }))
r = last()
assert(r.at_site == false, "the tracker left zone home")

-- An older message cannot overwrite a newer one.
send(message({ observed_at = OBSERVED + 2 * STEP, plugged = true, at_site = true }))
r = last()
assert(r.plugged == false and r.at_site == false, "an out-of-order message is ignored")

-- A cable time without a cable state means nothing.
boot()
send(message({ plugged = "nil" }))
r = last()
assert(r.plugged == nil and r.plugged_since_ms == nil, "no plugged, no plugged_since_ms")

-- null from the template, and non-boolean values, are unknown.
boot()
send('{"available":true,"soc_pct":50,"observed_at":1792082304,"source_age_s":1,' ..
     '"plugged":null,"plugged_since":null,"at_site":"home"}')
r = last()
assert(r.plugged == nil and r.at_site == nil and r.plugged_since_ms == nil, "null and strings are unknown")

-- A Home Assistant clock ahead of the box cannot put a time in the future.
boot()
box_ms = (OBSERVED + 20) * 1000
send(message({ observed_at = OBSERVED + 2 * STEP, plugged_since = OBSERVED + 2 * STEP, source_age_s = 0 }))
r = last()
assert(r.soc_observed_at_ms == math.floor(box_ms) and r.plugged_since_ms == math.floor(box_ms),
  "times capped at the box's clock")

-- An unavailable message leaves the old values stale, not live.
boot()
send(message())
send('{"available":false,"observed_at":1792082400}')
r = last()
assert(r.stale == true and r.soc_fresh == false, "unavailable marks the reading stale")

-- Invalid JSON, out-of-range levels and other topics.
boot()
send("not json")
assert(count() == 0, "nothing before a valid reading")
send(message({ soc_pct = 101 }))
assert(count() == 0, "a level above 100 % is refused")
send(message(), "ftw/vehicle/other/state")
assert(count() == 0, "another topic is ignored")

-- 1 % or less goes as a fraction: FTW reads a plain 1 as 100 %.
boot()
send(message({ soc_pct = 1.0 }))
assert(last().soc == 0.01, "1 % as 0.01, got " .. tostring(last().soc))
send(message({ observed_at = OBSERVED + STEP, soc_pct = 0.0 }))
assert(last().soc == 0, "0 % is 0")
send(message({ observed_at = OBSERVED + 2 * STEP, soc_pct = 2.0 }))
assert(last().soc == 2, "2 % stays a percent")

-- No VIN: nothing is emitted, since the reading cannot be bound to a car.
boot({ topic = TOPIC })
send(message())
assert(count() == 0, "no VIN, no emit")

-- Silence: after 15 minutes without a message the driver stops emitting.
boot()
send(message())
local before = count()
host._millis_counter = host._millis_counter + 900001
driver_poll()
assert(count() == before, "silent broker: no replay")

-- Read-only: no publish, no command.
for i = 1, #host._calls do
  assert(host._calls[i].func ~= "mqtt_publish", "the driver never publishes")
end
assert(driver_command() == false and driver_default_mode() == true, "read-only hooks")

print("PASS home_assistant_vehicle")
