-- Tesla Vehicle Driver (telemetry-only, Tesla Fleet / official cloud API)
-- Emits: Vehicle (DerVehicle)
-- Protocol: HTTPS (Tesla Fleet API)
--
-- Optional cloud SoC next to tesla_vehicle.lua (TeslaBLEProxy / VIN on the
-- LAN). This file does not replace that driver. Cloud access is not a
-- charging prerequisite: an asleep or unreachable car is a supported case,
-- and Core already plans from a stated default or the plug-in slider.
--
-- Telemetry only. No wake_up, charge_start, or other vehicle commands.
-- GET /api/1/vehicles/{vin}/vehicle_data is a live call to the car and a
-- billed request; Tesla says not to poll it regularly. GET
-- /api/1/vehicles/{vin} returns the car's state without a live call and
-- is not billed. So the driver checks the state every 5 minutes and reads
-- charge_state only from a car that is already awake: every 4 minutes
-- while it charges, every 20 minutes otherwise, and not on the first check
-- after it wakes, so it does not stretch the car's own short wakes. A
-- sleeping car is never woken from here. The host polls every minute; a
-- poll between those checks sends nothing and replays the last reading.
--
-- Vendor documents (public):
--   https://developer.tesla.com/docs/fleet-api/endpoints/vehicle-endpoints
--   https://developer.tesla.com/docs/fleet-api/authentication/third-party-tokens
--   https://developer.tesla.com/docs/fleet-api/billing-and-limits
-- They are not in the manifest's upstream_docs: the page HTML changes
-- with every deploy of Tesla's site, and the watcher hashes raw bytes.
--
-- Auth is OAuth refresh_token against fleet-auth. Refresh tokens rotate and
-- are persisted via host.persist_secret. Scopes needed: openid, offline_access,
-- vehicle_device_data. Do not grant vehicle_cmds / vehicle_charging_cmds for
-- this driver; it never posts a command.
--
-- Config:
--   drivers:
--     - name: tesla-cloud
--       lua: drivers/tesla_cloud.lua
--       capabilities:
--         http:
--           allowed_hosts:
--             - fleet-auth.prd.vn.cloud.tesla.com
--             - fleet-api.prd.eu.vn.cloud.tesla.com
--             - fleet-api.prd.na.vn.cloud.tesla.com
--             - fleet-api.prd.cn.vn.cloud.tesla.com.cn
--       config:
--         client_id: "..."
--         client_secret: "..."      # optional for some Tesla app types
--         refresh_token: "..."      # from the Fleet API auth-code exchange
--         vin: "5YJ3E1EA1KF000000"  # optional; first vehicle if omitted
--         region: eu                # na | eu | cn
--
-- Settings → Devices currently scaffolds {ip, vin} for any "vehicle"
-- capability (the BLE proxy form). Edit the YAML for Fleet OAuth; do not
-- point this driver at TeslaBLEProxy.

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "tesla_cloud",
  name         = "Tesla Vehicle (Fleet API)",
  manufacturer = "Tesla",
  version      = "0.1.0",
  protocols    = { "http" },
  capabilities = { "vehicle" },
  read_only    = true,
  auth_post_path = "/oauth2/v3/token",
  description  = "Read-only Tesla vehicle SoC, charge limit and charging state via the official Fleet API. Optional next to the local BLE-proxy driver. Does not wake or command the car.",
  homepage     = "https://developer.tesla.com/docs/fleet-api",
  http_hosts   = {
    "fleet-auth.prd.vn.cloud.tesla.com",
    "fleet-api.prd.na.vn.cloud.tesla.com",
    "fleet-api.prd.eu.vn.cloud.tesla.com",
    "fleet-api.prd.cn.vn.cloud.tesla.com.cn",
  },
  authors      = { "FTW contributors" },
  tested_models = { "Model Y", "Model 3" },
  verification_status = "experimental",
  config_secrets = { "client_secret", "refresh_token" },
}

PROTOCOL = "http"

-- Fixed: the POST that carries the refresh token and client secret only
-- ever goes to Tesla's auth host.
local AUTH_URL = "https://fleet-auth.prd.vn.cloud.tesla.com/oauth2/v3/token"
local REGION_URL = {
  na = "https://fleet-api.prd.na.vn.cloud.tesla.com",
  eu = "https://fleet-api.prd.eu.vn.cloud.tesla.com",
  cn = "https://fleet-api.prd.cn.vn.cloud.tesla.com.cn",
}

