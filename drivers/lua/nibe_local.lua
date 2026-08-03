-- NIBE S-series Heat Pump — LOCAL REST API driver
-- Emits: metrics only (compressor power, energy meters, temperatures, …)
--        into the long-format TS DB via host.emit_metric.
-- Control: one opt-in write path — the pump's native "Solar PV" surplus feed
--        (srcfl/ftw#537). Everything else on the pump stays untouchable.
-- Protocol: HTTPS (NIBE "Local REST API", self-described at https://<ip>:8443/)
--
-- This is the local-network twin of drivers/myuplink.lua. Instead of the
-- MyUplink cloud (OAuth + internet round-trip), it reads the pump directly
-- over the LAN. The local API is RICHER than the cloud one: every point
-- ships its own metadata (modbus register, unit, exact divisor, writable
-- flag), so scaling is exact — no °C×10 heuristic. ~980 points come back in
-- one bulk GET. Headline metrics land every minute; the bulk map records
-- changes plus an hourly full snapshot so the TS DB stays bounded on a Pi.
--
-- READ-ONLY BY DEFAULT. Without `write.solar_pv: true` in the driver config
-- the driver never issues a write. Note the write gate on the pump side is
-- the installer's read-only / read-write choice for the Local REST API
-- (installer menu 7.5.15) — NOT "aid mode", which is the pump's
-- compressor-off fault-recovery state and has nothing to do with API
-- permissions. A pump left read-only silently refuses writes (HTTP 200 with
-- a per-point "error: read only value" result), and this driver surfaces
-- that as an actionable error instead of pretending success.
--
-- THE SOLAR PV FEED (the only write this driver performs):
--   The S-series has a built-in "Solar PV" input meant for NIBE's Modbus
--   TCP/IP accessory: when the owner enables it (register 2107), the pump
--   expects an external box to keep "Available power" (register 2109)
--   updated with the current solar surplus, and applies the owner-tuned
--   Offset heating/cooling/pool setpoint shifts to soak it up. FTW acts as
--   that accessory: control-by-hint, not direct actuation — the pump's own
--   firmware decides what to do with the number, so misbehaviour degrades to
--   "pump believes a wrong solar value", never to unsafe operation.
--   The semantic switch 2108 ("include own consumption") and the offset
--   aggressiveness stay owner-tuned on the pump; this driver never writes
--   them.
--
--   Safety posture (each clamp answers a quantified risk):
--   - Value clamped to [0, write.max_w] — a sign bug or telemetry spike must
--     not tell the pump there are 100 kW of surplus.
--   - Deadband + at-most-one-write-per-interval — register wear and pointless
--     churn; a heat pump reacts over minutes, not seconds.
--   - Dead-man's switch: if no fresh solar_pv command lands within
--     write.ttl_s, the driver writes 0 once and stops. The pump-side timeout
--     for a silent feed is UNDOCUMENTED, so we do not rely on it.
--   - driver_default_mode (watchdog trip, stale site meter, driver stop)
--     clears the feed: absence of writes is the safe state.
--   - On startup the driver clears a non-zero feed it does not remember
--     writing (crash/restart orphan) — same undocumented-timeout reasoning.
--   All of these run only while FTW itself runs. DECOMMISSIONING: before
--   uninstalling FTW or permanently disabling this feed, turn the Solar PV
--   input (2107) off on the pump — or set the Local REST API back to
--   read-only (menu 7.5.15) — so no stale surplus value can stand with
--   nobody left to clear it.
--
-- Site sign convention: a heat pump is a LOAD. Its electrical draw would be
-- positive W flowing into the site at the grid boundary — but this driver
-- emits diagnostics via host.emit_metric only (never host.emit("meter"|…)),
-- so it performs NO sign conversion and never double-counts against the real
-- grid meter. The thermal/load models consume hp_power_w etc. as twins.
-- The solar_pv command arrives in site convention (negative W = surplus
-- leaving the site) and is converted HERE to the pump's positive-W value —
-- sign conversion happens only at the driver boundary.
--
-- AUTH + TRANSPORT:
--   The local API uses HTTP Basic auth over HTTPS with a SELF-SIGNED
--   certificate. The system trust store can't validate it, so the driver
--   relies on certificate PINNING in the host: grant
--   capabilities.http.tls_pin_sha256 with the pump's cert fingerprint
--   (the "fingeravtryck" shown in the myUplink app, or from
--   `openssl s_client -connect <ip>:8443 | openssl x509 -fingerprint -sha256`).
--   That pins exactly one leaf cert — a swapped cert (MITM on the LAN, which
--   would otherwise capture the Basic-auth password) is rejected at the
--   handshake. Do NOT fall back to blanket insecure-skip-verify.
--
-- Config example (config.yaml):
--   drivers:
--     - name: nibe
--       lua: drivers/nibe_local.lua
--       config:
--         host: "192.168.1.180"
--         port: 8443
--         username: "<local-api-username>"
--         password: "<local-api-password>"   # masked via config_secrets
--         # device_id: "..."        # optional; auto-detected if omitted
--         # write:                  # opt-in Solar PV feed (srcfl/ftw#537)
--         #   solar_pv: true        # master switch; default off
--         #   max_w: 9000           # REQUIRED: site PV nameplate, clamp ceiling
--         #   deadband_w: 50        # skip writes changing less than this
--         #   ttl_s: 300            # dead-man: clear feed if commands stop
--         #   min_interval_ms: 60000 # rate limit for nonzero increases
--         #   enable_id: "5201"     # variableId override for register 2107
--         #   available_id: "5202"  # variableId override for register 2109
--       capabilities:
--         http:
--           allowed_hosts: ["192.168.1.180:8443"]
--           tls_pin_sha256: "<64-hex-char certificate fingerprint>"
--           # allow_write: true     # host-enforced write gate; default off
--
-- The four heating-UI headline metrics map to NIBE S735 variable ids by
-- default; override per model via param_power_id / param_hw_temp_id /
-- param_indoor_temp_id / param_outdoor_temp_id if yours differs (find them
-- in the bulk GET /api/v1/devices/<serial>/points).

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "nibe-local",
  name         = "NIBE REST API S-series",
  manufacturer = "NIBE",
  version      = "1.2.0",
  protocols    = { "http" },
  capabilities = { "apicreds" },
  description  = "NIBE S-series heat-pump telemetry over the on-prem Local REST API (HTTPS + Basic auth, self-signed cert pinned via tls_pin_sha256). Emits compressor/used power, lifetime energy meters, and the full ~980-point register map. Read-only by default; one opt-in write path feeds the pump's native Solar PV surplus input (registers 2107/2109) so the pump soaks up excess solar.",
  homepage     = "https://www.nibe.eu",
  authors      = { "Claude Code (with the help of HuggeK)" },
  tested_models = { "NIBE S735" },
  verification_status = "beta",
  config_secrets = { "password" },
  write_capabilities = { "solar_pv" },
  connection_defaults = { port = 8443 },
}

PROTOCOL = "http"

-- ---- Runtime state -------------------------------------------------------

local base_url      = nil    -- https://<host>:<port>
local auth_value    = nil    -- "Basic <base64(user:pass)>"
local serial        = nil    -- device id (NIBE serial number) used in the path

-- Self-heal: the pump can be briefly unreachable at boot / after a network
-- blip. Rather than wedge on a nil serial (which needed a manual restart),
-- driver_poll retries device detection on this backoff.
local setup_retry_ms = 30000
local last_setup_ms  = nil
local poll_interval_ms = 60000
-- Headline metrics are emitted every poll. The remaining ~980-point map is
-- change-only, with an hourly full refresh so latest-value timestamps stay
-- useful without writing ~1.4 million mostly-duplicate TS rows per day.
local full_refresh_ms = 3600000
local last_full_emit_ms = nil
local last_emitted = {}

-- ---- Solar PV feed state (the one write path — srcfl/ftw#537) ------------
-- The pump's "Solar PV" input, by S-series Modbus register id. The Local
-- REST API keys points by its own variableId; every point's metadata carries
-- modbusRegisterID, so we resolve variableIds at poll time and never
-- hard-code them (they differ between models; the registers don't).
local SOLAR_PV_ENABLE_REG    = 2107  -- "Modbus TCP/IP Ext. (Solar PV)" — owner-enabled master switch
local SOLAR_PV_AVAILABLE_REG = 2109  -- "Available power" — the value FTW feeds (u16 W)

local write_cfg = { solar_pv = false }
local pv_reg           = nil   -- { enable={id,value}, avail={id,divisor,raw} } resolved from the bulk GET
local feed_last_w      = nil   -- last surplus W this run successfully wrote (nil = never wrote)
local feed_cmd_ms      = nil   -- host.millis() of the last solar_pv command received
local feed_write_ms    = nil   -- host.millis() of the last successful PATCH
local orphan_checked   = false -- startup clear of a feed left behind by a previous run
local default_clear_ms = nil   -- rate limit for default-mode clears (fires every tick on stale site meter)

-- ---- Headline metrics + per-model profiles -------------------------------
-- The BULK of telemetry is metadata-driven (every point self-describes its
-- unit + divisor), so reading any S-series pump needs NO per-model code. The
-- only model-specific knobs are the handful of STABLE headline aliases
-- (hp_power_w, hp_outdoor_temp_c, …) that web/heating.js + the thermal twin
-- read by fixed name. Each maps to a local-API variableId, resolved per pump
-- in priority order: explicit config override > model profile > generic
-- S-series default.

-- Logical headline -> { config override key, emitted metric name, watts? }.
local HEADLINES = {
    { key = "power",   cfg = "param_power_id",           name = "hp_power_w",            watts = true },
    { key = "used",    cfg = "param_used_id",            name = "hp_used_power_w",       watts = true },
    { key = "hw",      cfg = "param_hw_temp_id",         name = "hp_hw_top_temp_c" },
    { key = "indoor",  cfg = "param_indoor_temp_id",     name = "hp_indoor_temp_c" },
    { key = "outdoor", cfg = "param_outdoor_temp_id",    name = "hp_outdoor_temp_c" },
    { key = "econs",   cfg = "param_energy_consumed_id", name = "hp_energy_consumed_kwh" },
    { key = "eprod",   cfg = "param_energy_produced_id", name = "hp_energy_produced_kwh" },
    { key = "dm",      cfg = "param_degree_minutes_id",  name = "hp_degree_minutes" },
}

-- Per-model headline variable-id profiles, auto-selected from the pump's
-- product.name / firmwareId (GET /api/v1/devices), matched case-insensitively
-- as a substring. The S-series shares the core register ids, so `default`
-- covers the whole family (verified on an S735); add a model entry ONLY when
-- a specific model is confirmed to renumber a headline. A profile may set
-- just the keys that differ — the rest fall back to default.
local PROFILES = {
    default = {  -- generic NIBE S-series (verified: S735)
        power = "1801", used = "22130", hw = "11", indoor = "158",
        outdoor = "4",  econs = "28393", eprod = "28392", dm = "781",
    },
    -- Example — uncomment + verify the ids against GET …/points before use:
    -- ["s320"] = { power = "1801", hw = "11" },
}

local CANON           = {}   -- id(string) -> { name = "...", watts = bool }
local driver_config   = nil  -- kept so CANON can be rebuilt once the model is known
local device_model    = nil  -- product.name reported by the pump (may be "" / nil)
local device_firmware = nil  -- product.firmwareId (e.g. "nibe-n")

-- ---- Helpers -------------------------------------------------------------

-- Pure-Lua base64 (no host builtin). Used once per init to build the
-- Basic-auth header value.
local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function base64_encode(data)
    return ((data:gsub('.', function(x)
        local r, b = '', x:byte()
        for i = 8, 1, -1 do r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and '1' or '0') end
        return r
    end) .. '0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
        if #x < 6 then return '' end
        local c = 0
        for i = 1, 6 do c = c + (x:sub(i, i) == '1' and 2 ^ (6 - i) or 0) end
        return b64chars:sub(c + 1, c + 1)
    end) .. ({ '', '==', '=' })[#data % 3 + 1])
end

-- The "not connected" sentinel a NIBE variable reports per size. An
-- unconnected sensor returns this (e.g. an absent BT50 room sensor is
-- -32768 for s16) — and the API marks it isOk=true anyway, so we filter
-- by size, not by isOk.
local function size_sentinel(size)
    if size == "s8"  then return -128 end
    if size == "s16" then return -32768 end
    if size == "s32" then return -2147483648 end
    if size == "u8"  then return 255 end
    if size == "u16" then return 65535 end
    if size == "u32" then return 4294967295 end
    return nil
end

-- Turn a point title into a stable hp_ snake_case metric name. NIBE titles
-- embed soft hyphens (U+00AD = bytes 0xC2 0xAD) inside long words
-- ("Compres­sor", "Instant­aneous"); strip them first so the name reads
-- "compressor", not "compres_sor". Remaining non-ASCII / punctuation
-- collapses to single underscores. Empty falls back to the id.
local function sanitize_metric_name(title, id)
    local s = title or ""
    s = string.gsub(s, "\194\173", "")        -- soft hyphen
    s = string.lower(s)
    s = string.gsub(s, "[^a-z0-9]+", "_")
    s = string.gsub(s, "^_+", "")
    s = string.gsub(s, "_+$", "")
    if s == "" then s = "p" .. tostring(id) end
    return "hp_" .. s
end

-- Watts normalisation for the power headline metrics: some models report
-- compressor power in kW, others in W. Emit W either way.
local function to_watts(value, unit)
    if unit == "kW" then return value * 1000.0, "W" end
    return value, (unit ~= "" and unit or "W")
end

-- The NIBE Modbus register id for a point (metadata.modbusRegisterID), formatted
-- as a string for host.emit_metric's optional 4th (register) arg. Surfaced in
-- the per-driver "all signals" detail view so each signal shows its source
-- register. 0 / absent means the point has no Modbus mapping (menu-only) — emit
-- "" so the column stays blank rather than showing a misleading "0".
local function register_str(m)
    local r = tonumber(m.modbusRegisterID)
    if r and r ~= 0 then return string.format("%d", r) end
    return ""
end

-- Validate and scale one API point. Returns nil for malformed values and the
-- per-size "not connected" sentinel.
local function scaled_point(pt)
    local m = pt and pt.metadata
    local v = pt and pt.value
    if type(m) ~= "table" or type(v) ~= "table" or type(v.integerValue) ~= "number" then
        return nil
    end
    local raw = v.integerValue
    local sentinel = size_sentinel(m.variableSize)
    if sentinel and raw == sentinel then return nil end
    local div = tonumber(m.divisor) or 1
    if div == 0 then div = 1 end
    return raw / div, m.unit or "", register_str(m)
end

-- Build the id -> canonical-metric lookup. Each headline's id is resolved
-- explicit config override > model profile > generic default.
local function build_canon(profile, config)
    config = config or {}
    profile = profile or PROFILES.default
    local function s(v) return (v ~= nil and v ~= "") and tostring(v) or nil end
    CANON = {}
    for _, h in ipairs(HEADLINES) do
        local id = s(config[h.cfg]) or s(profile[h.key]) or s(PROFILES.default[h.key])
        if id then CANON[id] = { name = h.name, watts = h.watts } end
    end
end

-- Pick the model profile whose key appears (case-insensitively, as a
-- substring) in the pump's product.name or firmwareId. Falls back to the
-- generic default, which covers the whole S-series.
local function select_profile(model_name, firmware_id)
    local n = string.lower(model_name or "")
    local f = string.lower(firmware_id or "")
    for k, prof in pairs(PROFILES) do
        if k ~= "default" then
            if (n ~= "" and string.find(n, k, 1, true)) or
               (f ~= "" and string.find(f, k, 1, true)) then
                return k, prof
            end
        end
    end
    return "default", PROFILES.default
end

local function auth_headers()
    return { Authorization = auth_value, Accept = "application/json" }
end

local function api_get(path)
    -- pcall both host calls: a malformed response or a host-side raise must
    -- surface as a poll error the caller can back off on, never an
    -- unprotected error that kills driver_poll.
    local ok, resp, err = pcall(host.http_get, base_url .. path, auth_headers())
    if not ok then return nil, "http_get error: " .. tostring(resp) end
    if err then return nil, tostring(err) end
    local ok_json, data = pcall(host.json_decode, resp)
    if not ok_json or not data then return nil, "json decode failed" end
    return data, nil
end

-- ---- Solar PV feed (write path) ------------------------------------------

-- Find one point in the bulk GET result: by explicit variableId override
-- when configured, else by its Modbus register id from point metadata.
local function find_point(data, var_id, modbus_reg)
    if var_id then
        local pt = data[tostring(var_id)]
        if pt then return tostring(var_id), pt end
        return nil, nil
    end
    for id, pt in pairs(data) do
        local m = pt and pt.metadata
        if type(m) == "table" and tonumber(m.modbusRegisterID) == modbus_reg then
            return tostring(id), pt
        end
    end
    return nil, nil
end

-- Resolve the Solar PV enable + available-power points from a bulk GET.
-- Called every poll while the feed is requested, so the pump-side enable
-- state (2107) stays current without extra requests. Last-known-good ids
-- are RETAINED when a decodable body happens to lack the points (partial
-- body, firmware hiccup): the ability to clear a standing feed must not
-- vanish exactly when the pump misbehaves.
local function resolve_pv_points(data)
    local eid, ept = find_point(data, write_cfg.enable_id, SOLAR_PV_ENABLE_REG)
    local aid, apt = find_point(data, write_cfg.available_id, SOLAR_PV_AVAILABLE_REG)
    pv_reg = pv_reg or {}
    if eid and ept then
        pv_reg.enable = { id = eid, value = ept.value and ept.value.integerValue }
    end
    if aid and apt then
        local m = apt.metadata or {}
        local div = tonumber(m.divisor) or 1
        if div == 0 then div = 1 end
        pv_reg.avail = { id = aid, divisor = div, size = m.variableSize,
                         raw = apt.value and apt.value.integerValue }
    end
end

-- One PATCH of the available-power point. The pump answers HTTP 200 even
-- when it refuses a write — the per-point result string ("modified" /
-- "error: read only value" / "error: no such param") is the real verdict,
-- so success is judged on the body, never on the status code alone.
local function write_pv_surplus(w, why)
    if not host.http_patch then
        return nil, "host.http_patch unavailable — this FTW core predates HTTP writes"
    end
    if not (pv_reg and pv_reg.avail and serial) then
        return nil, "Solar PV registers not resolved yet (no successful poll)"
    end
    local raw = math.floor(w * pv_reg.avail.divisor + 0.5)
    -- 2109 is a u16 point and 65535 is the not-connected sentinel; stay
    -- comfortably below both. write.max_w already clamped the wattage.
    if raw > 65000 then raw = 65000 end
    if raw < 0 then raw = 0 end
    local body = string.format(
        '[{"type":"datavalue","variableId":%d,"integerValue":%d,"stringValue":""}]',
        tonumber(pv_reg.avail.id), raw)
    local hdrs = auth_headers()
    hdrs["Content-Type"] = "application/json"
    local resp, err = host.http_patch(
        base_url .. "/api/v1/devices/" .. serial .. "/points", body, hdrs)
    if err then return nil, "PATCH failed: " .. tostring(err) end
    resp = tostring(resp or "")
    if string.find(resp, "read only", 1, true) then
        return nil, "pump refused the write — its Local REST API is read-only; " ..
            "switch it to read/write on the pump (installer menu 7.5.15)"
    end
    if string.find(resp, "error", 1, true) then
        return nil, "pump rejected the write: " .. string.sub(resp, 1, 200)
    end
    if not string.find(resp, "modified", 1, true) then
        -- Unknown-but-not-an-error response shape: accept, keep evidence.
        host.log("debug", "NIBE: unexpected PATCH response: " .. string.sub(resp, 1, 200))
    end
    feed_last_w = w
    feed_write_ms = host.millis()
    host.emit_metric("hp_solar_pv_feed_w", w, "W",
        tostring(SOLAR_PV_AVAILABLE_REG), "Solar PV feed (FTW)")
    host.log("info", "NIBE: solar PV feed = " .. tostring(w) .. " W (" .. why .. ")")
    return true, nil
end

-- The driver_command("solar_pv", power_w) implementation. power_w is in
-- site convention: negative W = power leaving the site = exportable surplus.
-- Returns true on success/no-op, or an error string (v1 contract).
local function solar_pv_command(power_w)
    if not write_cfg.solar_pv then
        return "solar_pv: " .. (write_cfg.disabled_reason or
            "writes are disabled (set driver config write.solar_pv: true)")
    end
    if not serial then
        return "solar_pv: pump not detected yet"
    end
    if not host.http_patch then
        return "solar_pv: host.http_patch unavailable — FTW core upgrade required"
    end
    if not (pv_reg and pv_reg.avail) then
        return "solar_pv: Solar PV registers not resolved yet (waiting for first poll)"
    end
    local n = tonumber(power_w)
    if n == nil then
        return "solar_pv: power_w missing"
    end
    -- Site convention → pump value: only export (negative) is surplus.
    local surplus = n < 0 and -n or 0
    if surplus > write_cfg.max_w then surplus = write_cfg.max_w end
    surplus = math.floor(surplus + 0.5)

    feed_cmd_ms = host.millis()  -- any fresh command feeds the dead-man's switch

    -- A clear is always safe: it bypasses the pump-side enable gate (the
    -- owner turning 2107 off mid-feed must not block FTW from zeroing what
    -- it wrote) and every rate limit — dropping a clear to save a request
    -- would invert the safety trade.
    if surplus == 0 then
        if feed_last_w == 0 then return true end
        local ok, werr = write_pv_surplus(0, "command")
        if not ok then return "solar_pv: " .. tostring(werr) end
        return true
    end

    if not pv_reg.enable then
        return "solar_pv: register 2107 (Solar PV master enable) not found on this pump"
    end
    if pv_reg.enable.value == nil then
        return "solar_pv: register 2107 (Solar PV master enable) could not be read"
    end
    if tonumber(pv_reg.enable.value) ~= 1 then
        return "solar_pv: the pump-side Solar PV input (register 2107) is disabled — " ..
            "the owner must enable it on the pump first"
    end

    if feed_last_w ~= nil then
        local delta = surplus - feed_last_w
        -- A decrease beyond the deadband is safety-direction (surplus
        -- collapsed) and is written immediately; only small jitter and
        -- rapid increases are swallowed.
        if delta >= 0 or -delta < write_cfg.deadband_w then
            if math.abs(delta) < write_cfg.deadband_w then return true end
            if feed_write_ms and (feed_cmd_ms - feed_write_ms) < write_cfg.min_interval_ms then
                return true
            end
        end
    end

    local ok, werr = write_pv_surplus(surplus, "command")
    if not ok then return "solar_pv: " .. tostring(werr) end
    return true
end

-- Per-poll feed maintenance: startup orphan clear + dead-man's switch.
local function maintain_pv_feed()
    if not (pv_reg and pv_reg.avail) then return end
    -- A previous run may have died with a non-zero feed standing. The
    -- pump-side timeout for a silent feed is undocumented, so clear it
    -- ourselves the first time we can. Enabling write.solar_pv declares FTW
    -- the owner of this register, so a non-zero value we don't remember
    -- writing is ours to clean up. The one-shot check is only consumed once
    -- an actual number was read, and the per-size "not connected" sentinel
    -- is NOT a standing feed — writing 0 over it would turn "no accessory"
    -- into "accessory reporting zero", which changes pump behavior.
    if not orphan_checked then
        local raw = pv_reg.avail.raw
        if type(raw) == "number" then
            orphan_checked = true
            local sentinel = size_sentinel(pv_reg.avail.size)
            if feed_last_w == nil and raw > 0 and raw ~= sentinel then
                local ok, err = write_pv_surplus(0, "clearing orphaned feed from a previous run")
                if not ok then
                    orphan_checked = false  -- retry next poll
                    host.log("warn", "NIBE: orphaned solar PV feed clear failed: " .. tostring(err))
                end
            end
        end
    end
    -- Dead-man's switch: commands stopped arriving → clear once.
    if feed_last_w and feed_last_w > 0 and feed_cmd_ms and
       (host.millis() - feed_cmd_ms) > write_cfg.ttl_ms then
        local ok, err = write_pv_surplus(0, "feed stale — dead-man's switch")
        if not ok then
            host.log("warn", "NIBE: stale solar PV feed clear failed: " .. tostring(err))
        end
    end
end

-- ---- Setup ---------------------------------------------------------------

local function detect_serial()
    local data, err = api_get("/api/v1/devices")
    if err then
        host.log("warn", "NIBE: /api/v1/devices failed: " .. err)
        return nil
    end
    local devs = data.devices
    if type(devs) == "table" and devs[1] and devs[1].product then
        local p = devs[1].product
        device_model    = p.name
        device_firmware = p.firmwareId
        if p.serialNumber and p.serialNumber ~= "" then
            host.log("info", "NIBE: detected " .. tostring(p.manufacturer) ..
                " '" .. tostring(p.name) .. "' " .. tostring(p.serialNumber) ..
                " (fw " .. tostring(p.firmwareId) .. ")")
            return p.serialNumber
        end
    end
    host.log("error", "NIBE: no device serial in /api/v1/devices response")
    return nil
end

-- Bring the driver to "ready" (serial known). Safe to call repeatedly;
-- rate-limited by setup_retry_ms. Returns true once serial is established.
local function try_setup()
    if serial then return true end
    local now = host.millis()
    if last_setup_ms ~= nil and (now - last_setup_ms) < setup_retry_ms then
        return false
    end
    last_setup_ms = now
    serial = detect_serial()
    if not serial then return false end
    host.set_sn(serial)
    -- Now that the model is known, refine the headline ids (config overrides
    -- still win inside build_canon).
    local pkey, prof = select_profile(device_model, device_firmware)
    build_canon(prof, driver_config)
    local mode = write_cfg.solar_pv and "solar-pv feed armed" or "read-only"
    host.log("info", "NIBE: ready (" .. mode .. ") serial=" .. serial .. " profile=" .. pkey)
    return true
end

-- ---- Lifecycle -----------------------------------------------------------

function driver_init(config)
    host.set_make("NIBE")
    config = config or {}

    local function s(v) return (v ~= nil and v ~= "") and tostring(v) or nil end
    local username = s(config.username) or ""
    local password = s(config.password) or ""
    serial         = s(config.device_id)

    -- base_url override exists for tests; production builds it from host:port.
    base_url = s(config.base_url)
    if not base_url then
        local host_ip = s(config.host)
        local port    = s(config.port) or "8443"
        if host_ip then base_url = "https://" .. host_ip .. ":" .. port end
    end
    auth_value = "Basic " .. base64_encode(username .. ":" .. password)

    if config.poll_interval_ms ~= nil then
        poll_interval_ms = tonumber(config.poll_interval_ms) or poll_interval_ms
    end
    if config.setup_retry_ms ~= nil then
        setup_retry_ms = tonumber(config.setup_retry_ms) or setup_retry_ms
    end
    if config.full_refresh_ms ~= nil then
        full_refresh_ms = tonumber(config.full_refresh_ms) or full_refresh_ms
    end

    -- Solar PV feed config (write path). Off unless explicitly enabled, and
    -- refused without a clamp ceiling: max_w bounds every value we could
    -- ever write, so a missing max_w means the operator never stated the
    -- site's PV nameplate and the risk clamp cannot do its job.
    local w = config.write or {}
    write_cfg = {
        solar_pv        = (w.solar_pv == true),
        -- The operator asked for the feed at all: clear-only machinery
        -- (orphan sweep, dead-man's switch, default-mode clear) stays armed
        -- on this flag even when validation below refuses NEW writes, so a
        -- config mistake never strands a feed a previous run left standing.
        requested       = (w.solar_pv == true),
        max_w           = tonumber(w.max_w) or 0,
        deadband_w      = tonumber(w.deadband_w) or 50,
        ttl_ms          = (tonumber(w.ttl_s) or 300) * 1000,
        min_interval_ms = tonumber(w.min_interval_ms) or 60000,
        enable_id       = s(w.enable_id),
        available_id    = s(w.available_id),
        disabled_reason = nil,
    }
    if write_cfg.solar_pv and write_cfg.max_w <= 0 then
        write_cfg.solar_pv = false
        write_cfg.disabled_reason = "write.max_w (site PV nameplate, W) is missing " ..
            "or invalid — new writes are disabled"
        host.log("error", "NIBE: " .. write_cfg.disabled_reason ..
            " (feed clearing stays active)")
    end
    if write_cfg.solar_pv and not host.http_patch then
        host.log("warn", "NIBE: this FTW core has no host.http_patch — " ..
            "solar PV writes unavailable until the core is upgraded")
    end

    -- Build the headline lookup with the generic profile now; try_setup
    -- refines it to the detected model's profile once the pump answers.
    -- Config overrides (param_*_id) win in build_canon either way.
    driver_config = config
    build_canon(PROFILES.default, config)

    if not base_url then
        host.log("error", "NIBE: 'host' (pump IP) is required")
        return
    end
    if username == "" or password == "" then
        host.log("error", "NIBE: username and password are required")
        return
    end

    host.set_poll_interval(poll_interval_ms)
    -- Best-effort initial detection; driver_poll self-heals if it fails.
    if not try_setup() then
        host.log("warn", "NIBE: initial setup did not complete — will retry automatically")
    end
end

function driver_poll()
    if not base_url then return setup_retry_ms end
    if not serial then
        if not try_setup() then return setup_retry_ms end
    end

    local data, err = api_get("/api/v1/devices/" .. serial .. "/points")
    if err then
        host.log("warn", "NIBE: points poll failed: " .. err)
        return poll_interval_ms
    end

    if write_cfg.requested then
        resolve_pv_points(data)
        maintain_pv_feed()
    end

    local now = host.millis()
    local full_refresh = last_full_emit_ms == nil or (now - last_full_emit_ms) >= full_refresh_ms

    -- Titles are not guaranteed unique. Count sanitized names first so every
    -- collision gets an id suffix deterministically; the old one-pass `seen`
    -- approach made whichever point happened to appear first change names
    -- across polls because Lua table iteration order is unspecified.
    local name_counts = {}
    for id, pt in pairs(data) do
        if not CANON[tostring(id)] then
            local scaled = scaled_point(pt)
            if scaled ~= nil then
                local base = sanitize_metric_name(pt.title, id)
                name_counts[base] = (name_counts[base] or 0) + 1
            end
        end
    end

    for id, pt in pairs(data) do
        local scaled, unit, reg = scaled_point(pt)
        if scaled ~= nil then
            local canon = CANON[tostring(id)]
            local name = canon and canon.name or sanitize_metric_name(pt.title, id)
            if not canon and (name_counts[name] or 0) > 1 then
                name = name .. "_" .. tostring(id)
            end
            local value = scaled
            if canon and canon.watts then value, unit = to_watts(scaled, unit) end

            -- Stable headline series retain one-minute resolution. The bulk
            -- map records transitions plus an hourly complete snapshot.
            if canon or full_refresh or last_emitted[name] ~= value then
                host.emit_metric(name, value, unit, reg, pt.title)
                last_emitted[name] = value
            end
        end
    end
    if full_refresh then last_full_emit_ms = now end
    -- Guarantees watchdog freshness even on a model whose configured headline
    -- ids are absent and whose non-headline values remain unchanged.
    host.emit_metric("hp_poll_ok", 1, "")

    return poll_interval_ms
end

function driver_command(action, power_w, _cmd)
    if action == "solar_pv" then
        return solar_pv_command(power_w)
    end
    -- Anything else (battery dispatch, EV commands, …) stays rejected: this
    -- driver's only actuator is the Solar PV feed.
    return false
end

function driver_default_mode()
    -- Safe state = no feed standing. Fires on watchdog trip, on every tick
    -- while the site meter is stale, and on driver stop — so it must be
    -- idempotent, rate-limited and quiet when there is nothing to clear.
    -- Gated on `requested`, not the validated flag: a bad max_w must not
    -- disarm the clearing path.
    if not write_cfg.requested then return end
    if feed_last_w == nil or feed_last_w == 0 then return end
    local now = host.millis()
    if default_clear_ms and (now - default_clear_ms) < 60000 then return end
    default_clear_ms = now
    local ok, err = write_pv_surplus(0, "default mode")
    if not ok then
        host.log("warn", "NIBE: default-mode solar PV clear failed " ..
            "(will retry): " .. tostring(err))
    end
end

function driver_cleanup()
    serial       = nil
    last_setup_ms = nil
    last_full_emit_ms = nil
    last_emitted = {}
    pv_reg           = nil
    feed_last_w      = nil
    feed_cmd_ms      = nil
    feed_write_ms    = nil
    orphan_checked   = false
    default_clear_ms = nil
end
