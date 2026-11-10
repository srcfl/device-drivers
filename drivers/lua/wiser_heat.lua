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
  description  = "Schneider Electric / Drayton Wiser heating hub via its local HTTPS API. Read-only: room temperatures and setpoints, smoke alarm temperatures, heating channel demand.",
  homepage     = "https://www.se.com/ww/en/product-range/65635-wiser-heating/",
  authors      = { "hannesb90", "Claude (Anthropic)" },
  tested_models = { "Wiser Hub R gen 2 (WT704R1B30S4)" },
  verification_status = "experimental",
  verification_notes  = "Checked against one Wiser Hub R gen 2 (WT704R1B30S4, firmware 4.50.4) with one smoke alarm and no thermostat or valve, on 2026-11-10. Room temperatures from real thermostats are decoded but not yet seen.",
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

local function next_poll(ms)
    host.set_poll_interval(ms)
    return ms
end

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
    -- base_url override exists for tests; production builds it from host.
    local base = s(config.base_url)
    if not base and s(config.host) then
        -- The hub serves HTTPS on 443. A port is added only when the owner
        -- configured another, so allowed_hosts can stay the bare address.
        local port = s(config.port)
        base = "https://" .. s(config.host)
        if port and port ~= "443" then base = base .. ":" .. port end
    end
    if base then url = base .. "/data/domain/" end
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

    for _, r in ipairs(data.Room or {}) do
        local id = tonumber(r.id)
        if id then
            emit("room_" .. id .. "_temp_c", temp(r.CalculatedTemperature), "°C")
            local sp = tonumber(r.CurrentSetPoint)
            if sp ~= nil and sp > SETPOINT_OFF then
                emit("room_" .. id .. "_setpoint_c", temp(sp), "°C")
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
