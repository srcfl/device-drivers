-- Zaptec Cloud EV charger driver (Go / Go 2 / Pro).
--
-- Protocol: HTTPS against the Zaptec Cloud API, documented at
-- https://api.zaptec.com/help/index.html (swagger: /swagger/v1/swagger.json).
--
-- Auth:      POST /oauth/token                         (OAuth2 password grant)
-- Telemetry: GET  /api/chargers/{id}/state             (observation list)
-- Current:   POST /api/chargers/{id}/update            {"maxChargeCurrent": A}
-- Pause:     POST /api/chargers/{id}/sendCommand/506   (stop or pause)
-- Resume:    POST /api/chargers/{id}/sendCommand/507
--
-- Why the charger's maxChargeCurrent and not the installation's
-- AvailableCurrent: Zaptec asks callers not to change AvailableCurrent more
-- than once every 15 minutes, and FTW's fuse guard must lower a charger within
-- seconds. Zaptec documents maxChargeCurrent as the setting for "an external
-- party [that] must override the Zaptec load balancer". With FTW, FTW is that
-- party. The installation's own circuit-breaker limit still applies on top.
--
-- The driver does not switch phases. A Go uses the phases its installation
-- gives it. When it computes amps from watts it assumes three phases unless
-- Core asked for one phase and the charger measures at most one, so a
-- single-phase car can only ever draw less than Core budgeted, never more.
--
-- Stand-alone mode (observation 712) makes the charger ignore current set
-- through the API. The driver then refuses current orders and says why.
--
-- When FTW can no longer steer (driver_default_mode) it pauses and sets
-- 0 A, as easee_cloud does. maxChargeCurrent is stored on the charger, so an
-- owner who stops using FTW sets it again in the Zaptec app or portal.
--
-- Sign convention: positive W is charging (power into the vehicle).
--
-- Config:
--   email / username  Zaptec account email
--   password          Zaptec account password (secret)
--   serial            optional charger Id (UUID) or SerialNo
--   phases            optional 1 or 3, the installation's phase count
--   base_url          optional origin override (tests / staging)

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "zaptec_cloud",
  name         = "Zaptec Cloud",
  manufacturer = "Zaptec",
  version      = "0.2.0",
  protocols    = { "http" },
  capabilities = { "ev" },
  description  = "Zaptec Go / Go 2 / Pro via Zaptec Cloud. Email + password; optional charger serial. FTW sets the charging current and pauses or resumes.",
  homepage     = "https://zaptec.com",
  http_hosts   = { "api.zaptec.com" },
  authors      = { "FTW contributors" },
  tested_models = { "Go", "Go 2", "Pro" },
  verification_status = "experimental",
  config_secrets = { "password" },
}

PROTOCOL = "http"

local BASE_URL = "https://api.zaptec.com"
local USER_AGENT = "FTW-zaptec_cloud/" .. DRIVER.version

-- Observation ids from Zaptec's state document (GET /api/constants).
local OBS_CAPABILITIES   = 100
local OBS_VOLTAGE_L1     = 501
local OBS_VOLTAGE_L2     = 502
local OBS_VOLTAGE_L3     = 503
local OBS_CURRENT_L1     = 507
local OBS_CURRENT_L2     = 508
local OBS_CURRENT_L3     = 509
local OBS_MAX_CURRENT    = 510
local OBS_CHARGE_POWER   = 513
local OBS_SESSION_ENERGY = 553
local OBS_OP_MODE        = 710
local OBS_STAND_ALONE    = 712
local OBS_FINAL_STOP     = 718

-- Operating modes (observation 710).
local OP_DISCONNECTED = 1
local OP_CONNECTED    = 2
local OP_CHARGING     = 3
local OP_FINISHED     = 5

-- Commands (POST .../sendCommand/{id}).
local CMD_PAUSE  = 506
local CMD_RESUME = 507
-- Command results that mean "already in that state": 520 on a Pro, 528 on a
-- Go 2 ("Charging is not Paused nor Scheduled; Resume command cannot be sent").
local NO_CHANGE_CODES = { [520] = true, [528] = true }

