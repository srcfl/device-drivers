-- Hardy Barth (eCharge) wallbox, local HTTP API
-- Emits: EV
-- Protocol: HTTP on the LAN, port 80
--
-- Hardy Barth builds two controllers with two different APIs. This driver
-- finds out which one answers, or takes config.controller ("ecb1" or
-- "salia").
--
-- eCB1 controller (cPH1 and other eCB1 boxes). Source: eCB1 REST API 1.3,
--   http://apidoc.ecb1.de (Swagger: http://apidoc.ecb1.de/doc/api/v1/swagger.json)
--   GET  /api/v1/chargecontrols/{id}            connected, stateid, mode,
--                                               manualmodeamp, currentpwmamp,
--                                               evminamp
--   GET  /api/v1/chargecontrols/{id}/maxcurrent the socket's maximum current
--   GET  /api/v1/meters/{id}                    OBIS values: 1-0:1.4.0 power W,
--                                               1-0:1.8.0 energy kWh,
--                                               1-0:31/51/71.4.0 current A,
--                                               1-0:32/52/72.4.0 voltage V
--   POST /api/v1/chargecontrols/{id}/mode                mode=manual
--   POST /api/v1/chargecontrols/{id}/mode/manual/ampere  manualmodeamp=<A>
--   POST /api/v1/chargecontrols/{id}/start | /stop
--   Writes are form-encoded. manualmodeamp only acts in manual mode, so the
--   first order that needs current sets the mode to manual. That setting
--   stays. The API does not list state ids; stateid 5 is charging and 17 is
--   stopped, as evcc has seen on these boxes. The driver remembers which of
--   start and stop it sent last, and sends stop again only while the car
--   still charges.
--
-- Salia controller (cPH2, cPu2). Source: eCharge Salia REST API,
--   https://docs.echarge.de/api/salia
--   GET  /api/?reset    the whole station as JSON; ?reset reads it fresh
--   POST /api/          {"grid_current_limit": "<A>"}: the external limit,
--                       "0" stops charging. The reply is {"result":"ok"}.
--   Firmware 2.3.81 and later wants an Apikey header on writes
--   (config.api_key). The station offers the lowest of its external,
--   internal and manual limits, so this driver's limit is a ceiling: eco
--   mode or the web UI slider can hold the car lower, and the driver says
--   so. Power needs the station's meter (metering/meter/available = 1).
--
-- Control (both):
--   An order of power_w becomes whole amps per phase, rounded down:
--     amps = floor(power_w / (voltage * phases))
--   phases is 3 unless the installation is one-phase (config.phases = 1) and
--   the car is not measured on more than one phase, or Core asks for "1p" and
--   the car is measured on exactly one. An idle charger counts as
--   three-phase, so a three-phase car never gets a one-phase sum. The result
--   never exceeds Core's max_amps_per_phase or cap_amps_per_phase or the
--   station's own maximum. Below its minimum (at least 6 A) the station is
--   stopped; an order is never rounded up. Only what differs from the
--   station's last report is written.
--   driver_default_mode stops the station once: /stop on eCB1, a limit of
--   0 A on Salia. Core runs it at every start, so it acts only after FTW
--   has written to the station in this run. The stop stays until FTW
--   orders current again.
--
-- Sign convention: w is positive while the car charges.
--
-- Config example:
--   drivers:
--     - name: hardybarth
--       lua: drivers/hardybarth.lua
--       capabilities:
--         http:
--           allowed_hosts: ["192.168.1.80"]
--       config:
--         host: 192.168.1.80
--         port: 80
--         phases: 3        # optional; 1 for a one-phase installation
--         controller: ""   # optional: "ecb1" or "salia"
--         connector: 1     # eCB1 charge control and meter id
--         api_key: ""      # Salia firmware 2.3.81 and later

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "hardybarth",
  name         = "Hardy Barth / eCharge",
  manufacturer = "HardyBarth",
  version      = "1.1.0",
  protocols    = { "http" },
  capabilities = { "ev" },
  description  = "Hardy Barth / eCharge wallbox on the LAN, eCB1 (cPH1) or Salia (cPH2, cPu2) controller. Reads power and energy, and sets the charging current and start/stop.",
  homepage     = "https://echarge.de",
  authors      = { "FTW contributors" },
  tested_models = { "cPH1", "cPH2", "cPu2" },
  verification_status = "experimental",
  verification_notes = "Control written from the eCB1 REST API 1.3 and the eCharge Salia REST API documentation; not yet confirmed on hardware.",
  config_secrets = { "api_key" },
  connection_defaults = {
    port = 80,
  },
}

