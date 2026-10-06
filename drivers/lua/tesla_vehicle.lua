-- Tesla vehicle telemetry through TeslaBleHttpProxy on the local LAN.
-- Config: ip (proxy address, optionally host:port), vin (paired vehicle).
-- Source timestamp: the proxy converts the BMS timestamp to Unix seconds.
-- Recovery needs Core's unix_ms and reserve_vehicle_wake host functions.
-- Older hosts keep reading but cannot automatically wake or trust source age.
-- https://github.com/wimaha/TeslaBleHttpProxy

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "tesla_vehicle",
  name         = "Tesla Vehicle (BLE Proxy)",
  manufacturer = "Tesla",
  version      = "0.2.5",
  protocols    = { "http" },
  capabilities = { "vehicle" },
  description  = "Vehicle SoC and charge limit via a local Tesla BLE proxy, with bounded telemetry wake and charge-start support.",
  telemetry_wake = true,
  homepage     = "https://github.com/wimaha/TeslaBleHttpProxy",
  authors      = { "FTW contributors" },
  tested_models = { "Model Y", "Model 3" },
  verification_status = "beta",
}

PROTOCOL = "http"

local PROXY_PORT = 8080
local POLL_INTERVAL_MS = 60000
local POLL_INTERVAL_CHARGING_MS = 30000
local SOURCE_MAX_AGE_MS = 300000
local BUSY_BACKOFF_MS = 180000
local READ_AFTER_WAKE_MS = 5000
local base_url, vin
local wake_read_pending = false
local recovery_not_before_ms = 0
local last = { ts_ms = 0 }

local function log(level, message)
  message = tostring(message)
  if type(vin) == "string" and #vin > 4 then
    message = message:gsub(vin:gsub("%p", "%%%0"), "****" .. vin:sub(-4))
  end
  host.log(level, message)
end

local function headers() return { Accept = "application/json" } end
local function get(url)
  local ok, body, err = pcall(host.http_get, url, headers())
  if not ok then return nil, "request failed" end
  return body, err
end
local function post(url)
  local ok, body, err = pcall(host.http_post, url, "{}", headers())
  if not ok then return nil, "request failed" end
  return body, err
end
local function decode(body)
  if type(body) ~= "string" or body == "" then return nil end
  local ok, data = pcall(host.json_decode, body)
  if ok and type(data) == "table" then return data end
end
local function finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end
local function wall_ms()
  if not host.unix_ms then return nil end
  return host.unix_ms()
end
local function source_ms(value)
  value = tonumber(value)
  if not finite(value) or value <= 0 then return nil end
  -- Current BLE proxy uses seconds; Tesla Owner API variants use milliseconds.
  if value < 100000000000 then value = value * 1000.0 end
  return math.floor(value)
end
local function set_interval(ms)
  host.set_poll_interval(ms)
  return ms
end
local function busy(err)
  local es = tostring(err)
  return es:match("HTTP 408") or es:match("HTTP 503") or es:match("Command Disallowed")
end
local function emit_last(fresh)
  if last.soc == nil then return end
  local now = wall_ms()
  local age = now and last.ts_ms > 0 and math.max(0, now - last.ts_ms) or nil
  if age and host.emit_metric then host.emit_metric("vehicle_soc_age_s", age / 1000, "s") end
  host.emit("vehicle", {
    soc = last.soc,
    charge_limit_pct = last.limit,
    charging_state = last.state,
    time_to_full_min = last.ttf,
    charge_amps = last.amps,
    charger_actual_current = last.actual,
    soc_observed_at_ms = last.ts_ms > 0 and last.ts_ms or nil,
    soc_fresh = fresh == true,
    stale = not age or age > SOURCE_MAX_AGE_MS,
  })
end

local function wake_vehicle()
  local now = host.millis()
  if now < recovery_not_before_ms then return false end
  if not host.reserve_vehicle_wake then
    log("warn", "tesla: telemetry wake needs a host with a durable wake budget")
    recovery_not_before_ms = now + 1800000
    return false
  end
  local allowed, retry_ms, err = host.reserve_vehicle_wake()
  if not allowed then
    recovery_not_before_ms = now + math.max(1000, tonumber(retry_ms) or 1800000)
    if err then log("warn", "tesla: telemetry wake budget unavailable") end
    return false
  end
  -- Save-before-send happens in the host. Even a failed request consumes budget.
  recovery_not_before_ms = now + math.max(1000, tonumber(retry_ms) or 90000)
  -- Dedicated POST cannot be bypassed by vehicle_data's cache-hit path.
  local body, request_err = post(base_url .. "/api/1/vehicles/" .. vin .. "/command/wake_up")
  if request_err then
    if busy(request_err) then recovery_not_before_ms = now + BUSY_BACKOFF_MS end
    log("warn", "tesla: telemetry wake request failed")
    return false
  end
  local reply = decode(body)
  local accepted = false
  local result = reply
  for _ = 1, 3 do
    if type(result) ~= "table" then break end
    if result.result == false then accepted = false; break end
    if result.result == true then accepted = true end
    result = result.response
  end
  if not accepted then
    log("warn", "tesla: telemetry wake was not accepted")
    return false
  end
  wake_read_pending = true
  set_interval(READ_AFTER_WAKE_MS)
  log("info", "tesla: telemetry wake accepted; waiting for a new BMS observation")
  return true
