-- Schneider Electric / Drayton Wiser heating hub — local HTTPS API, read-only.
--
-- Emits: metrics only, via host.emit_metric. No power stream, so no sign
-- conversion: the hub measures temperature and demand, not watts.
-- Control: none. New drivers start read-only.
--
-- WHAT IT READS
--   One GET of https://<hub>/data/domain/ per poll, the hub's whole state as
--   JSON. From it:
--   - each Room:  room_<id>_temp_c       CalculatedTemperature, 0.1 °C
--                 room_<id>_setpoint_c   CurrentSetPoint, 0.1 °C
--                 room_<id>_temp_is_floor 1 when the room is controlled on
--                                         floor temperature, 0 on air
--                 room_<id>_demand_pct   PercentageDemand
--                 room_<id>_output_on    ControlOutputState
--   - each HeatingActuator with a floor sensor (e.g. a Renova CFMT 16 A
--     floor thermostat):
--                 heating_actuator_<id>_floor_temp_c  floor sensor, 0.1 °C
--                 heating_actuator_<id>_floor_max_c   floor upper limit
--                 heating_actuator_<id>_floor_min_c   floor lower limit
--                 heating_actuator_<id>_power_est_w   estimated draw, only
--                                                     when configured (below)
--   - each SmokeAlarmDevice: smoke_alarm_<id>_temp_c  MeasuredTemperature
--   - each HeatingChannel:   heating_channel_<id>_demand_pct  PercentageDemand
--                            heating_channel_<id>_relay_on    HeatingRelayState
--   Ids are the hub's own and stay put while devices stay paired, so a room
--   keeps its metric name. Room names are owner text and stay out of metric
--   names.
--
-- WHAT THE HUB SAYS WHEN IT KNOWS NOTHING
--   Measured on a Wiser Hub R gen 2 (WT704R1B30S4, firmware 4.50.4) on
--   2026-11-10:
--   - A room with no thermostat or valve assigned reports
--     CalculatedTemperature -32768 and CurrentSetPoint -200, with
--     Invalid = "NothingAssigned". Neither is emitted.
--   - -200 (-20.0 °C) is also what Wiser uses for a room set to off, so a
--     setpoint at or below it is "no setpoint", not -20 °C.
--   The Wiser community libraries also treat 2000 (200.0 °C) as a sensor
--   error; it is dropped as well.
--
-- ROOM TEMPERATURE CAN BE A FLOOR TEMPERATURE
--   A floor thermostat in a floor-control preset (Renova CFMT P7/P8) makes
--   the room's CalculatedTemperature the floor sensor's reading
--   (InputTemperatureType "Floor"); in a room preset with floor limit (P6)
--   it is the thermostat's air sensor ("Air") and the floor sensor only
--   bounds it. room_<id>_temp_is_floor says which, so 26 °C of floor is not
--   read as 26 °C of air.
--
-- FLOOR SENSOR TYPE
--   The hub reports the configured sensor type (NTC_10K, NTC_15K, ...) but
--   cannot know the probe in the floor. A wrong type still reads plausibly:
--   on the test site a 15 kOhm probe configured as 10 kOhm read 17.4 °C
--   while the floor surface measured 26.6-27.5 °C, and after setting
--   NTC_15K it read 27.0 °C. The type is logged when it changes, and the
--   floor reading is emitted only while the sensor status is
--   Normal_Operation.
--
-- ESTIMATED POWER
--   A Renova CFMT switches its load with a relay and measures no power:
--   the hub reports InstantaneousDemand and CurrentSummationDelivered as 0
--   with the relay on. When the owner states the load, the driver emits
--   heating_actuator_<id>_power_est_w = rated W x room PercentageDemand.
--   The thermostat drives the relay time-proportionally over its cycle
--   (CycleTime_10, ten minutes), so the demand is the share of the cycle the
--   relay is on, and the product is the average draw over the cycle, not
--   the instant one. It is a metric, not a power stream: it is an estimate
--   and must not be added to a measured site balance. The rated W is, per
--   actuator id, either rated_w (the heating cable or mat's own rating, best
--   when known) or area_m2 x w_per_m2 (w_per_m2 defaults to 110, a common
--   rating for floor heating mats in bathrooms). Nothing is emitted for an
--   actuator without a configured load.
--
-- STALENESS
--   The hub answers from its own cache. A device whose Device entry shows
--   DisplayedSignalStrength "Offline" or "NoSignal" has its temperature
--   left out, since the hub would otherwise keep serving its last value.
--
-- SETUP
--   The hub's local API needs its SECRET, which the hub hands out on
--   GET http://<hub>/secret only while it is in setup mode (press Setup on
--   the hub; it leaves setup mode by itself after 15 minutes). The secret
--   is masked via config_secrets. The hub's certificate is self-signed, so
--   the host pins it with tls_pin_sha256:
--     openssl s_client -connect <hub>:443 </dev/null | \
--       openssl x509 -noout -fingerprint -sha256
--
-- Config example (config.yaml):
--   drivers:
--     - name: wiser
--       lua: drivers/wiser_heat.lua
--       config:
--         host: "<hub-ip>"
--         secret: "<hub secret>"          # masked via config_secrets
--         floor_heating:                  # optional, per heating actuator id
--           - actuator: 8
--             area_m2: 4.5                # x w_per_m2 (default 110)
--             # w_per_m2: 130             # the owner's own rating per m²
--             # rated_w: 600              # or the cable's total rating
--       capabilities:
--         http:
--           allowed_hosts: ["<hub-ip>"]
--           tls_pin_sha256: "<64-hex-char certificate fingerprint>"

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "wiser_heat",
  name         = "Wiser heating hub",
  manufacturer = "Schneider Electric",
  version      = "0.1.0",
  protocols    = { "http" },
  capabilities = { "apicreds" },
  read_only    = true,
  description  = "Schneider Electric / Drayton Wiser heating hub via its local HTTPS API. Read-only: room temperatures, setpoints and demand, floor thermostat floor temperature and limits, smoke alarm temperatures, heating channel demand.",
  homepage     = "https://www.se.com/ww/en/product-range/65635-wiser-heating/",
  authors      = { "hannesb90", "Claude (Anthropic)" },
  tested_models = { "Wiser Hub R gen 2 (WT704R1B30S4)", "Renova Connected Thermostat 16 A (WDE011680)" },
  verification_status = "experimental",
  verification_notes  = "Checked against one Wiser Hub R gen 2 (WT704R1B30S4, firmware 4.50.4) with smoke alarms and one Renova CFMT 16 A floor thermostat (WDE011680) on electric floor heating, on 2026-11-10 and 2026-11-11, in both the floor-control (P8) and room-with-floor-limit (P6) presets. Radiator valves (iTRV) and room stats are decoded only as rooms; not seen.",
  config_secrets = { "secret" },
}