PROTOCOL = "http"

local POLL_MS = 5000
local RETRY_MS = 10000
local LIMITS_EVERY_MS = 60000
local DETECT_EVERY_MS = 30000

local MIN_A = 6
local MAX_A = 32
local PHASE_ACTIVE_A = 1.0
local STALL_MS = 30000
local DEFAULT_ATTEMPTS = 3

-- eCB1 state ids seen by evcc; the API document does not list them.
local ECB1_CHARGING = 5
local ECB1_STOPPED = 17

local FORM = { ["Content-Type"] = "application/x-www-form-urlencoded" }

local base_url = nil
local forced_kind = nil
local kind = nil              -- "ecb1" or "salia" once known
local detect_due_ms = 0
local connector = 1
local api_headers = nil
local identity_set = false
local eco_warned = false

-- What the station last reported, updated by every write it accepted.
local dev = {}
local measured_phases = nil
local measured_v = nil
local limits_due_ms = 0
local limits_read_ms = nil

local phases_cfg = 3           -- config.phases: the installation's phase count
-- Core runs driver_default_mode at every start. It stands down only after FTW
-- wrote to the charger in this run, or found it already holding FTW's order,
-- so a charger FTW never steered keeps the owner's own setting.
local ftw_wrote = false
local last_order_a = nil
local stood_down = false
local default_failures = 0
local stalled_since = nil

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

-- Salia sends every value as a string; eCB1 sends numbers.
local function num(v)
  if type(v) == "string" then v = tonumber(v) end
  if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
    return nil
  end
  return v
end

local function at(t, ...)
  for _, k in ipairs({ ... }) do
    if type(t) ~= "table" then return nil end
    t = t[k]
  end
  return t
end

local function http_get_json(path)
  local ok, body, err = pcall(host.http_get, base_url .. path)
  if not ok then return nil, tostring(body) end
  if not body then return nil, tostring(err or "no reply") end
  local ok2, data = pcall(host.json_decode, body)
  if not ok2 or type(data) ~= "table" then return nil, "reply is not JSON" end
  return data
end

local function post(path, body, headers, what)
  ftw_wrote = true
  local ok, reply, err = pcall(host.http_post, base_url .. path, body, headers)
  if not ok or not reply then
    host.log("warn", "Hardy Barth: " .. what .. " failed: " .. tostring(ok and err or reply))
    return nil
  end
  return reply
end

local function note_phases(a, v)
  local active, v_sum, v_n = 0, 0, 0
  for i = 1, 3 do
    if a[i] and a[i] >= PHASE_ACTIVE_A then active = active + 1 end
    if v[i] and v[i] > 100 and v[i] < 300 then v_sum, v_n = v_sum + v[i], v_n + 1 end
  end
  measured_phases = active > 0 and active or nil
  measured_v = v_n > 0 and (v_sum / v_n) or nil
end

local function device_min_a()
  local m = dev.min_a
  if m and m > MIN_A and m <= MAX_A then return m end
  return MIN_A
end

local function device_max_a()
  local cap = MAX_A
  local cfg, socket = dev.max_a_cfg, dev.socket_max_a
  if cfg and cfg >= MIN_A and cfg < cap then cap = cfg end
  if socket and socket >= MIN_A and socket < cap then cap = socket end
  return cap
end