-- Tesla VINs carry the model line in the fourth character.
local VIN_MODEL = {
  S = "Model S",
  ["3"] = "Model 3",
  X = "Model X",
  Y = "Model Y",
  C = "Cybertruck",
}

-- The host ignores driver_poll's return value and keeps the interval last
-- set with host.set_poll_interval, so every poll sets it. Requests to Tesla
-- are paced separately by next_request_ms.
local POLL_MS           = 60000
local CHARGING_EVERY_MS = 240000   -- charging: the car is awake anyway
local IDLE_EVERY_MS     = 1200000  -- awake, not charging: let it fall asleep
local ASLEEP_EVERY_MS   = 300000   -- state check only: free, wakes nothing
local ERROR_RETRY_MS    = 300000
local BACKOFF_MS        = 900000   -- failed token refresh or HTTP 429
-- Longer than IDLE_EVERY_MS, so an awake idle car stays listed between
-- reads. Core itself stops using a vehicle SoC 5 minutes after it was read.
local STALE_AFTER_MS    = 1500000
local WATCHDOG_TIMEOUT_S = 300

local client_id     = nil
local client_secret = nil
local refresh_token = nil
local access_token  = nil
local token_expires_at = 0
local vin           = nil
local base_url      = REGION_URL.eu
local next_request_ms = 0
-- Whether the car was online at the previous state check (nil: not
-- checked yet since start).
local was_online    = nil

-- Last vendor observation. seen_ms is host.millis() of the last successful
-- charge_state read. Age is measured on that clock; Tesla's unix ms cannot
-- be compared to host.millis().
local last = {
  seen_ms                = 0,
  soc                    = nil,
  charge_limit           = nil,
  charging_state         = nil,
  time_to_full           = nil,
  charge_amps            = nil,
  charger_actual_current = nil,
}

local function redact_http_err(err)
  if err == nil then return "ok" end
  return tostring(err):match("^(HTTP %d+)") or "request failed"
end

