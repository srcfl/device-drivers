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
-- the installation has one, or Core asks for one and the charger is drawing
-- on exactly one. A single-phase car can then only draw less than Core
-- budgeted, never more. With no cap in an order it keeps Core's last one.
--
-- Stand-alone mode (observation 712) makes the charger ignore current set
-- through the API. The driver then refuses current orders and says why.
--
-- When FTW can no longer steer (driver_default_mode) it pauses and sets
-- 0 A, as easee_cloud does, but only once FTW has written a current in this
-- run. maxChargeCurrent is stored on the charger, so an owner who stops
-- using FTW sets it again in the Zaptec app or portal.
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
  version      = "0.2.2",
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

-- Operating modes (observation 710).
local OP_DISCONNECTED = 1
local OP_CONNECTED    = 2
local OP_CHARGING     = 3
local OP_FINISHED     = 5

-- Commands (POST .../sendCommand/{id}).
local CMD_PAUSE  = 506
local CMD_RESUME = 507
-- Zaptec's ErrorCode 528 (DeviceCommandRejected) is what a charger answers
-- when the command would not change its state, for example a resume on a
-- charger that is not paused. 520 (ErrorCommunicatingWithDevice) means the
-- command never reached the charger, so it is a failure.
local CODE_REJECTED = 528

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
local STAND_DOWN_RETRY_MS = 60000
-- A positive order on a paused charger resends resume no more often than this.
local RESUME_RETRY_MS = 30000

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
local op_mode        = nil
local OBS_FINAL_STOP = 718
local phase_currents = { nil, nil, nil }
local variant_logged = false

-- What the driver last wrote.
local last_written_a  = nil   -- nil until the first write this run
local last_write_ms   = 0
local last_cap_a      = nil   -- Core's last max_amps_per_phase
local paused          = false -- the charger is paused (506 or the poll says so)
local resume_try_ms   = nil
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

-- post sends one request and returns an error string or nil. A 401 signs in
-- again once. A 2xx whose body carries a non-zero Code counts as an error,
-- in the same "HTTP <status>: <body>" shape the host uses for a 4xx.
local function post(path, body, content_type)
  local function once()
    local headers = auth_headers()
    if content_type then headers["Content-Type"] = content_type end
    local resp, err = safe_http_post(BASE_URL .. path, body, headers)
    if err then return err end
    if resp and resp ~= "" then
      local data = decode_json(resp)
      local code = type(data) == "table" and as_number(pick(data, "Code", "code"))
      if code and code ~= 0 then return "HTTP 200: " .. resp end
    end
    return nil
  end
  local err = once()
  if err and tostring(err):match("^HTTP 401") then
    access_token = nil
    token_expiry = 0
    if ensure_auth() then err = once() end
  end
  return err
end

local function post_json(path, tbl)
  return post(path, host.json_encode(tbl), "application/json")
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

-- send_command posts a charger command. It returns whether the result
-- holds, and whether the charger took the command itself rather than
-- answering that there was nothing to do.
local function send_command(cmd_id)
  local err = post("/api/chargers/" .. charger_id .. "/sendCommand/" .. cmd_id, "")
  if err == nil then return true, true end
  local rejected = error_code(err) == CODE_REJECTED
  if cmd_id == CMD_PAUSE then
    -- Rejected means already paused, or no car to pause. Nothing flows.
    if rejected or op_mode == OP_DISCONNECTED then return true, false end
  elseif cmd_id == CMD_RESUME then
    -- Rejected means nothing to resume, which holds unless the driver
    -- itself paused the charger and has not seen it charge since.
    if rejected and not paused then return true, false end
  end
  host.log("warn", "Zaptec: command " .. cmd_id .. " failed: " .. redact_http_err(err))
  return false, false
end

local function live_phase_count()
  local n = 0
  for i = 1, 3 do
    local a = phase_currents[i]
    if a and a >= LIVE_PHASE_A then n = n + 1 end
  end
  return n
end

-- amps_for turns Core's watts into amps per phase, never above Core's cap.
-- It divides by three phases unless the installation has one phase and the
-- charger is not drawing on more, or Core asks for one and the charger is
-- drawing on exactly one. An idle charger
-- proves nothing, so a three-phase car can never get a one-phase sum.
local function amps_for(power_w, cmd, cap)
  local voltage = as_number(cmd.voltage)
  if not voltage or voltage <= 0 then voltage = 230 end
  local mode = type(cmd.phase_mode) == "string" and cmd.phase_mode or ""
  local phases = 3
  local live = live_phase_count()
  if (phases_cfg == 1 and live <= 1) or (mode == "1p" and live == 1) then phases = 1 end
  local amps = (as_number(power_w) or 0) / (voltage * phases)
  if cap and amps > cap then amps = cap end
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