-- Whole amps per phase for a power order. Rounds down and never up.
local function amps_for(power_w, cmd)
  power_w = num(power_w)
  if not power_w or power_w <= 0 then return 0 end
  if type(cmd) ~= "table" then cmd = {} end
  local voltage = num(cmd.voltage)
  if not voltage or voltage < 100 then voltage = measured_v or 230 end
  -- Divide by one phase only when the installation is one-phase and the
  -- car is not measured on more, or Core asks for "1p" and the car is
  -- measured on exactly one. An idle charger proves nothing, so a
  -- three-phase car never gets a one-phase sum.
  local live = measured_phases or 0
  local phases = 3
  if (phases_cfg == 1 and live <= 1) or (cmd.phase_mode == "1p" and live == 1) then phases = 1 end
  -- 0.001 A of slack so float rounding cannot turn 6.0 into 5.
  local amps = math.floor(power_w / (voltage * phases) + 0.001)
  local limit = device_max_a()
  local max_cmd = num(cmd.max_amps_per_phase)
  if max_cmd and max_cmd > 0 and max_cmd < limit then limit = max_cmd end
  local cap_cmd = num(cmd.cap_amps_per_phase)
  if cap_cmd and cap_cmd >= 0 and cap_cmd < limit then limit = cap_cmd end
  limit = math.floor(limit + 0.001)
  if amps > limit then amps = limit end
  if amps < device_min_a() then return 0 end
  return amps
end

local function stall_check(blocked, now)
  if not blocked then
    stalled_since = nil
    return false
  end
  stalled_since = stalled_since or now
  return (now - stalled_since) >= STALL_MS
end

----------------------------------------------------------------------------
-- eCB1
----------------------------------------------------------------------------

local function ecb1_path(suffix)
  return "/api/v1/chargecontrols/" .. connector .. (suffix or "")
end

local function ecb1_poll(now)
  local c = http_get_json(ecb1_path())
  local cc = c and c.chargecontrol
  local m = type(cc) == "table" and http_get_json("/api/v1/meters/" .. connector)
  local md = m and at(m, "meter", "data")
  local power_w = md and num(md["1-0:1.4.0"])
  if not power_w then
    host.log("warn", "Hardy Barth: eCB1 charge control or meter read failed")
    return false
  end

  if not identity_set then
    if type(cc.type) == "string" and cc.type ~= "" then host.set_model(cc.type) end
    identity_set = true
  end

  dev.mode = type(cc.mode) == "string" and cc.mode or nil
  dev.amp = num(cc.manualmodeamp)
  local stateid = num(cc.stateid)
  if stateid then dev.stopped = (stateid == ECB1_STOPPED) else dev.stopped = nil end
  dev.connected = nil
  if type(cc.connected) == "boolean" then dev.connected = cc.connected end
  dev.min_a = num(cc.evminamp)

  if now >= limits_due_ms then
    limits_due_ms = now + LIMITS_EVERY_MS
    local mc = http_get_json(ecb1_path("/maxcurrent"))
    if mc and num(mc.maxcurrent) then
      dev.socket_max_a, limits_read_ms = num(mc.maxcurrent), now
    end
  end

  local a = { num(md["1-0:31.4.0"]), num(md["1-0:51.4.0"]), num(md["1-0:71.4.0"]) }
  local v = { num(md["1-0:32.4.0"]), num(md["1-0:52.4.0"]), num(md["1-0:72.4.0"]) }
  note_phases(a, v)
  local kwh = num(md["1-0:1.8.0"])

  local charging = nil
  if stateid then charging = (stateid == ECB1_CHARGING) end
  dev.charging = charging
  local max_a = nil
  if dev.stopped then
    max_a = 0
  elseif dev.mode == "manual" then
    max_a = dev.amp
  end

  host.emit("ev", {
    w                  = power_w,
    connected          = dev.connected,
    charging           = charging,
    lifetime_wh        = kwh and kwh * 1000 or nil,
    max_a              = max_a,
    current_limit_a    = num(cc.currentpwmamp),
    device_limit_a     = limits_read_ms and dev.socket_max_a or nil,
    device_limit_age_s = limits_read_ms and dev.socket_max_a and (now - limits_read_ms) / 1000 or nil,
    phases             = measured_phases,
    l1_a = a[1], l2_a = a[2], l3_a = a[3],
    l1_v = v[1], l2_v = v[2], l3_v = v[3],
  })
  return true
end

-- start and stop are remembered as sent: the API has no documented field
-- that says a socket is stopped, and a stop sent again on every 0 W order
-- would write each tick. A stop goes out again when the car still charges.
local function ecb1_apply(amps)
  if amps <= 0 then
    if dev.sent == "stop" and dev.charging ~= true then return true end
    if not post(ecb1_path("/stop"), "", FORM, "stop") then return false end
    dev.sent, dev.stopped = "stop", true
    return true
  end
  if dev.mode ~= "manual" then
    if not post(ecb1_path("/mode"), "mode=manual", FORM, "mode=manual") then return false end
    dev.mode = "manual"
  end
  if dev.amp ~= amps then
    if not post(ecb1_path("/mode/manual/ampere"), string.format("manualmodeamp=%d", amps),
        FORM, "manualmodeamp") then return false end
    dev.amp = amps
  end
  -- "start" acts on a connected car. Without one, the next order starts it.
  if dev.sent ~= "start" and dev.connected ~= false then
    if not post(ecb1_path("/start"), "", FORM, "start") then return false end
    dev.sent, dev.stopped = "start", false
  end
  return true