PROTOCOL = "http"

local NO_TEMP      = -32768 -- nothing measured
local TEMP_ERROR   = 2000   -- 200.0 °C, a sensor error
local SETPOINT_OFF = -200   -- -20.0 °C, off or no control

-- Applied with host.set_poll_interval: an interval returned from driver_poll
-- is capped at 30 s by the host, so returning 60000 alone would poll the
-- hub twice as often as meant. Returned too, so the two always agree.
local POLL_MS  = 60000
local RETRY_MS = 30000

local DEFAULT_W_PER_M2 = 110
-- Bounds on a configured load. 16 A x 230 V is the most a CFMT relay
-- switches; a figure outside these is a typing error, not a floor.
local MAX_RATED_W  = 3680
local MAX_AREA_M2  = 200
local MAX_W_PER_M2 = 300

local function next_poll(ms)
    host.set_poll_interval(ms)
    return ms
end

local rated_w  = {}  -- actuator id -> configured load in W
local url      = nil
local headers  = nil
local identity = false

local function present(v)
    return v ~= nil and v ~= "" and v ~= NO_TEMP
end

-- A temperature in 0.1 °C, or nil.
local function temp(v)
    v = tonumber(v)
    if v == nil or v == NO_TEMP or v >= TEMP_ERROR then return nil end
    return v / 10