local function url_encode(s)
  return (tostring(s or ""):gsub("[^%w%-%.%_%~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
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

local function auth_headers()
  return {
    Authorization = "Bearer " .. (access_token or ""),
    Accept = "application/json",
  }
end

local function unwrap(decoded)
  if type(decoded) ~= "table" then return nil end
  if type(decoded.response) == "table" then
    if type(decoded.response.response) == "table" then
      return decoded.response.response
    end
    return decoded.response
  end
  return decoded
end

local function as_list(t)
  if type(t) ~= "table" then return {} end
  if t[1] ~= nil then return t end
  if type(t.vehicles) == "table" then return t.vehicles end
  return {}
end

local function persist_refresh(new_token)
  if not new_token or new_token == "" or new_token == refresh_token then
    return
  end
  refresh_token = new_token
  if not host.persist_secret then return end
  local ok, perr = host.persist_secret("refresh_token", refresh_token)
  if not ok then
    host.log("warn", "tesla_cloud: could not persist rotated refresh_token: " .. tostring(perr))
  end
end

local function fetch_token()
  if not refresh_token or refresh_token == "" then
    host.log("warn", "tesla_cloud: not connected — set refresh_token from a Tesla Fleet API auth-code exchange")
    return false
  end
  if not client_id or client_id == "" then
    host.log("error", "tesla_cloud: client_id required")
    return false
  end
  local body = "grant_type=refresh_token"
    .. "&client_id=" .. url_encode(client_id)
    .. "&refresh_token=" .. url_encode(refresh_token)
  if client_secret and client_secret ~= "" then
    body = body .. "&client_secret=" .. url_encode(client_secret)
  end
  local resp, err = safe_http_post(AUTH_URL, body, {
    ["Content-Type"] = "application/x-www-form-urlencoded",
    Accept = "application/json",
  })
  if err then
    host.log("error", "tesla_cloud: token refresh failed: " .. redact_http_err(err))
    return false
  end
  local data, derr = decode_json(resp)
  if derr or type(data) ~= "table" or not data.access_token then
    host.log("error", "tesla_cloud: no access_token in refresh response")
    return false
  end
  access_token = data.access_token
  local expires_in = tonumber(data.expires_in) or 28800
  token_expires_at = host.millis() + (expires_in * 1000) - 60000
  persist_refresh(data.refresh_token)
  return true
end

local function ensure_auth()
  if access_token and access_token ~= "" and host.millis() < token_expires_at then
    return true
  end
  return fetch_token()
end

-- The model comes from the VIN, not display_name: that is the name the
-- owner gave the car.
local function bind_identity(next_vin)
  if not next_vin or next_vin == "" then return end
  local s = tostring(next_vin)
  if s == vin then return end
  vin = s
  host.set_sn(vin)
  local model = VIN_MODEL[vin:sub(4, 4):upper()]
  if model and host.set_model then
    host.set_model(model)
  end
end

local function pick_vehicle(rows, want)
  if type(rows) ~= "table" then return nil end
  if want and want ~= "" then
    for i = 1, #rows do
      local row = rows[i]
      if type(row) == "table" and tostring(row.vin or "") == want then
        return row
      end
    end
    return nil
  end
  for i = 1, #rows do
    if type(rows[i]) == "table" and rows[i].vin then
      return rows[i]
    end
  end
  return nil
end

local function list_vehicles()
  local resp, err = safe_http_get(base_url .. "/api/1/vehicles", auth_headers())
  if err then return nil, err end
  local data, derr = decode_json(resp)
  if derr then return nil, derr end
  return as_list(unwrap(data)), nil
end

local function vehicle_row()
  if vin and vin ~= "" then
    local resp, err = safe_http_get(base_url .. "/api/1/vehicles/" .. vin, auth_headers())
    if not err then
      local data, derr = decode_json(resp)
      if not derr then
        local row = unwrap(data)
        if type(row) == "table" and (row.vin or row.state) then
          return row, nil
        end
      end
    end
    if err and tostring(err):match("HTTP 401") then
      return nil, err
    end
  end
  local rows, lerr = list_vehicles()
  if lerr then return nil, lerr end
  local row = pick_vehicle(rows, vin)
  if not row then
    return nil, "no matching vehicle"
  end
  return row, nil
end

local function charge_state_from(decoded)
  local root = unwrap(decoded)
  if type(root) ~= "table" then return nil end
  if type(root.charge_state) == "table" then
    return root.charge_state
  end
  if root.battery_level ~= nil then
    return root
  end
  return nil
end

local function remember(cs)
  local soc = tonumber(cs.battery_level)
  if soc == nil then return false end
  last.soc                    = soc
  last.charge_limit           = tonumber(cs.charge_limit_soc)
  last.charge_amps            = tonumber(cs.charge_amps)
  last.charger_actual_current = tonumber(cs.charger_actual_current)
  local cs_state = cs.charging_state
  if type(cs_state) ~= "string" then cs_state = nil end
  last.charging_state = cs_state
  local ttf_min = tonumber(cs.minutes_to_full_charge)
  if ttf_min == nil then
    local ttf_h = tonumber(cs.time_to_full_charge)
    if ttf_h ~= nil then ttf_min = math.floor(ttf_h * 60 + 0.5) end
  end
  last.time_to_full = ttf_min
  -- Successful vehicle_data is a new observation. Age is for failed or
  -- asleep polls that would otherwise replay this cache forever.
  last.seen_ms = host.millis()
  return true
end

-- A replay repeats the last observation with soc_fresh=false, so Core keeps
-- the time of that observation and ages it itself. Marking a replay stale
-- would drop the car from Core between two reads. After STALE_AFTER_MS the
-- driver stops emitting.
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
    stale                  = false,
    soc_fresh              = fresh,
  })
end

local function fetch_charge_state()
  local url = base_url .. "/api/1/vehicles/" .. vin
    .. "/vehicle_data?endpoints=charge_state"
  local resp, err = safe_http_get(url, auth_headers())
  if err then return nil, err end
  local decoded, derr = decode_json(resp)
  if derr then return nil, derr end
  if type(decoded) == "table" and decoded.error then
    return nil, tostring(decoded.error)
  end
  return charge_state_from(decoded), nil
end

local function wait(ms)
  next_request_ms = host.millis() + ms
end

local function is_charging(state)
  return state == "Charging" or state == "Starting"
end