end

----------------------------------------------------------------------------
-- Salia
----------------------------------------------------------------------------

local function salia_poll(now, snap)
  snap = snap or http_get_json("/api/?reset")
  local port = at(snap, "secc", "port0")
  local metering = at(port, "metering")
  local power_dw = num(at(metering, "power", "active_total", "actual"))
  if not power_dw then
    host.log("warn", "Hardy Barth: Salia read failed or the station has no meter")
    return false
  end
  local power_w = power_dw / 10   -- deci-watts

  if not identity_set then
    local sn = at(snap, "device", "serial")
    if type(sn) == "string" and sn ~= "" then host.set_sn(sn) end
    local model = at(snap, "device", "modelname")
    if type(model) == "string" and model ~= "" then host.set_model(model) end
    identity_set = true
  end

  local salia = at(port, "salia")
  local basic = at(port, "ci", "evse", "basic")
  dev.lane = num(at(basic, "grid_current_limit", "actual"))
  dev.min_a = num(at(salia, "socketminamp"))
  dev.max_a_cfg = num(at(salia, "max_amp"))
  dev.socket_max_a = num(at(salia, "socketmaxamp"))
  local offered = num(at(basic, "offered_current_limit"))
  local mode = at(salia, "chargemode")
  if mode == "eco" and not eco_warned then
    host.log("warn", "Hardy Barth: the station is in eco mode; it may hold the car " ..
      "below FTW's limit. Set it to manual or power.")
    eco_warned = true
  end

  local cp = at(port, "ci", "charge", "cp", "status")
  local connected, charging = nil, nil
  if cp == "A" then
    connected, charging = false, false
  elseif cp == "B" then
    connected, charging = true, false
  elseif cp == "C" or cp == "D" then
    connected, charging = true, true
  end

  local a, v = {}, {}
  for i, l in ipairs({ "l1", "l2", "l3" }) do
    local ma = num(at(metering, "current", "ac", l, "actual"))
    local cv = num(at(metering, "voltage", "ac", l, "actual"))
    a[i] = ma and ma / 1000 or nil   -- milliamps
    v[i] = cv and cv / 100 or nil    -- centivolts
  end
  note_phases(a, v)

  -- chargedata is "elapsed_s|power_w|energy_kwh|rfid" during a session.
  local session_wh = nil
  local cd = at(salia, "chargedata")
  if type(cd) == "string" then
    local kwh = num(cd:match("^[^|]*|[^|]*|([^|]*)"))
    if kwh then session_wh = kwh * 1000 end
  end

  local reason = nil
  if connected and not charging then
    if at(salia, "pausecharging") == "1" then
      reason = "paused at the station"
    elseif mode == "eco" then
      reason = "eco mode"
    elseif offered and dev.lane and offered + 0.5 < dev.lane then
      reason = "another station limit is lower"
    end
  end
  local blocked = connected == true and charging == false and (dev.lane or 0) >= MIN_A
    and offered ~= nil and offered < MIN_A

  local ceiling = nil
  if dev.max_a_cfg or dev.socket_max_a then ceiling = device_max_a() end

  host.emit("ev", {
    w                       = power_w,
    connected               = connected,
    charging                = charging,
    session_wh              = session_wh,
    lifetime_wh             = num(at(metering, "energy", "active_import", "actual")),
    max_a                   = dev.lane,
    current_limit_a         = offered,
    device_limit_a          = ceiling,
    device_limit_age_s      = ceiling and 0 or nil,
    phases                  = measured_phases,
    reason_no_current_label = reason,
    command_stalled         = stall_check(blocked, now),
    l1_a = a[1], l2_a = a[2], l3_a = a[3],
    l1_v = v[1], l2_v = v[2], l3_v = v[3],
  })
  return true
end

