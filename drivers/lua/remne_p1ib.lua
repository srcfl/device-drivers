-- remne_p1ib.lua
-- Remne Technologies P1IB (P1 Interface Bridge) smart-meter reader.
-- Emits: Meter (read-only)
-- Protocol: HTTP - the bridge's own `GET /meterData` JSON endpoint.
--
-- The P1IB is a Wi-Fi (optionally Ethernet) bridge that plugs into the
-- meter's RJ12 P1/HAN port and parses its telegrams. It is common in
-- Sweden. Firmware is closed; the endpoint shape below was read off live
-- units (firmware 757b45d, hardware revision F, Landis+Gyr E360 meters
-- in Mode-D) and matches the paths in the published firmware image.
--
-- Why HTTP and not the bridge's MQTT output:
--   P1IB publishes MQTT per sensor and only when a value moves past its
--   "reduced mode" hysteresis. A site whose load holds steady goes quiet
--   on MQTT for hours, and FTW treats a quiet site meter as stale and
--   stops all dispatch. `/meterData` answers every poll and carries a
--   telegram counter, so freshness is measured rather than inferred from
--   value changes.
--
-- Endpoint contract (GET http://<host>/meterData):
--   {
--     "d": { "<OBIS>": [v1, ..., v10], ... },   -- last ~10 telegrams, oldest first
--     "last_ok_interval": 10192,            -- ms between the last two good telegrams
--     "info": { "mac": "A0:B7:...", "meter": "LGF5E360", "mode": "Mode-D",
--               "okCnt": 39564, "failCnt": 3, ... }
--   }
--   The newest reading is the LAST element of each array. okCnt counts
--   telegrams with a good CRC and restarts from 0 when the bridge reboots.
--
-- OBIS codes used (units as the bridge reports them):
--   1-0:1.7.0  / 1-0:2.7.0            total active power import / export (kW)
--   1-0:21.7.0 / 1-0:22.7.0           L1 active power import / export (kW)
--   1-0:41.7.0 / 1-0:42.7.0           L2 active power import / export (kW)
--   1-0:61.7.0 / 1-0:62.7.0           L3 active power import / export (kW)
--   1-0:32.7.0 / 52.7.0 / 72.7.0      L1-L3 voltage (V)
--   1-0:31.7.0 / 51.7.0 / 71.7.0      L1-L3 current (A, unsigned magnitude)
--   1-0:1.8.0  / 1-0:2.8.0            lifetime active energy import / export (kWh)
--   1-0:3.7.0  / 1-0:4.7.0            reactive power import / export (kvar)
--
-- Sign convention (SITE = positive W flows INTO the site):
--   meter.w = (import_kW - export_kW) * 1000; per phase the same way.
--   Currents stay unsigned: the P1 port reports magnitude only.
--
-- Config example (config.yaml):
--   drivers:
--     - name: p1ib
--       lua: drivers/remne_p1ib.lua
--       is_site_meter: true
--       capabilities:
--         http:
--           allowed_hosts: ["192.168.1.112"]
--       config:
--         host: "192.168.1.112"      # required; IP or p1ib.local
--         # poll_ms: 5000            # optional, default 5000

DRIVER = {
  id = "remne_p1ib",
  name = "Remne P1IB",
  manufacturer = "Remne Technologies",
  version = "0.1.0",
  host_api_min = 1,
  host_api_max = 1,
  protocols = { "http" },
  capabilities = { "meter" },
  description = "Smart meter via the Remne P1IB bridge's /meterData JSON endpoint (P1/HAN, DLMS Mode D and HDLC meters).",
  homepage = "https://github.com/remne/p1ib",
  authors = { "FTW contributors" },
  tested_models = {
    "P1IB hardware rev F, firmware 757b45d, on Landis+Gyr E360 (LGF5E360, Mode-D)",
  },
  verification_status = "experimental",
  verification_notes = "Read-only. Endpoint shape taken from two live P1IB units on Landis+Gyr E360 meters in Sweden.",
  read_only = true,
  connection_defaults = {
    -- No host default: the bridge takes its address from the site's DHCP.
    -- Declaring the key is what makes FTW setup pass the entered IP as config.host.
    host = "",
  },
}

PROTOCOL = "http"

----------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------

local base_url = nil
local poll_ms = 5000

-- A telegram counter that has not moved for this long means the bridge
-- is answering but the meter has stopped sending. Swedish meters send
-- every 10 s; three missed telegrams is well outside normal jitter.
local STALE_TELEGRAMS = 3
local MIN_STALE_MS = 30000

local last_ok_cnt = nil
local last_new_telegram_ms = nil
local stale_logged = false

local identity_set = false

local consecutive_failures = 0
local BACKOFF_MAX_MS = 60000
local function backoff_ms()
  if consecutive_failures <= 0 then return poll_ms end
  local interval = poll_ms * (2 ^ math.min(consecutive_failures, 8))
  if interval > BACKOFF_MAX_MS then return BACKOFF_MAX_MS end
  return interval
end

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

-- Newest reading for an OBIS code, or nil when the meter does not send it.
-- A bridge that has just booted serves empty arrays until telegrams arrive.
local function latest(d, obis)
  local series = d[obis]
  if type(series) ~= "table" or #series == 0 then return nil end
  return tonumber(series[#series])
end

local function net_w(d, import_obis, export_obis)
  local imp = latest(d, import_obis)
  local exp = latest(d, export_obis)
  if imp == nil or exp == nil then return nil end
  return (imp - exp) * 1000.0
end

local function stale_after_ms(interval_ms)
  local n = tonumber(interval_ms)
  if n == nil or n <= 0 then return MIN_STALE_MS end
  local ms = n * STALE_TELEGRAMS
  if ms < MIN_STALE_MS then return MIN_STALE_MS end
  return ms
end

-- The bridge's MAC is its stable identity. The meter's own serial is not
-- in the P1IB payload; the meter model string is, and goes to set_model.
local function report_identity(info)
  if identity_set or type(info) ~= "table" then return end
  local mac = info.mac
  if type(mac) ~= "string" or mac == "" then return end
  host.set_sn("p1ib-" .. string.lower((string.gsub(mac, ":", ""))))
  if type(info.meter) == "string" and info.meter ~= "" then
    host.set_model(info.meter)
  end
  identity_set = true
end

----------------------------------------------------------------------------
-- Driver interface
----------------------------------------------------------------------------

function driver_init(config)
  if not config or type(config.host) ~= "string" or config.host == "" then
    host.log("error", "remne_p1ib: config.host is required (e.g. \"192.168.1.112\" or \"p1ib.local\")")
    return
  end
  if string.sub(config.host, 1, 7) == "http://" then
    base_url = config.host
  else
    base_url = "http://" .. config.host
  end
  local configured_poll_ms = tonumber(config.poll_ms)
  if configured_poll_ms and configured_poll_ms >= 1000 then
    poll_ms = configured_poll_ms
  end

  host.set_make("Remne Technologies")
  host.set_poll_interval(poll_ms)
  host.log("info", "remne_p1ib: initialized (host=" .. config.host .. ", poll=" .. poll_ms .. "ms)")
end

function driver_poll()
  if not base_url then
    return poll_ms
  end

  local ok_http, body, err = pcall(host.http_get, base_url .. "/meterData")
  if not ok_http or not body then
    consecutive_failures = consecutive_failures + 1
    local reason = ok_http and err or body
    host.log("warn", "remne_p1ib: /meterData failed (backoff " .. backoff_ms() .. "ms): " .. tostring(reason))
    return backoff_ms()
  end
  local ok_json, data = pcall(host.json_decode, body)
  if not ok_json or type(data) ~= "table" or type(data.d) ~= "table" then
    consecutive_failures = consecutive_failures + 1
    host.log("warn", "remne_p1ib: /meterData is not the expected JSON: " .. tostring(body):sub(1, 80))
    return backoff_ms()
  end
  if consecutive_failures > 0 then
    host.log("info", "remne_p1ib: poll recovered after " .. consecutive_failures .. " failure(s)")
    consecutive_failures = 0
  end

  local info = data.info
  report_identity(info)

  -- Emit only when a new telegram has arrived since the last emit. The
  -- arrays are a rolling window, so re-emitting them between telegrams
  -- would present the same reading as fresh twice.
  local ok_cnt = type(info) == "table" and tonumber(info.okCnt) or nil
  if ok_cnt == nil then
    host.log("warn", "remne_p1ib: /meterData has no info.okCnt; cannot tell a fresh telegram from a cached one")
    return poll_ms
  end
  local now = host.now_ms()
  if ok_cnt == last_ok_cnt then
    local limit = stale_after_ms(data.last_ok_interval)
    if not stale_logged and last_new_telegram_ms and now - last_new_telegram_ms > limit then
      host.log("warn", "remne_p1ib: no new meter telegram for " .. (now - last_new_telegram_ms) .. "ms; check the P1 cable")
      stale_logged = true
    end
    return poll_ms
  end
  -- A lower count than before means the bridge rebooted; that is new data too.
  last_ok_cnt = ok_cnt
  last_new_telegram_ms = now
  if stale_logged then
    host.log("info", "remne_p1ib: meter telegrams resumed")
    stale_logged = false
  end

  local d = data.d
  local total_w = net_w(d, "1-0:1.7.0", "1-0:2.7.0")
  if total_w == nil then
    -- Without net site power the emit is meaningless for a site meter.
    host.log("warn", "remne_p1ib: telegram has no 1-0:1.7.0/1-0:2.7.0 active power")
    return poll_ms
  end

  -- Optional values are omitted when the meter does not send them.
  -- A synthetic 0 A would disable the per-phase fuse guard, and a
  -- synthetic 0 Wh would look like a lifetime-counter reset.
  local phases = {
    { imp = "1-0:21.7.0", exp = "1-0:22.7.0", v = "1-0:32.7.0", a = "1-0:31.7.0" },
    { imp = "1-0:41.7.0", exp = "1-0:42.7.0", v = "1-0:52.7.0", a = "1-0:51.7.0" },
    { imp = "1-0:61.7.0", exp = "1-0:62.7.0", v = "1-0:72.7.0", a = "1-0:71.7.0" },
  }
  local meter = { w = total_w }
  for i, p in ipairs(phases) do
    local w = net_w(d, p.imp, p.exp)
    local v = latest(d, p.v)
    local a = latest(d, p.a)
    if w ~= nil then meter["l" .. i .. "_w"] = w end
    if v ~= nil then meter["l" .. i .. "_v"] = v end
    if a ~= nil then meter["l" .. i .. "_a"] = a end
  end
  local imp_kwh = latest(d, "1-0:1.8.0")
  local exp_kwh = latest(d, "1-0:2.8.0")
  if imp_kwh ~= nil then meter.import_wh = imp_kwh * 1000.0 end
  if exp_kwh ~= nil then meter.export_wh = exp_kwh * 1000.0 end
  host.emit("meter", meter)

  -- Diagnostics for the long-format history: reactive power is not part
  -- of the Meter struct, and Wi-Fi signal explains most bridge dropouts.
  local q_imp = latest(d, "1-0:3.7.0")
  local q_exp = latest(d, "1-0:4.7.0")
  if q_imp ~= nil then host.emit_metric("meter_q_imp_var", q_imp * 1000.0, "var") end
  if q_exp ~= nil then host.emit_metric("meter_q_exp_var", q_exp * 1000.0, "var") end
  if type(info.rssi) == "number" then host.emit_metric("p1ib_rssi_dbm", info.rssi, "dBm") end

  return poll_ms
end

function driver_cleanup()
  base_url = nil
  last_ok_cnt = nil
  last_new_telegram_ms = nil
  stale_logged = false
  identity_set = false
  consecutive_failures = 0
end
