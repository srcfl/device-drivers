-- Tesla Vehicle Driver (telemetry-only, via TeslaMate MQTT)
-- Emits: Vehicle (DerVehicle)
-- Protocol: MQTT (TeslaMate retained topics teslamate/cars/{id}/…)
--
-- Optional SoC next to tesla_vehicle.lua (TeslaBLEProxy on the LAN).
-- This file does not replace that driver, and it is not a Fleet API client.
-- FTW reads the TeslaMate instance the owner already runs. It does not talk
-- to Tesla Fleet cloud and it does not ingest Home Assistant entities.
-- Cloud access is not a charging prerequisite: an asleep or unreachable car
-- is a supported case, and Core already plans from a stated default or the
-- plug-in slider.
--
-- Telemetry only. No wake, charge_start, or other vehicle command. TeslaMate
-- MQTT is subscribe-only; this driver never publishes.
--
-- TeslaMate does not publish VIN on MQTT (privacy). Bind identity from YAML:
-- host.set_make("Tesla"), host.set_sn(VIN). Car id selects the topic prefix.
--
-- Vendor document:
--   https://docs.teslamate.org/docs/integrations/mqtt
-- TeslaMate payloads are per-topic strings, retained. While the car is
-- asleep TeslaMate stops updating; retained values can be hours old. Age
-- is host.millis() of the last awake observation (online / charging /
-- driving / updating / starting). Replay with stale=true / soc_fresh=false
-- until STALE_AFTER_MS, then stop. A first subscribe that only sees an
-- asleep car is not a live observation and emits nothing.
--
-- Config (MQTT host/port/user live on the capability grant, not here):
--
--   drivers:
--     - name: teslamate
--       lua: drivers/teslamate_vehicle.lua
--       capabilities:
--         mqtt:
--           host: 192.168.1.10   # TeslaMate's broker (often Mosquitto)
--           port: 1883
--           username: ""         # optional
--           password: ""         # optional
--       config:
--         vin: "5YJ3E1EA1KF000000"   # required — TeslaMate MQTT has no VIN
--         car_id: 1                  # TeslaMate id, usually starts at 1
--         # topic_prefix: teslamate/cars/1   # optional override of the prefix
--
-- Enable MQTT in TeslaMate (MQTT_HOST in its compose) before pointing FTW
-- at the broker. Settings → Devices currently scaffolds vehicle drivers as
-- {ip, vin} (BLE proxy). Edit the YAML for TeslaMate MQTT.
--
-- No HTTP. TeslaMate's UI and GraphQL are out of scope. If a later HTTP
-- lookup is added, grant capabilities.http.allowed_hosts for that host only.

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "teslamate_vehicle",
  name         = "Tesla Vehicle (TeslaMate)",
  manufacturer = "Tesla",
  version      = "0.1.0",
  protocols    = { "mqtt" },
  capabilities = { "vehicle" },
  read_only    = true,
  description  = "Read-only Tesla vehicle SoC, charge limit and charging state via TeslaMate MQTT. Optional next to tesla_vehicle (BLE). Does not wake or command the car.",
  homepage     = "https://docs.teslamate.org/docs/integrations/mqtt",
  authors      = { "FTW contributors" },
  tested_models = { "Model Y", "Model 3" },
  verification_status = "experimental",
}

PROTOCOL = "mqtt"

-- File-local so host.mqtt_subscribe(base_topic .. "/#") stays a static
-- topic expression for the MQTT contract tests.
local base_topic = "teslamate/cars/1"

local POLL_INTERVAL_MS   = 5000
local STALE_AFTER_MS     = 900000
local WATCHDOG_TIMEOUT_S = 300

local AWAKE = {
  online    = true,
  charging  = true,
  driving   = true,
  updating  = true,
  starting  = true,
}

local vin = nil

-- Last live (awake) observation. seen_ms is host.millis() when TeslaMate
-- last published charge fields while the car was awake. TeslaMate's
-- ISO `since` cannot be compared to host.millis() (monotonic uptime),
-- and os.time is sandbox-forbidden in this repository.
local last = {
  seen_ms                = 0,
  soc                    = nil,
  charge_limit           = nil,
  charging_state         = nil,
  time_to_full           = nil,
  charge_amps            = nil,
  charger_actual_current = nil,
  tm_state               = nil,
  healthy                = nil,
}