end

local function emit(name, value, unit)
    if value ~= nil then host.emit_metric(name, value, unit) end
end

local OFFLINE = { Offline = true, NoSignal = true }
local ON_OFF  = { On = 1, Off = 0 }
local IS_FLOOR = { Floor = 1, Air = 0 }

-- Last floor sensor type and status logged per actuator, so a change is
-- logged once rather than every minute.
local floor_seen = {}

local function device_online(devices, id)
    local d = devices[id]
    -- A device the hub does not list is not one it can vouch for.
    if d == nil then return false end
    return not OFFLINE[tostring(d.DisplayedSignalStrength)]
end

local function read_identity(data)
    if identity then return end
    for _, d in ipairs(data.Device or {}) do
        if d.ProductType == "Controller" then
            if present(d.ModelIdentifier) then host.set_model(tostring(d.ModelIdentifier)) end
            if present(d.UUID) then host.set_sn(tostring(d.UUID)) end
            identity = true
            local fw = d.ActiveFirmwareVersion
            if present(fw) then host.log("info", "Wiser: hub firmware " .. tostring(fw)) end
            return
        end
    end
end

function driver_init(config)
    host.set_make("Wiser")
    config = config or {}
    local function s(v) return (v ~= nil and v ~= "") and tostring(v) or nil end
    -- The URL is always built from host, and always HTTPS: the request
    -- carries the hub's secret, and an empty allowed_hosts lets the host
    -- reach any address, so no config value may point it elsewhere or at
    -- clear-text HTTP.
    if s(config.host) then
        -- The hub serves HTTPS on 443. A port is added only when the owner
        -- configured another, so allowed_hosts can stay the bare address.
        local port = s(config.port)
        url = "https://" .. s(config.host)
        if port and port ~= "443" then url = url .. ":" .. port end
        url = url .. "/data/domain/"
    end
    rated_w = {}
    local fh = config.floor_heating
    if type(fh) == "table" then
        for _, e in ipairs(fh) do
            local id = type(e) == "table" and tonumber(e.actuator) or nil
            local w = nil
            if id then
                local rw, area = tonumber(e.rated_w), tonumber(e.area_m2)
                local per = tonumber(e.w_per_m2) or DEFAULT_W_PER_M2
                if rw ~= nil then
                    if rw > 0 and rw <= MAX_RATED_W then w = rw end
                elseif area ~= nil and area > 0 and area <= MAX_AREA_M2
                        and per > 0 and per <= MAX_W_PER_M2 then
                    w = area * per
                    if w > MAX_RATED_W then w = nil end
                end
            end
            if w then
                rated_w[id] = w
                host.log("info", string.format(
                    "Wiser: heating actuator %d load %.0f W (estimate)", id, w))
            else
                host.log("warn", "Wiser: floor_heating entry ignored: needs actuator and "
                    .. "rated_w (1-" .. MAX_RATED_W .. " W) or area_m2 (1-" .. MAX_AREA_M2
                    .. " m2) with w_per_m2 (1-" .. MAX_W_PER_M2 .. ")")
            end
        end
    end

    local secret = s(config.secret)
    if secret then headers = { SECRET = secret, Accept = "application/json" } end
    if not url then host.log("warn", "Wiser: no host configured") end
    if not headers then host.log("warn", "Wiser: no secret configured") end
end

