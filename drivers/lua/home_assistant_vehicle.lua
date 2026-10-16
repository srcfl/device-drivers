-- Vehicle from Home Assistant (telemetry-only, via MQTT)
-- Emits: Vehicle (DerVehicle)
-- Protocol: MQTT (a JSON message a Home Assistant automation publishes)
--
-- For a car whose level Home Assistant already reads, through the Tesla
-- Custom Integration or any other car integration. An automation in Home
-- Assistant publishes one JSON message to a topic the owner picks, every
-- 30 seconds and whenever a car entity changes. This driver only
-- subscribes: FTW holds no Home Assistant token, calls no Home Assistant
-- API and sends nothing back. It never wakes or commands the car.
--
-- The message. Times are Unix seconds, as Home Assistant's as_timestamp
-- gives them. Leave out, or send null for, what Home Assistant does not
-- know.
--   available        true when the car entities have values
--   soc_pct          0-100
--   observed_at      when the integration last read the car
--   source_age_s     seconds since observed_at, by Home Assistant's clock
--   charge_limit_pct 0-100
--   charging_state   Charging | Starting | NoPower | Stopped | Complete |
--                    Disconnected
--   plugged          true when the charge cable is in, false when it is out
--   plugged_since    when the cable entity took that state (last_changed);
--                    send it only when the integration reads the cable at
--                    least every 30 seconds, see below
--   at_site          true when the car's tracker is in zone home, false
--                    when it is somewhere else
-- source_age_s measures the car's reading, not the moment Home Assistant
-- forwards it, so a repeat never makes an old reading fresh. A message
-- older than the last one (smaller observed_at) is ignored.
--
-- plugged, plugged_since and at_site let FTW tell which car was plugged in
-- (FTW docs/cars.md, rule 2). Home Assistant's zone home must be this site.
-- last_changed is when Home Assistant read the change, not the plug-in: an
-- integration that polls a car every few minutes dates a plug-in minutes
-- late, and FTW would match it to the wrong charger or none. FTW counts a
-- cable time only within a minute of a charger's plug-in, so leave
-- plugged_since out of the template unless the integration reads the cable
-- at least every 30 seconds while the car is at home.
--
-- Config (MQTT host/port/user live on the capability grant, not here):
--
--   drivers:
--     - name: tesla-ha
--       lua: drivers/home_assistant_vehicle.lua
--       capabilities:
--         mqtt:
--           host: 192.168.1.10   # the broker Home Assistant publishes to
--           port: 1883
--       config:
--         topic: ftw/vehicle/tesla-ha/state
--         vin: "5YJ3E1EA1KF000000"   # binds the reading to the car
--         make: Tesla                # optional
--         model: Model Y             # optional
--
-- Automation for the Tesla Custom Integration with a car named "Tesla
-- Model Y". Other integrations name their entities differently; map them
-- in the template. The cable is binary_sensor.<car>_charger (device class
-- plug, with the car's charging_state as an attribute); the place is
-- device_tracker.<car>_location_tracker.
--
--   - id: ftw_tesla_mqtt
--     alias: "FTW: Tesla via MQTT"
--     triggers:
--       - trigger: state
--         entity_id:
--           - sensor.tesla_model_y_battery
--           - sensor.tesla_model_y_data_last_update_time
--           - number.tesla_model_y_charge_limit
--           - binary_sensor.tesla_model_y_charger
--           - device_tracker.tesla_model_y_location_tracker
--       - trigger: time_pattern
--         seconds: "/30"
--       - trigger: homeassistant
--         event: start
--     actions:
--       - action: mqtt.publish
--         data:
--           topic: ftw/vehicle/tesla-ha/state
--           qos: 0
--           retain: false
--           payload: >-
--             {% set cable = states.binary_sensor.tesla_model_y_charger %}
--             {% set known = cable is not none and cable.state in ['on', 'off'] %}
--             {% set tracker = 'device_tracker.tesla_model_y_location_tracker' %}
--             {% set observed = as_timestamp(states('sensor.tesla_model_y_data_last_update_time'), 0) %}
--             {% set soc = states('sensor.tesla_model_y_battery') | float(-1) %}
--             {% set charging = state_attr('binary_sensor.tesla_model_y_charger', 'charging_state') %}
--             {{ {
--               'available': observed > 0 and soc >= 0 and soc <= 100,
--               'soc_pct': soc,
--               'charge_limit_pct': states('number.tesla_model_y_charge_limit') | float(-1),
--               'charging_state': charging if charging else ('Disconnected' if known and cable.state == 'off' else ''),
--               'observed_at': observed,
--               'source_age_s': as_timestamp(now()) - observed,
--               'plugged': (cable.state == 'on') if known else none,
--               'at_site': is_state(tracker, 'home') if has_value(tracker) else none
--             } | to_json }}
--     mode: restart
--
-- With an integration that reads the cable at least every 30 seconds, add
--               'plugged_since': as_timestamp(cable.last_changed) if known else none,
--
-- Publish non-retained: a retained message would replay an old reading at
-- every reconnect.

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "home_assistant_vehicle",
  name         = "Vehicle (Home Assistant MQTT)",
  manufacturer = "Home Assistant",
  version      = "0.1.0",
  protocols    = { "mqtt" },
  capabilities = { "vehicle" },
  read_only    = true,
  description  = "Read-only vehicle level, charge limit, charging state, charge cable and place from a JSON message a Home Assistant automation publishes over MQTT. Does not wake or command the car.",
  homepage     = "https://www.home-assistant.io/integrations/mqtt/",
  authors      = { "FTW contributors" },
  tested_models = { "Model Y" },
  verification_status = "experimental",
}

