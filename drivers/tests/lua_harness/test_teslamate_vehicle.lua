dofile("drivers/tests/lua_harness/host_mock.lua")

local VIN = "5YJ3E1EA1KF000000"

local function boot(cfg)
  host.reset()
  dofile("drivers/lua/teslamate_vehicle.lua")
  driver_init(cfg or { vin = VIN, car_id = 1 })
end

local function last_vehicle()
  local rows = host._emitted.vehicle
  if not rows or #rows == 0 then return nil end
  return rows[#rows]
end

local function count_publish()
  local n = 0
  for i = 1, #host._calls do
    if host._calls[i].func == "mqtt_publish" then n = n + 1 end
  end
  return n
end

local function subscribed_topic()
  for i = 1, #host._calls do
    local c = host._calls[i]
    if c.func == "mqtt_subscribe" then return c.args[1] end
  end
  return nil
end

local function push(fields)
  fields = fields or {}
  local prefix = fields.prefix or "teslamate/cars/1"
  local msgs = {}
  local function add(key, value)
    if value ~= nil then
      msgs[#msgs + 1] = { topic = prefix .. "/" .. key, payload = tostring(value) }
    end
  end
  add("state", fields.state)
  add("healthy", fields.healthy)
  add("model", fields.model)
  add("battery_level", fields.soc)
  add("charge_limit_soc", fields.limit)
  add("charging_state", fields.charging_state)
  add("time_to_full_charge", fields.ttf_h)
  add("charge_current_request", fields.amps)
  add("charger_actual_current", fields.actual)
  host._mqtt_buffer = msgs
end

boot()
assert(host._make == "Tesla", "set_make Tesla")
assert(host._sn == VIN, "set_sn from config VIN")
assert(subscribed_topic() == "teslamate/cars/1/#", "default subscribe prefix")

push({
  state = "charging",
  healthy = "true",
  model = "Y",
  soc = 67,
  limit = 80,
  charging_state = "Charging",
  ttf_h = 0.7,
  amps = 16,
  actual = 15,
})
driver_poll()
local sample = last_vehicle()
assert(sample, "awake car must emit DerVehicle")
assert(sample.soc == 67, "soc")
assert(sample.charge_limit_pct == 80, "charge_limit_pct")
assert(sample.charging_state == "Charging", "charging_state")
assert(sample.time_to_full_min == 42, "hours converted to minutes")
assert(sample.charge_amps == 16, "charge_amps from charge_current_request")
assert(sample.charger_actual_current == 15, "charger_actual_current")
assert(sample.stale == false, "fresh emit is not stale")
assert(sample.soc_fresh == true, "soc_fresh")
assert(host._model == "Model Y", "model letter mapped")
assert(count_publish() == 0, "must not publish MQTT")

-- time_to_full_charge 1.5 h → 90 min.
boot()
push({
  state = "charging",
  healthy = "true",
  soc = 50,
  limit = 80,
  charging_state = "Charging",
  ttf_h = 1.5,
})
driver_poll()
assert(last_vehicle().time_to_full_min == 90, "1.5 hours → 90 min")

-- Retained asleep at first subscribe is not a live observation.
boot()
push({
  state = "asleep",
  healthy = "true",
  soc = 67,
  limit = 80,
  charging_state = "Complete",
})
driver_poll()
assert(last_vehicle() == nil, "asleep retained must not invent a fresh SoC")

-- Missing battery_level is not a zero SoC.
boot()
push({
  state = "online",
  healthy = "true",
  charging_state = "Stopped",
  limit = 80,
})
driver_poll()
assert(last_vehicle() == nil, "no battery_level invented SoC")

-- Unhealthy logger is not a live observation.
boot()
push({
  state = "charging",
  healthy = "false",
  soc = 41,
  limit = 80,
  charging_state = "Charging",
})
driver_poll()
assert(last_vehicle() == nil, "unhealthy TeslaMate must not emit fresh")

-- Live charge, then the car sleeps: replay stale, then stop.
boot()
push({
  state = "charging",
  healthy = "true",
  soc = 67,
  limit = 80,
  charging_state = "Charging",
  ttf_h = 0.5,
})
driver_poll()
assert(last_vehicle() and last_vehicle().soc_fresh == true, "prime cache")
local after_fresh = #(host._emitted.vehicle)
host._mqtt_buffer = {
  { topic = "teslamate/cars/1/state", payload = "asleep" },
}
driver_poll()
assert(#(host._emitted.vehicle) == after_fresh + 1, "replay cache while young")
assert(last_vehicle().stale == true, "replay is stale")
assert(last_vehicle().soc_fresh == false, "replay is not fresh")
assert(last_vehicle().soc == 67, "replay keeps SoC")
assert(count_publish() == 0, "asleep poll must not publish")

host._millis_counter = host._millis_counter + 900001
local before_stale = #(host._emitted.vehicle)
host._mqtt_buffer = {}
driver_poll()
assert(#(host._emitted.vehicle) == before_stale, "stop emitting when stale")

-- Idle poll after a live reading also ages out.
boot()
push({
  state = "online",
  healthy = "true",
  soc = 55,
  limit = 90,
  charging_state = "Disconnected",
})
driver_poll()
assert(last_vehicle() and last_vehicle().soc == 55, "online parked emits")
host._mqtt_buffer = {}
driver_poll()
assert(last_vehicle().soc_fresh == false, "idle replay is not fresh")
assert(last_vehicle().stale == true, "idle replay is stale")
host._millis_counter = host._millis_counter + 900001
local n = #(host._emitted.vehicle)
host._mqtt_buffer = {}
driver_poll()
assert(#(host._emitted.vehicle) == n, "idle poll stops after STALE_AFTER_MS")

-- car_id and topic_prefix select the MQTT prefix.
boot({ vin = VIN, car_id = 2 })
assert(subscribed_topic() == "teslamate/cars/2/#", "car_id subscribe")
push({
  prefix = "teslamate/cars/2",
  state = "charging",
  healthy = "true",
  soc = 33,
  limit = 70,
  charging_state = "Charging",
})
-- A leftover car 1 topic must not leak into car 2.
host._mqtt_buffer[#host._mqtt_buffer + 1] = {
  topic = "teslamate/cars/1/battery_level", payload = "99",
}
driver_poll()
assert(last_vehicle() and last_vehicle().soc == 33, "car_id isolates topics")

boot({ vin = VIN, topic_prefix = "teslamate/cars/4/#" })
assert(subscribed_topic() == "teslamate/cars/4/#", "topic_prefix strips /#")
push({
  prefix = "teslamate/cars/4",
  state = "charging",
  healthy = "true",
  soc = 12,
  limit = 50,
  charging_state = "Starting",
})
driver_poll()
assert(last_vehicle() and last_vehicle().charging_state == "Starting", "topic_prefix")

-- VIN is required; no identity, no emit.
boot({ car_id = 1 })
assert(host._sn == nil, "no VIN at init")
push({
  state = "charging",
  healthy = "true",
  soc = 80,
  charging_state = "Charging",
})
driver_poll()
assert(last_vehicle() == nil, "missing VIN must not emit")
assert(count_publish() == 0, "missing VIN must not publish")

-- TeslaMate "nil" payload is absence, not zero.
boot()
push({
  state = "charging",
  healthy = "true",
  soc = 40,
  limit = 80,
  charging_state = "Charging",
})
driver_poll()
host._mqtt_buffer = {
  { topic = "teslamate/cars/1/state", payload = "charging" },
  { topic = "teslamate/cars/1/healthy", payload = "true" },
  { topic = "teslamate/cars/1/charging_state", payload = "nil" },
}
driver_poll()
assert(last_vehicle().charging_state == "Charging", "nil payload must not wipe state")

assert(count_publish() == 0, "driver must never mqtt_publish")
print("OK teslamate_vehicle")