end

function driver_init(config)
  config = config or {}
  vin = type(config.vin) == "string" and config.vin:match("^%s*(.-)%s*$"):upper() or nil
  local ip = config.ip
  if type(vin) ~= "string" or vin == "" or type(ip) ~= "string" or ip == "" then
    log("error", "tesla: ip and vin required")
    return
  end
  local address, port = ip:match("^(.*):(%d+)$")
  base_url = "http://" .. (address or ip) .. ":" .. (port or tostring(PROXY_PORT))
  host.set_make("Tesla")
  host.set_sn(vin)
  if host.set_watchdog_timeout_s then host.set_watchdog_timeout_s(300) end
  set_interval(500)
end

function driver_poll()
  if not base_url then return set_interval(10000) end
  local steady = last.state == "Charging" and POLL_INTERVAL_CHARGING_MS or POLL_INTERVAL_MS
  wake_read_pending = false
  local body, err = get(base_url .. "/api/1/vehicles/" .. vin .. "/vehicle_data?endpoints=charge_state")
  if err and busy(err) then
    emit_last(false)
    recovery_not_before_ms = math.max(recovery_not_before_ms, host.millis() + BUSY_BACKOFF_MS)
    return set_interval(BUSY_BACKOFF_MS)
  end
  local data = decode(body)
  local cs = data and (data.charge_state or
    (type(data.response) == "table" and (data.response.charge_state or
      (type(data.response.response) == "table" and data.response.response.charge_state))))
  local soc = type(cs) == "table" and tonumber(cs.battery_level) or nil
  local observed = type(cs) == "table" and source_ms(cs.timestamp) or nil
  local now = wall_ms()
  local usable = not err and finite(soc) and soc >= 0 and soc <= 100 and
    observed and now and observed <= now
  if usable then
    local fresh = observed > last.ts_ms
    if fresh then
      local ttf = tonumber(cs.minutes_to_full_charge)
      if not ttf and tonumber(cs.time_to_full_charge) then ttf = tonumber(cs.time_to_full_charge) * 60 end
      last = { ts_ms = observed, soc = soc, limit = tonumber(cs.charge_limit_soc),
        state = type(cs.charging_state) == "string" and cs.charging_state or nil,
        ttf = ttf, amps = tonumber(cs.charge_amps), actual = tonumber(cs.charger_actual_current) }
    end
    emit_last(fresh)
    if now - observed <= SOURCE_MAX_AGE_MS and observed >= last.ts_ms then
      return set_interval(last.state == "Charging" and POLL_INTERVAL_CHARGING_MS or POLL_INTERVAL_MS)
    end
  else
    emit_last(false)
  end
  -- Includes HTTP 200 with empty, partial, invalid or stale data.
  if wake_vehicle() then return set_interval(READ_AFTER_WAKE_MS) end
  return set_interval(steady)
end

function driver_command(action, _, _)
  if action == "wake_up" or action == "ev_wake" then
    if not base_url then return false end
    -- A refresh always requests a read, even when another caller reserved wake.
    local accepted = wake_vehicle()
    set_interval(READ_AFTER_WAKE_MS)
    return accepted or wake_read_pending
  end
  if action == "charge_start" or action == "ev_start" then
    if not base_url or not vin then
      log("warn", "tesla: charge_start before init")
      return false
    end
    local url = base_url .. "/api/1/vehicles/" .. vin .. "/command/charge_start"
    -- Empty JSON object body — TeslaBLEProxy's command endpoints
    -- accept GET-ish POSTs; some Tesla SDKs send `{}` for parity
    -- with the cloud API. Either form works on the proxy.
    local body, err = post(url)
    if err then
      local es = tostring(err)
      -- 503 / "Command Disallowed" means the proxy's BLE radio is
      -- busy or rate-limited. Not an error from our perspective —
      -- the controller's cooldown will retry on the next window.
      if es:match("HTTP 503") or es:match("HTTP 408") then
        log("debug", "tesla: charge_start busy/asleep, will retry: " .. es)
        return false
      end
      log("warn", "tesla: charge_start failed: " .. es)
      return false
    end
    -- Surface the proxy's response body so we can see WHY a
    -- nominally-successful POST didn't wake the car. Common cases:
    -- Tesla returned `not_charging` (already at limit), `is_charging`
    -- (idempotent / no-op), or a vehicle-side rejection (e.g. user
    -- has charge-on-schedule enabled).
    local snippet = (body and #body > 0) and body:sub(1, 200) or "(empty body)"
    log("info", "tesla: charge_start response: " .. snippet)
    return true
  end
  log("debug", "tesla: command ignored: " .. tostring(action))
  return false
end

function driver_default_mode() end
function driver_cleanup()
  base_url, vin = nil, nil
  last = { ts_ms = 0 }
  wake_read_pending = false
  recovery_not_before_ms = 0
end