PROTOCOL = "mqtt"

-- File-local so host.mqtt_subscribe(topic) stays a static topic expression
-- for the MQTT contract tests.
local topic = "ftw/vehicle/car/state"

local POLL_MS            = 5000
local WATCHDOG_TIMEOUT_S = 60
-- A car reading older than this is not fresh: Core's own live window.
local MAX_AGE_S          = 300
-- Home Assistant publishes every 30 seconds. After this long without a
-- message the broker or Home Assistant is gone, and the driver stops
-- emitting so Core sees the gap instead of a replay.
local SILENT_AFTER_MS    = 900000

local CHARGING_STATES = {
  Charging = true, Starting = true, NoPower = true,
  Stopped = true, Complete = true, Disconnected = true,
}

local vin = nil
-- The last accepted message, as it will be emitted.
local last = nil
-- observed_at (Unix seconds) of the last accepted message.
local observed_at = nil
-- host.millis() after which the last reading is older than MAX_AGE_S.
local expires_ms = 0
-- host.millis() of the last message on the topic, valid or not.
local heard_ms = 0

-- Logs get pasted into public issues, and a VIN identifies the owner's
-- car. Every log line therefore shows only the VIN's last four characters.
local function log(level, message)
  message = tostring(message)
  if type(vin) == "string" and #vin > 4 then
    local escaped = vin:gsub("%p", "%%%0")
    message = message:gsub(escaped, "****" .. vin:sub(-4))
  end
  host.log(level, message)
end

local function finite(n)
  return type(n) == "number" and n == n and n > -math.huge and n < math.huge
end

local function percent(n)
  return finite(n) and n >= 0 and n <= 100
end

-- FTW reads a vehicle soc of 1 or less as a fraction, and more as a
-- percent; FTW before 0.131 reads every value as a percent. A percent above
-- 1 means the same to both, so only 1 % or less goes as a fraction: 0.01 is
-- 1 % to a new FTW and 0.01 % to an old one, where a plain 1 would be 100 %.
local function soc_value(pct)
  if pct <= 1 then return pct / 100 end
  return pct
end

local function bool_or_nil(v)
  if v == true or v == false then return v end
  return nil
end

-- Unix ms on the box's clock. A Home Assistant clock a little ahead of the
-- box must not put a reading in the future, which Core refuses.
local function to_ms(seconds)
  local ms = math.floor(seconds * 1000)
  if host.unix_ms then
    local now = host.unix_ms()
    if finite(now) and ms > now then ms = math.floor(now) end
  end
  return ms
end

local function decode(payload)
  local ok, p = pcall(host.json_decode, payload)
  if ok and type(p) == "table" then return p end
  return nil
end