local function send_resume()
  resume_try_ms = host.millis()
  local ok = send_command(CMD_RESUME)
  if ok then paused = false end
  return ok
end

-- set_current writes Core's order. A positive order also resumes a charger
-- that is paused, as easee_cloud does, so a stand-down never strands it.
-- Even a zero order is refused in stand-alone mode: the charger ignores the
-- current there, and saying otherwise would hide that FTW cannot steer it.
local function set_current(power_w, cmd)
  if stand_alone then return refuse_stand_alone() end
  cmd = cmd or {}
  local cap = as_number(cmd.max_amps_per_phase)
  if cap and cap > 0 then last_cap_a = cap else cap = last_cap_a end
  local amps = amps_for(power_w, cmd, cap)
  local now = host.millis()
  local wrote = true
  local write = true
  if last_written_a ~= nil then
    local diff = amps - last_written_a
    local age = now - last_write_ms
    if math.abs(diff) < 0.1 and age < REFRESH_MS then write = false end
    -- A small rise waits; a fall always goes out at once.
    if diff > 0 and diff < SMALL_RISE_A and last_written_a > 0
        and age < SMALL_RISE_HOLD_MS then
      write = false
    end
  end
  if write then wrote = write_current(amps) end
  if amps < MIN_A or not wrote then return wrote end
  if paused and (resume_try_ms == nil or now - resume_try_ms >= RESUME_RETRY_MS) then
    return send_resume()
  end
  return true
end

local function pause()
  local wrote = write_current(0)
  local sent, applied = send_command(CMD_PAUSE)
  if applied then paused = true end
  -- 0 A alone is enough: below 6 A the charger allocates nothing.
  return wrote or sent
end

-- resume starts a paused charger. It offers the minimum current, never more
-- than Core's last cap, and Core's next order sets the level.
local function resume()
  if stand_alone then return refuse_stand_alone() end
  if (last_written_a == nil or last_written_a < MIN_A)
      and (last_cap_a == nil or last_cap_a >= MIN_A) then
    if not write_current(MIN_A) then return false end
  end
  -- Always send the command: the last poll may predate a pause.
  return send_resume()
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
    phase_currents = { nil, nil, nil }
    host.log("warn", "Zaptec: state poll failed: " .. redact_http_err(err))
    return 10000
  end
  local obs, oerr = observation_map(resp)
  if oerr or not obs then
    phase_currents = { nil, nil, nil }
    host.log("warn", "Zaptec: state decode failed")
    return 10000
  end

  log_variant(obs[OBS_CAPABILITIES])
  op_mode = as_number(obs[OBS_OP_MODE])
  if op_mode == OP_CHARGING then
    paused = false
  elseif op_mode == OP_FINISHED and as_flag(obs[OBS_FINAL_STOP]) == true then
    paused = true
  end
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
  -- Stand down when FTW can no longer steer: 0 A and pause. Core runs this at
  -- every start too, and maxChargeCurrent is stored on the charger, so it acts
  -- only after FTW wrote a current in this run; a charger FTW never steered
  -- keeps the owner's own setting.
  --
  -- The return value is what Core believes. true means stood down (or nothing
  -- of FTW's to hand back); false keeps Core's control blocked and its
  -- recovery retrying. A refused stand-down is false, and the write is tried
  -- again no more than once a minute, so it settles without lying.
  if not charger_id or not email or not password then return true end
  if last_written_a == nil then return true end
  if stood_down then return true end
  local now = host.millis()
  if stand_down_try_ms and now - stand_down_try_ms < STAND_DOWN_RETRY_MS then return false end
  stand_down_try_ms = now
  if not ensure_auth() then return false end
  local wrote = write_current(0)
  local _, applied = send_command(CMD_PAUSE)
  if applied then paused = true end
  -- Either holds the car: below 6 A Zaptec allocates nothing, and a paused
  -- charger draws nothing.
  if wrote or applied then
    stood_down = true
    stand_down_try_ms = nil
    return true
  end
  return false
end

function driver_cleanup()
  access_token = nil
  refresh_token = nil
end