function driver_init(config)
  host.set_make("Tesla")
  config = config or {}
  client_id     = config.client_id
  client_secret = config.client_secret
  refresh_token = config.refresh_token
  if config.vin and tostring(config.vin) ~= "" then
    bind_identity(config.vin)
  end
  local region = tostring(config.region or "eu"):lower()
  base_url = REGION_URL[region]
  if not base_url then
    host.log("warn", "tesla_cloud: unknown region " .. region .. ", using eu")
    region = "eu"
    base_url = REGION_URL.eu
  end
  next_request_ms = 0
  if host.set_watchdog_timeout_s then
    host.set_watchdog_timeout_s(WATCHDOG_TIMEOUT_S)
  end
  -- First poll soon; driver_poll sets POLL_MS on every path after that.
  host.set_poll_interval(500)
  if not client_id or client_id == "" or not refresh_token or refresh_token == "" then
    host.log("error", "tesla_cloud: client_id and refresh_token required (Fleet API auth-code exchange)")
  end
  host.log("info", "tesla_cloud: init region=" .. region ..
                   " vin=" .. tostring(vin or "(discover)") ..
                   " telemetry-only")
end

function driver_poll()
  host.set_poll_interval(POLL_MS)
  if not refresh_token or refresh_token == "" then
    return POLL_MS
  end
  if host.millis() < next_request_ms then
    emit_vehicle(false)
    return POLL_MS
  end

  if not ensure_auth() then
    wait(BACKOFF_MS)
    emit_vehicle(false)
    return POLL_MS
  end

  local row, err = vehicle_row()
  if err and tostring(err):match("HTTP 401") then
    token_expires_at = 0
    if ensure_auth() then
      row, err = vehicle_row()
    end
  end
  if err or type(row) ~= "table" then
    host.log("warn", "tesla_cloud: vehicle status: " .. redact_http_err(err))
    wait(ERROR_RETRY_MS)
    emit_vehicle(false)
    return POLL_MS
  end

  bind_identity(row.vin)
  if not vin or vin == "" then
    host.log("warn", "tesla_cloud: no VIN on account")
    wait(ERROR_RETRY_MS)
    return POLL_MS
  end

  local state = tostring(row.state or ""):lower()
  local online = state == "online"
  local woke_just_now = online and was_online == false
  was_online = online
  if not online then
    host.log("debug", "tesla_cloud: " .. vin .. " is " .. (state ~= "" and state or "unknown") ..
                      " — not calling vehicle_data")
    wait(ASLEEP_EVERY_MS)
    emit_vehicle(false)
    return POLL_MS
  end
  if woke_just_now then
    -- The car wakes briefly on its own. A live call now would keep it
    -- awake; if it is still online at the next check, it is in use.
    host.log("debug", "tesla_cloud: " .. vin .. " just woke — reading at the next check")
    wait(ASLEEP_EVERY_MS)
    emit_vehicle(false)
    return POLL_MS
  end

  local cs, ferr = fetch_charge_state()
  if ferr and tostring(ferr):match("HTTP 401") then
    token_expires_at = 0
    if ensure_auth() then
      cs, ferr = fetch_charge_state()
    end
  end
  if ferr then
    local es = tostring(ferr)
    if es:match("HTTP 408") or es:match("vehicle unavailable") then
      host.log("debug", "tesla_cloud: vehicle_data unavailable (asleep)")
      wait(ASLEEP_EVERY_MS)
    elseif es:match("HTTP 429") then
      host.log("warn", "tesla_cloud: rate limited")
      wait(BACKOFF_MS)
    else
      host.log("warn", "tesla_cloud: vehicle_data: " .. redact_http_err(ferr))
      wait(ERROR_RETRY_MS)
    end
    emit_vehicle(false)
    return POLL_MS
  end
  if type(cs) ~= "table" or not remember(cs) then
    host.log("debug", "tesla_cloud: no battery_level in charge_state")
    wait(IDLE_EVERY_MS)
    emit_vehicle(false)
    return POLL_MS
  end

  if is_charging(last.charging_state) then
    wait(CHARGING_EVERY_MS)
  else
    wait(IDLE_EVERY_MS)
  end
  host.log("info", "tesla_cloud: emit soc=" .. tostring(last.soc) ..
                   " limit=" .. tostring(last.charge_limit) ..
                   " state=" .. tostring(last.charging_state))
  emit_vehicle(true)
  return POLL_MS
end

function driver_cleanup()
  last.seen_ms                = 0
  last.soc                    = nil
  last.charge_limit           = nil
  last.charging_state         = nil
  last.time_to_full           = nil
  last.charge_amps            = nil
  last.charger_actual_current = nil
  access_token                = nil
  token_expires_at            = 0
  next_request_ms             = 0
  was_online                  = nil
  vin                         = nil
end