function driver_poll()
    if not url or not headers then return next_poll(RETRY_MS) end

    local ok, body, err = pcall(host.http_get, url, headers)
    if not ok then err = tostring(body); body = nil end
    if body == nil then
        -- Nothing from the hub means nothing is emitted: no reading here is
        -- fresh. A 401 is a wrong or reset secret.
        host.log("warn", "Wiser: hub did not answer: " .. tostring(err))
        host.emit_metric("wiser_poll_ok", 0, "")
        return next_poll(RETRY_MS)
    end
    local dok, data = pcall(host.json_decode, body)
    if not dok or type(data) ~= "table" then
        host.log("warn", "Wiser: hub answer was not JSON")
        host.emit_metric("wiser_poll_ok", 0, "")
        return next_poll(RETRY_MS)
    end

    read_identity(data)

    local devices = {}
    for _, d in ipairs(data.Device or {}) do
        if d.id ~= nil then devices[d.id] = d end
    end

    local room_demand = {}
    for _, r in ipairs(data.Room or {}) do
        local id = tonumber(r.id)
        if id then
            room_demand[id] = tonumber(r.PercentageDemand)
            emit("room_" .. id .. "_temp_c", temp(r.CalculatedTemperature), "°C")
            local sp = tonumber(r.CurrentSetPoint)
            if sp ~= nil and sp > SETPOINT_OFF then
                emit("room_" .. id .. "_setpoint_c", temp(sp), "°C")
            end
            -- A room with nothing assigned has none of these fields.
            if temp(r.CalculatedTemperature) ~= nil then
                emit("room_" .. id .. "_temp_is_floor", IS_FLOOR[r.InputTemperatureType], "")
            end
            emit("room_" .. id .. "_demand_pct", tonumber(r.PercentageDemand), "%")
            emit("room_" .. id .. "_output_on", ON_OFF[r.ControlOutputState], "")
        end
    end

    for _, a in ipairs(data.HeatingActuator or {}) do
        local id = tonumber(a.id)
        local f = a.FloorTemperatureSensor
        if id and type(f) == "table" and device_online(devices, a.DeviceId) then
            local seen = tostring(f.SensorType) .. "/" .. tostring(f.Status)
            if floor_seen[id] ~= seen then
                floor_seen[id] = seen
                host.log("info", "Wiser: heating actuator " .. id .. " floor sensor "
                    .. tostring(f.SensorType) .. ", status " .. tostring(f.Status))
            end
            local p = "heating_actuator_" .. id
            if f.Status == "Normal_Operation" then
                emit(p .. "_floor_temp_c", temp(f.MeasuredTemperature), "°C")
            end
            emit(p .. "_floor_max_c", temp(f.MaximumTemperature), "°C")
            emit(p .. "_floor_min_c", temp(f.MinimumTemperature), "°C")
        end
        local w = id and rated_w[id]
        if w and device_online(devices, a.DeviceId) then
            local dev = devices[a.DeviceId]
            local demand = room_demand[tonumber(dev.RoomId)]
            if demand ~= nil and demand >= 0 and demand <= 100 then
                emit("heating_actuator_" .. id .. "_power_est_w",
                    math.floor(w * demand / 100 + 0.5), "W")
            end
        end
    end

    for _, s in ipairs(data.SmokeAlarmDevice or {}) do
        local id = tonumber(s.id)
        if id and device_online(devices, s.DeviceId) then
            emit("smoke_alarm_" .. id .. "_temp_c", temp(s.MeasuredTemperature), "°C")
        end
    end

    for _, h in ipairs(data.HeatingChannel or {}) do
        local id = tonumber(h.id)
        if id then
            emit("heating_channel_" .. id .. "_demand_pct", tonumber(h.PercentageDemand), "%")
            if h.HeatingRelayState == "On" then
                emit("heating_channel_" .. id .. "_relay_on", 1, "")
            elseif h.HeatingRelayState == "Off" then
                emit("heating_channel_" .. id .. "_relay_on", 0, "")
            end
        end
    end

    host.emit_metric("wiser_poll_ok", 1, "")
    return next_poll(POLL_MS)
end

function driver_cleanup()
end