-- A message whose reading is usable: a level, its time and its age.
local function usable(p)
  return p.available == true and percent(p.soc_pct)
    and finite(p.observed_at) and p.observed_at > 0
    and finite(p.source_age_s) and p.source_age_s >= 0
end

local function reading_from(p)
  local r = {
    soc                = soc_value(p.soc_pct),
    charge_limit_pct   = percent(p.charge_limit_pct) and p.charge_limit_pct or nil,
    charging_state     = CHARGING_STATES[p.charging_state] and p.charging_state or nil,
    soc_observed_at_ms = to_ms(p.observed_at),
    plugged            = bool_or_nil(p.plugged),
    at_site            = bool_or_nil(p.at_site),
  }
  if r.plugged ~= nil and finite(p.plugged_since) and p.plugged_since > 0 then
    r.plugged_since_ms = to_ms(p.plugged_since)
  end
  return r
end

-- Returns true when the message carried a newer car reading.
local function apply(p, now)
  if not usable(p) then
    -- Unavailable or invalid: the old value must not stay live.
    expires_ms = 0
    return false
  end
  if observed_at ~= nil and p.observed_at < observed_at then
    return false
  end
  local deadline = now + (MAX_AGE_S - p.source_age_s) * 1000
  local newer = observed_at == nil or p.observed_at > observed_at
  if newer then
    expires_ms = deadline
  else
    -- A repeat of the same reading may say it is older, never younger.
    expires_ms = math.min(expires_ms, deadline)
  end
  observed_at = p.observed_at
  last = reading_from(p)
  return newer and p.source_age_s < MAX_AGE_S
end

function driver_init(config)
  config = config or {}
  last, observed_at, expires_ms, heard_ms = nil, nil, 0, 0
  -- Home Assistant does not say the make; a wrong one is worse than none.
  if type(config.make) == "string" and config.make ~= "" then
    host.set_make(config.make)
  end
  if type(config.model) == "string" and config.model ~= "" and host.set_model then
    host.set_model(config.model)
  end
  if type(config.vin) == "string" and config.vin ~= "" then
    vin = config.vin
    host.set_sn(vin)
  else
    vin = nil
    log("error", "home_assistant_vehicle: config.vin required to bind the reading to a car")
  end
  if type(config.topic) == "string" and config.topic ~= "" then
    topic = config.topic
  else
    log("error", "home_assistant_vehicle: config.topic required")
  end
  if host.set_watchdog_timeout_s then
    host.set_watchdog_timeout_s(WATCHDOG_TIMEOUT_S)
  end
  host.set_poll_interval(POLL_MS)
  local err = host.mqtt_subscribe(topic)
  if type(err) == "string" and err ~= "" then
    log("error", "home_assistant_vehicle: subscribe failed: " .. err)
  else
    log("info", "home_assistant_vehicle: subscribed to " .. topic ..
                " vin=" .. tostring(vin or "(missing)") .. " telemetry-only")
  end
end

function driver_poll()
  host.set_poll_interval(POLL_MS)
  local now = host.millis()
  local fresh = false
  local messages = host.mqtt_messages()
  if not messages then messages = {} end
  for _, msg in ipairs(messages) do
    if type(msg) == "table" and msg.topic == topic then
      heard_ms = now
      local p = decode(msg.payload)
      if p then
        if apply(p, now) then fresh = true end
      else
        expires_ms = 0
      end
    end
  end
  if not vin or not last or now - heard_ms > SILENT_AFTER_MS then
    return POLL_MS
  end
  local stale = now >= expires_ms
  host.emit("vehicle", {
    soc                = last.soc,
    charge_limit_pct   = last.charge_limit_pct,
    charging_state     = last.charging_state,
    soc_observed_at_ms = last.soc_observed_at_ms,
    plugged            = last.plugged,
    plugged_since_ms   = last.plugged_since_ms,
    at_site            = last.at_site,
    stale              = stale,
    soc_fresh          = fresh and not stale,
  })
  return POLL_MS
end

function driver_command()
  return false
end

function driver_default_mode()
  return true
end

function driver_cleanup()
  last, observed_at, expires_ms, heard_ms = nil, nil, 0, 0
  vin = nil
  topic = "ftw/vehicle/car/state"
end