local function salia_apply(amps)
  if dev.lane == amps then return true end
  local body = host.json_encode({ grid_current_limit = string.format("%d", amps) })
  local reply = post("/api/", body, api_headers, "grid_current_limit=" .. amps)
  if not reply then return false end
  local ok, data = pcall(host.json_decode, reply)
  if not ok or type(data) ~= "table" or data.result ~= "ok" then
    host.log("warn", "Hardy Barth: station refused grid_current_limit=" .. amps ..
      ": " .. tostring(reply))
    return false
  end
  dev.lane = amps
  return true
end

----------------------------------------------------------------------------
-- Driver interface
----------------------------------------------------------------------------

-- Which controller answers? Returns a Salia snapshot when it found one, so
-- the first poll does not read it twice.
local function detect(now)
  if forced_kind then
    kind = forced_kind
    return nil
  end
  if now < detect_due_ms then return nil end
  detect_due_ms = now + DETECT_EVERY_MS
  local c = http_get_json(ecb1_path())
  if c and type(c.chargecontrol) == "table" then
    kind = "ecb1"
    host.log("info", "Hardy Barth: eCB1 controller")
    return nil
  end
  local snap = http_get_json("/api/?reset")
  if at(snap, "secc", "port0") then
    kind = "salia"
    host.log("info", "Hardy Barth: Salia controller")
    return snap
  end
  host.log("warn", "Hardy Barth: neither an eCB1 nor a Salia controller answered")
  return nil
end

function driver_init(config)
  config = config or {}
  local port = config.port or 80
  base_url = "http://" .. tostring(config.host) .. ":" .. tostring(port)
  if config.controller == "ecb1" or config.controller == "salia" then
    forced_kind = config.controller
  end
  local p = tonumber(config.phases)
  if p == 1 or p == 3 then phases_cfg = p end
  local id = num(config.connector)
  if id and id >= 1 then connector = string.format("%d", id) else connector = "1" end
  if type(config.api_key) == "string" and config.api_key ~= "" then
    api_headers = { Apikey = config.api_key }
  end
  host.set_make("HardyBarth")
end

function driver_poll()
  local now = host.millis()
  local snap = nil
  if not kind then
    snap = detect(now)
    if not kind then return RETRY_MS end
  end
  local ok
  if kind == "ecb1" then ok = ecb1_poll(now) else ok = salia_poll(now, snap) end
  if not ok then
    dev.amp, dev.stopped, dev.lane, dev.mode = nil, nil, nil, nil
    dev.sent, dev.charging, dev.connected = nil, nil, nil
    measured_phases, measured_v, stalled_since = nil, nil, nil
    return RETRY_MS
  end
  return POLL_MS
end

local function apply(amps)
  if kind == "ecb1" then return ecb1_apply(amps) end
  if kind == "salia" then return salia_apply(amps) end
  host.log("warn", "Hardy Barth: controller not known yet; no write")
  return false
end

function driver_command(action, power_w, cmd)
  if action == "init" or action == "deinit" then return true end
  if not base_url then return false end

  local ok
  if action == "ev_set_current" then
    local amps = amps_for(power_w, cmd)
    ok = apply(amps)
    if ok and amps > 0 then last_order_a = amps end
  elseif action == "ev_pause" then
    ok = apply(0)
  elseif action == "ev_resume" or action == "ev_start" then
    local amps = last_order_a or device_min_a()
    if amps > device_max_a() then amps = device_max_a() end
    amps = math.floor(amps)
    ok = apply(amps)
  else
    host.log("warn", "Hardy Barth: unknown action " .. tostring(action))
    return false
  end
  if ok then
    ftw_wrote = true
    stood_down = false
    default_failures = 0
  end
  return ok
end

-- Stand down when FTW can no longer steer: stop the station once. After
-- DEFAULT_ATTEMPTS refusals in a row it stops trying and reports the default
-- as held, so a station that will not take the write is not written every tick.
function driver_default_mode()
  if not base_url or not ftw_wrote or stood_down then return true end
  if default_failures >= DEFAULT_ATTEMPTS then return true end
  if not kind then detect(host.millis()) end
  if kind and apply(0) then
    stood_down = true
    default_failures = 0
    return true
  end
  default_failures = default_failures + 1
  return false
end

function driver_cleanup()
  base_url = nil
end