-- Charger limits. Below MIN_A a charger allocates no current, so the driver
-- writes 0 rather than rounding a small order up.
local MIN_A = 6
local MAX_A = 32
-- A live phase counts when it carries at least this much current.
local LIVE_PHASE_A = 1.0
-- Rewrite an unchanged current at most this often; small rises wait for it.
local REFRESH_MS = 300000
local SMALL_RISE_A = 0.5
local SMALL_RISE_HOLD_MS = 60000
-- After a failed stand-down, try again no sooner than this.
local STAND_DOWN_RETRY_MS = 300000

local email         = nil
local password      = nil
local serial_want   = nil
local charger_id    = nil
local phases_cfg    = 3
local access_token  = nil
local refresh_token = nil
local token_expiry  = 0

-- What the last poll saw. nil means not known.
local stand_alone    = false
local final_stop     = nil
local op_mode        = nil
local phase_currents = { nil, nil, nil }
local variant_logged = false

-- What the driver last wrote.
local last_written_a  = nil   -- nil until the first write this run
local last_write_ms   = 0
local resume_a        = nil   -- last current a positive order asked for
local stood_down      = false
local stand_down_try_ms = nil
local warned_stand_alone = false

local function pick(t, ...)
  if type(t) ~= "table" then return nil end
  for i = 1, select("#", ...) do
    local v = t[select(i, ...)]
    if v ~= nil then return v end
  end
  return nil
end

local function as_number(v)
  if type(v) == "number" then return v end
  if v == nil then return nil end
  return tonumber(v)
end

-- Keep HTTP error strings to a status prefix so a 4xx body that echoes
-- credentials or a bearer token never lands in the driver log.
local function redact_http_err(err)
  if err == nil then return "request failed" end
  local s = tostring(err)
  return s:match("^(HTTP %d+)") or "request failed"
end