-- Fields collected from MQTT that have not yet been accepted as a live
-- observation. Kept across polls so state and battery_level can arrive
-- on different ticks.
local incoming = {
  soc                    = nil,
  charge_limit           = nil,
  charging_state         = nil,
  time_to_full           = nil,
  charge_amps            = nil,
  charger_actual_current = nil,
}

local function payload_present(p)
  if p == nil then return false end
  local s = tostring(p)
  return s ~= "" and s ~= "nil" and s ~= "null"
end

local function as_bool(p)
  if p == true then return true end
  if p == false then return false end
  local s = tostring(p or ""):lower()
  if s == "true" or s == "1" then return true end
  if s == "false" or s == "0" then return false end
  return nil
end

local function model_name(raw)
  local s = tostring(raw or "")
  if s == "3" or s == "Y" or s == "S" or s == "X" then
    return "Model " .. s
  end
  return s
end

local function normalize_prefix(s)
  s = tostring(s or ""):gsub("/+$", "")
  s = s:gsub("/#$", "")
  return s
end

local function topic_key(topic)
  if type(topic) ~= "string" then return nil end
  local prefix = base_topic .. "/"
  if topic:sub(1, #prefix) ~= prefix then return nil end
  local key = topic:sub(#prefix + 1)
  -- TeslaMate charge fields are a single path segment. Reject
  -- teslamate/cars/10/... when the prefix is teslamate/cars/1.
  if key == "" or key:find("/", 1, true) then return nil end
  return key
end

local function hours_to_min(hours)
  local h = tonumber(hours)
  if h == nil then return nil end
  return math.floor(h * 60 + 0.5)
end

local function reset_incoming()
  incoming.soc                    = nil
  incoming.charge_limit           = nil
  incoming.charging_state         = nil
  incoming.time_to_full           = nil
  incoming.charge_amps            = nil
  incoming.charger_actual_current = nil
end

local function reset_last()
  last.seen_ms                = 0
  last.soc                    = nil
  last.charge_limit           = nil
  last.charging_state         = nil
  last.time_to_full           = nil
  last.charge_amps            = nil
  last.charger_actual_current = nil
  last.tm_state               = nil
  last.healthy                = nil
  reset_incoming()
end

local function car_is_awake()
  local state = last.tm_state
  return type(state) == "string" and AWAKE[state] == true
end

local function can_accept_fresh()
  if not vin or vin == "" then return false end
  if last.healthy == false then return false end
  return car_is_awake()
end

local function remember()
  local soc = tonumber(incoming.soc)
  if soc == nil then soc = last.soc end
  if soc == nil then return false end
  last.soc = soc
  if incoming.charge_limit ~= nil then
    last.charge_limit = tonumber(incoming.charge_limit)
  end
  if incoming.charge_amps ~= nil then
    last.charge_amps = tonumber(incoming.charge_amps)
  end
  if incoming.charger_actual_current ~= nil then
    last.charger_actual_current = tonumber(incoming.charger_actual_current)
  end
  local cs = incoming.charging_state
  if type(cs) == "string" and cs ~= "" then
    last.charging_state = cs
  end
  if incoming.time_to_full ~= nil then
    last.time_to_full = incoming.time_to_full
  end
  last.seen_ms = host.millis()
  return true
end

local function emit_vehicle(fresh)
  if last.soc == nil or last.seen_ms == 0 then return end
  local age = host.millis() - last.seen_ms
  if age > STALE_AFTER_MS then
    return
  end
  host.emit("vehicle", {
    soc                    = last.soc,
    charge_limit_pct       = last.charge_limit,
    charging_state         = last.charging_state,
    time_to_full_min       = last.time_to_full,
    charge_amps            = last.charge_amps,
    charger_actual_current = last.charger_actual_current,
    stale                  = not fresh,
    soc_fresh              = fresh,
  })
end

-- Returns true when this message is a live charge-field update. State,
-- health and model do not refresh seen_ms on their own.
local function apply_message(msg)
  if type(msg) ~= "table" then return false end
  local key = topic_key(msg.topic)
  if not key then return false end
  local p = msg.payload
  if key == "state" then
    if payload_present(p) then
      last.tm_state = tostring(p):lower()
    end
    return false
  end
  if key == "healthy" then
    local b = as_bool(p)
    if b ~= nil then last.healthy = b end
    return false
  end
  if key == "model" then
    if payload_present(p) and host.set_model then
      host.set_model(model_name(p))
    end
    return false
  end
  if key == "battery_level" then
    local n = tonumber(p)
    if n == nil then return false end
    incoming.soc = n
    return true
  end
  if key == "charge_limit_soc" then
    local n = tonumber(p)
    if n == nil then return false end
    incoming.charge_limit = n
    return true
  end
  if key == "charging_state" then
    if not payload_present(p) then return false end
    incoming.charging_state = tostring(p)
    return true
  end
  if key == "time_to_full_charge" then
    local mins = hours_to_min(p)
    if mins == nil then return false end
    incoming.time_to_full = mins
    return true
  end
  if key == "charge_current_request" then
    local n = tonumber(p)
    if n == nil then return false end
    incoming.charge_amps = n
    return true
  end
  if key == "charger_actual_current" then
    local n = tonumber(p)
    if n == nil then return false end
    incoming.charger_actual_current = n
    return true
  end
  return false
end

function driver_init(config)
  host.set_make("Tesla")
  config = config or {}

  if config.vin and tostring(config.vin) ~= "" then
    vin = tostring(config.vin)
    host.set_sn(vin)
  else
    host.log("error", "teslamate_vehicle: config.vin required (TeslaMate MQTT does not publish VIN)")
  end

  if config.topic_prefix and tostring(config.topic_prefix) ~= "" then
    base_topic = normalize_prefix(config.topic_prefix)
  elseif config.base_topic and tostring(config.base_topic) ~= "" then
    base_topic = normalize_prefix(config.base_topic)
  elseif config.topic and tostring(config.topic) ~= "" then
    base_topic = normalize_prefix(config.topic)
  elseif config.car_id ~= nil and tostring(config.car_id) ~= "" then
    base_topic = "teslamate/cars/" .. tostring(config.car_id)
  else
    base_topic = "teslamate/cars/1"
  end

  if host.set_watchdog_timeout_s then
    host.set_watchdog_timeout_s(WATCHDOG_TIMEOUT_S)
  end
  host.set_poll_interval(500)

  -- Real host returns nil on success. The test mock returns true.
  local err = host.mqtt_subscribe(base_topic .. "/#")
  if type(err) == "string" and err ~= "" then
    host.log("error", "teslamate_vehicle: subscribe failed: " .. err)
  else
    host.log("info", "teslamate_vehicle: subscribed to " .. base_topic .. "/#" ..
                     " vin=" .. tostring(vin or "(missing)") ..
                     " telemetry-only")
  end
end

function driver_poll()
  host.set_poll_interval(POLL_INTERVAL_MS)

  if not vin or vin == "" then
    return POLL_INTERVAL_MS
  end

  local messages = host.mqtt_messages()
  if not messages then messages = {} end
  local saw_charge = false
  for _, msg in ipairs(messages) do
    if apply_message(msg) then saw_charge = true end
  end

  -- Only a charge-field message while TeslaMate says the car is awake
  -- starts (or refreshes) the age clock. Idle polls and asleep retained
  -- values must not look like a new BMS reading.
  if can_accept_fresh() and saw_charge and remember() then
    host.log("info", "teslamate_vehicle: emit soc=" .. tostring(last.soc) ..
                     " limit=" .. tostring(last.charge_limit) ..
                     " state=" .. tostring(last.charging_state) ..
                     " tm=" .. tostring(last.tm_state))
    emit_vehicle(true)
  else
    emit_vehicle(false)
  end

  return POLL_INTERVAL_MS
end

function driver_cleanup()
  reset_last()
  vin = nil
  base_topic = "teslamate/cars/1"
end