local function url_encode(s)
  s = tostring(s or "")
  return (s:gsub("[^%w%-%.%_%~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local function auth_headers()
  return {
    Authorization  = "Bearer " .. (access_token or ""),
    ["User-Agent"] = USER_AGENT,
  }
end

local function decode_json(raw)
  if raw == nil or raw == "" then return nil, "empty body" end
  local ok, data = pcall(host.json_decode, raw)
  if not ok then return nil, tostring(data) end
  if data == nil then return nil, "decode failed" end
  return data, nil
end

local function safe_http_get(url, headers)
  local ok, resp, err = pcall(host.http_get, url, headers)
  if not ok then return nil, tostring(resp) end
  return resp, err
end

local function safe_http_post(url, body, headers)
  local ok, resp, err = pcall(host.http_post, url, body, headers)
  if not ok then return nil, tostring(resp) end
  return resp, err
end

local function token_post(body)
  local resp, err = safe_http_post(
    BASE_URL .. "/oauth/token",
    body,
    { ["Content-Type"] = "application/x-www-form-urlencoded",
      ["User-Agent"] = USER_AGENT })
  if err then return nil, err end
  local data, derr = decode_json(resp)
  if derr or not data then return nil, derr or "invalid JSON" end
  local token = pick(data, "access_token", "accessToken")
  if not token or token == "" then return nil, "no access_token" end
  return data, nil
end

local function take_token(data)
  access_token = pick(data, "access_token", "accessToken")
  local rotated = pick(data, "refresh_token", "refreshToken")
  if rotated and rotated ~= "" then refresh_token = rotated end
  local expires_in = as_number(pick(data, "expires_in", "expiresIn")) or 3600
  token_expiry = host.millis() + (expires_in * 1000) - 60000
end

local function login()
  local data, err = token_post("grant_type=password"
    .. "&username=" .. url_encode(email)
    .. "&password=" .. url_encode(password))
  if not data then return false, err end
  take_token(data)
  host.log("info", "Zaptec: logged in")
  return true
end

local function refresh()
  if not refresh_token or refresh_token == "" then return false end
  local data, err = token_post("grant_type=refresh_token"
    .. "&refresh_token=" .. url_encode(refresh_token))
  if not data then
    host.log("warn", "Zaptec token refresh failed: " .. redact_http_err(err))
    return false
  end
  take_token(data)
  return true
end

local function ensure_auth()
  if access_token and host.millis() < token_expiry then return true end
  if refresh() then return true end
  return (login())
end

local function charger_rows(data)
  if type(data) ~= "table" then return nil end
  local rows = pick(data, "Data", "data")
  if type(rows) == "table" then return rows end
  if data[1] ~= nil then return data end
  return nil
end

local function charger_matches(ch, want)
  if not want or want == "" then return true end
  local id = tostring(pick(ch, "Id", "id") or "")
  local serial = tostring(pick(ch, "SerialNo", "serialNo", "Serial") or "")
  local device = tostring(pick(ch, "DeviceId", "deviceId") or "")
  return id == want or serial == want or device == want
end

local function resolve_charger()
  local resp, err = safe_http_get(BASE_URL .. "/api/chargers", auth_headers())
  if err then return nil, err end
  local data, derr = decode_json(resp)
  if derr then return nil, derr end
  local rows = charger_rows(data)
  if not rows or #rows == 0 then
    return nil, "no chargers on account"
  end
  if serial_want and serial_want ~= "" then
    for i = 1, #rows do
      if charger_matches(rows[i], serial_want) then
        return tostring(pick(rows[i], "Id", "id")), nil
      end
    end
    return nil, "charger not found"
  end
  return tostring(pick(rows[1], "Id", "id")), nil
end

local function observation_map(raw)
  local data, err = decode_json(raw)
  if err then return nil, err end
  local rows = data
  if type(data) == "table" and data[1] == nil then
    rows = pick(data, "Data", "data") or data
  end
  local obs = {}
  if type(rows) ~= "table" then return obs, nil end
  for i = 1, #rows do
    local item = rows[i]
    local id = as_number(pick(item, "StateId", "stateId", "ObservationId", "observationId"))
    if id then
      obs[id] = pick(item, "ValueAsString", "valueAsString", "Value", "value")
    end
  end
  return obs, nil
end

local function as_flag(v)
  if v == nil then return nil end
  local s = string.lower(tostring(v))
  if s == "1" or s == "true" then return true end
  if s == "0" or s == "false" then return false end
  return nil
end

-- The Zaptec error body carries a numeric Code, for example 528 when a
-- resume would not change anything. host.http_post reports a 4xx/5xx as
-- "HTTP <status>: <body>".
local function error_code(err)
  if err == nil then return nil end
  local body = tostring(err):match("^HTTP %d+: (.*)$")
  if not body then return nil end
  local data = decode_json(body)
  if type(data) ~= "table" then return nil end
  return as_number(pick(data, "Code", "code"))
end

local function post_json(path, tbl)
  local body = host.json_encode(tbl)
  local headers = auth_headers()
  headers["Content-Type"] = "application/json"
  local _, err = safe_http_post(BASE_URL .. path, body, headers)
  return err
end

-- write_current sets maxChargeCurrent. Returns true when Zaptec accepted it.
local function write_current(amps)
  local err = post_json("/api/chargers/" .. charger_id .. "/update",
    { maxChargeCurrent = amps })
  if err then
    host.log("warn", "Zaptec: current write failed: " .. redact_http_err(err))
    return false
  end
  last_written_a = amps
  last_write_ms = host.millis()
  return true
end

-- send_command posts a charger command. A result that means "already in
-- that state" counts as done.
local function send_command(cmd_id)
  local headers = auth_headers()
  local _, err = safe_http_post(
    BASE_URL .. "/api/chargers/" .. charger_id .. "/sendCommand/" .. cmd_id,
    "", headers)
  if err == nil then return true end
  local code = error_code(err)
  if code and NO_CHANGE_CODES[code] then return true end
  -- Zaptec rejects a pause on a charger with no car plugged in. Nothing
  -- can flow then, so the pause holds.
  if cmd_id == CMD_PAUSE and op_mode == OP_DISCONNECTED then return true end
  host.log("warn", "Zaptec: command " .. cmd_id .. " failed: " .. redact_http_err(err))
  return false
end

local function live_phase_count()
  local n = 0
  for i = 1, 3 do
    local a = phase_currents[i]
    if a and a >= LIVE_PHASE_A then n = n + 1 end
  end
  return n
end

-- amps_for turns Core's watts into amps per phase. It uses three phases
-- unless both Core and the charger say one, so the amps never exceed what
-- Core budgeted per phase.
local function amps_for(power_w, cmd)
  cmd = cmd or {}
  local voltage = as_number(cmd.voltage)
  if not voltage or voltage <= 0 then voltage = 230 end
  local mode = type(cmd.phase_mode) == "string" and cmd.phase_mode or ""
  local one_phase = (mode == "1p") or (mode ~= "3p" and phases_cfg == 1)
  local phases = 3
  if one_phase and live_phase_count() <= 1 then phases = 1 end
  local amps = (as_number(power_w) or 0) / (voltage * phases)
  local cap = as_number(cmd.max_amps_per_phase)
  if cap and cap > 0 and amps > cap then amps = cap end
  if amps > MAX_A then amps = MAX_A end
  if amps < MIN_A then return 0 end
  return math.floor(amps * 10 + 1e-9) / 10
end

-- refuse_stand_alone logs once and refuses. In stand-alone mode the charger
-- ignores FTW's current, so starting it would charge without the fuse guard.
local function refuse_stand_alone()
  if not warned_stand_alone then
    host.log("error", "Zaptec: the charger is in stand-alone mode and ignores " ..
      "current set by FTW. Turn stand-alone mode off in the Zaptec app.")
    warned_stand_alone = true
  end
  return false
end

local function set_current(power_w, cmd)
  if stand_alone then return refuse_stand_alone() end
  local amps = amps_for(power_w, cmd)
  if amps > 0 then resume_a = amps end
  local now = host.millis()
  if last_written_a ~= nil then
    local diff = amps - last_written_a
    local age = now - last_write_ms
    if math.abs(diff) < 0.1 and age < REFRESH_MS then return true end
    -- A small rise waits; a fall always goes out at once.
    if diff > 0 and diff < SMALL_RISE_A and last_written_a > 0
        and age < SMALL_RISE_HOLD_MS then
      return true
    end
  end
  return write_current(amps)
end

local function pause()
  local wrote = write_current(0)
  local sent = send_command(CMD_PAUSE)
  return wrote or sent
end

local function resume()
  if stand_alone then return refuse_stand_alone() end
  -- Coming back from 0 A, offer the last asked current, or the minimum.
  -- Core sends its own order right after.
  if last_written_a == nil or last_written_a < MIN_A then
    if not write_current(resume_a or MIN_A) then return false end
  end
  if final_stop == false and op_mode == OP_CHARGING then return true end
  return send_command(CMD_RESUME)
end

function driver_init(config)
  host.set_make("Zaptec")
  config = config or {}
  email = config.email or config.username
  password = config.password
  serial_want = config.serial
  if serial_want == "" then serial_want = nil end
  if email == "" then email = nil end
  if password == "" then password = nil end
  if config.base_url and tostring(config.base_url) ~= "" then
    BASE_URL = tostring(config.base_url):gsub("/$", "")
  end
  local p = as_number(config.phases)
  if p == 1 or p == 3 then phases_cfg = p end

  if not email or not password then
    error("Zaptec: email/username and password required")
  end
  local ok, lerr = login()
  if not ok then
    error("Zaptec: initial login failed: " .. redact_http_err(lerr))
  end
  local id, rerr = resolve_charger()
  if not id then
    error("Zaptec: could not list chargers: " .. redact_http_err(rerr))
  end
  charger_id = id
  host.set_sn(charger_id)
  host.log("info", "Zaptec: driver initialized for " .. charger_id)
end

local function log_variant(raw)
  if variant_logged or raw == nil or raw == "" then return end
  variant_logged = true
  local caps = decode_json(raw)
  if type(caps) ~= "table" then return end
  local variant = pick(caps, "ProductVariant", "productVariant")
  local device = pick(caps, "DeviceType", "deviceType")
  if variant or device then
    host.log("info", "Zaptec: product " .. tostring(variant or device))
  end
end

function driver_poll()
  if not charger_id or not email then
    return 10000
  end
  if not ensure_auth() then
    host.log("warn", "Zaptec: auth failed, skipping poll")
    return 10000
  end
  local resp, err = safe_http_get(
    BASE_URL .. "/api/chargers/" .. charger_id .. "/state",
    auth_headers())
  if err then
    host.log("warn", "Zaptec: state poll failed: " .. redact_http_err(err))
    return 10000
  end
  local obs, oerr = observation_map(resp)
  if oerr or not obs then
    host.log("warn", "Zaptec: state decode failed")
    return 10000
  end

  log_variant(obs[OBS_CAPABILITIES])
  op_mode = as_number(obs[OBS_OP_MODE])
  final_stop = as_flag(obs[OBS_FINAL_STOP])
  local was_stand_alone = stand_alone
  stand_alone = as_flag(obs[OBS_STAND_ALONE]) == true
  if was_stand_alone and not stand_alone then warned_stand_alone = false end
  phase_currents = {
    as_number(obs[OBS_CURRENT_L1]),
    as_number(obs[OBS_CURRENT_L2]),
    as_number(obs[OBS_CURRENT_L3]),
  }

  local power_w = as_number(obs[OBS_CHARGE_POWER])
  if power_w and power_w < 0 then power_w = 0 end
  local session_kwh = as_number(obs[OBS_SESSION_ENERGY])
  local connected = nil
  local charging = nil
  if op_mode then
    connected = (op_mode == OP_CONNECTED or op_mode == OP_CHARGING or op_mode == OP_FINISHED)
    charging = (op_mode == OP_CHARGING)
  end
  local live = live_phase_count()
  local phases = phases_cfg
  if charging and live > 0 then phases = live end

  local reason = nil
  if stand_alone then
    reason = "stand-alone mode: the charger ignores FTW's current"
  end

  host.emit("ev", {
    w          = power_w,
    connected  = connected,
    charging   = charging,
    session_wh = session_kwh and (session_kwh * 1000) or nil,
    max_a      = as_number(obs[OBS_MAX_CURRENT]),
    phases     = phases,
    op_mode    = op_mode,
    l1_a       = phase_currents[1],
    l2_a       = phase_currents[2],
    l3_a       = phase_currents[3],
    l1_v       = as_number(obs[OBS_VOLTAGE_L1]),
    l2_v       = as_number(obs[OBS_VOLTAGE_L2]),
    l3_v       = as_number(obs[OBS_VOLTAGE_L3]),
    reason_no_current_label = reason,
  })

  if power_w then host.emit_metric("ev_power_w", power_w) end
  return 5000
end

function driver_command(action, power_w, cmd)
  if action == "init" or action == "deinit" then
    return true
  end
  if not charger_id or not ensure_auth() then
    return false
  end
  -- Any order means FTW steers again; the next stand-down must run.
  stood_down = false
  stand_down_try_ms = nil
  if action == "ev_set_current" then
    return set_current(power_w, cmd)
  elseif action == "ev_pause" then
    return pause()
  elseif action == "ev_resume" or action == "ev_start" then
    return resume()
  end
  host.log("warn", "Zaptec: unknown action " .. tostring(action))
  return false
end

function driver_default_mode()
  -- Stand down when FTW can no longer steer: 0 A and pause. Settles: once
  -- done it does nothing until a new order, and a failed try waits before
  -- the next one.
  if not charger_id or not email or not password then return end
  if stood_down then return end
  local now = host.millis()
  if stand_down_try_ms and now - stand_down_try_ms < STAND_DOWN_RETRY_MS then return end
  stand_down_try_ms = now
  if not ensure_auth() then return end
  local wrote = write_current(0)
  send_command(CMD_PAUSE)
  if wrote then
    stood_down = true
    stand_down_try_ms = nil
  end
end

function driver_cleanup()
  access_token = nil
  refresh_token = nil
end
