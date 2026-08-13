-- zap.lua
-- Sourceful Zap P1/HAN site meter.
--
-- FTW uses Zap as the HAN/P1 meter on the gateway, nothing else. If Zap
-- also lists an inverter, battery or charger, this driver logs that and
-- leaves those resources alone. Add them in FTW with their own drivers.
-- Using Zap as a proxy for those devices is not supported.
--
-- Emits: meter
-- Protocol: HTTP
-- API contract: https://developer.sourceful.energy/docs/api/zap-local-api
--
-- Config example:
--   - name: sourceful-zap
--     lua: drivers/zap.lua
--     is_site_meter: true
--     capabilities:
--       http:
--         allowed_hosts: ["zap.local"]
--     config:
--       host: zap.local
--       # meter_serial: p1m-...       # optional; P1/HAN is auto-selected
--       # discovery_interval_ms: 60000
--
-- Site convention (the official Zap model already uses the same signs):
--   meter:  +W import, -W export

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "sourceful-zap",
  name         = "Sourceful Zap (P1/HAN meter)",
  manufacturer = "Sourceful",
  version      = "3.0.0",
  protocols    = { "http" },
  capabilities = { "meter" },
  read_only    = true,
  description  = "P1/HAN site meter from a Sourceful Zap. Add inverters, batteries and chargers in FTW with their own drivers. Do not attach them to Zap for FTW.",
  homepage     = "https://developer.sourceful.energy/docs/api/zap-local-api",
  authors      = { "Sourceful Energy", "FTW contributors" },
  http_hosts   = { "zap.local" },
  verification_status = "production",
  verified_by = { "erikarenhill@fortytwo:3d" },
  verified_at = "2026-07-17",
  verification_notes = "P1/HAN live-hardware verified against the official Zap Local API (srcful-zap-x-firmware 96e0258). Inverters, batteries and chargers found on Zap are reported to the operator and not ingested.",
  tested_models = { "Sourceful Zap (ESP32-C3 controller firmware)" },
  connection_defaults = {
    host = "zap.local",
    port = 80,
  },
}

PROTOCOL = "http"

local zap_host = "zap.local"
local zap_port = 80
local gateway_serial = nil
local pinned_meter_serial = nil
local meter_serial = nil
local discovered = false
local other_resources = {}
local warned_other = false

local discovery_interval_ms = 60000
local discovery_last_attempt = 0
local discovery_last_success = 0
local discovery_backoff_ms = 0
local DISCOVERY_BACKOFF_MIN = 2000
local DISCOVERY_BACKOFF_MAX = 60000

local identity_last_attempt = 0
local IDENTITY_RETRY_MS = 60000

local meter_fail_count = 0
local METER_FAIL_REDISCOVER = 10

local function number(v)
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return nil end
    return n
end

local function base_url()
    local host = zap_host
    if string.sub(host, 1, 7) == "http://" or string.sub(host, 1, 8) == "https://" then
        return host
    end
    if zap_port ~= 80 then
        local base_url = "http://" .. host .. ":" .. tostring(zap_port)
        return base_url
    end
    local base_url = "http://" .. host
    return base_url
end

local function fetch_json(path)
    local ok, body, err = pcall(host.http_get, base_url() .. path)
    if not ok then return nil, tostring(body) end
    if not body then return nil, err or "empty response" end
    local dec_ok, data = pcall(host.json_decode, body)
    if not dec_ok then return nil, tostring(data) end
    if type(data) ~= "table" then return nil, "json decode failed" end
    return data, nil
end

local function resolve_gateway_identity()
    local now = host.millis()
    if gateway_serial or (identity_last_attempt > 0 and now - identity_last_attempt < IDENTITY_RETRY_MS) then
        return
    end
    identity_last_attempt = now
    local data, err = fetch_json("/api/crypto")
    if err then
        host.log("debug", "Zap: identity endpoint unavailable: " .. tostring(err))
        return
    end
    local serial = data.serialNumber or data.serial_number
    if type(serial) == "string" and serial ~= "" then
        gateway_serial = serial
        host.set_sn(serial)
        host.log("info", "Zap: gateway identity " .. serial)
    end
end

local function bump_discovery_backoff()
    if discovery_backoff_ms == 0 then
        discovery_backoff_ms = DISCOVERY_BACKOFF_MIN
    else
        discovery_backoff_ms = math.min(discovery_backoff_ms * 2, DISCOVERY_BACKOFF_MAX)
    end
    discovery_last_attempt = host.millis()
end

local function clear_discovery_backoff()
    discovery_backoff_ms = 0
    discovery_last_attempt = 0
end

local function discovery_in_backoff()
    if discovery_backoff_ms == 0 then return false end
    return host.millis() - discovery_last_attempt < discovery_backoff_ms
end

local function add_other(list, seen, label)
    if seen[label] then return end
    seen[label] = true
    list[#list + 1] = label
end

-- GET /api/devices describes connection points and DERs. This driver takes
-- the P1/HAN meter only. Anything else is reported so the operator can add
-- it in FTW with a native driver.
local function discover_devices()
    local data, err = fetch_json("/api/devices")
    if err then return nil, nil, nil, err end
    if type(data.devices) ~= "table" then
        return nil, nil, nil, "unexpected payload (no devices array)"
    end

    local first_p1 = nil
    local first_meter = nil
    local recognised = 0
    local extras = {}
    local seen = {}

    for _, dev in ipairs(data.devices) do
        if type(dev) == "table" and dev.sn then
            recognised = recognised + 1
            local is_meter = false

            if dev.type == "p1_uart" then
                is_meter = true
                if not first_p1 then first_p1 = tostring(dev.sn) end
                if not first_meter then first_meter = tostring(dev.sn) end
            end

            if type(dev.ders) == "table" then
                for _, der in ipairs(dev.ders) do
                    if type(der) == "table" then
                        if der.type == "meter" then
                            is_meter = true
                            if not first_meter then first_meter = tostring(dev.sn) end
                        elseif der.type == "pv" then
                            add_other(extras, seen, "PV inverter")
                        elseif der.type == "battery" then
                            add_other(extras, seen, "battery")
                        elseif der.type == "v2x_charger" or der.type == "ev" then
                            add_other(extras, seen, "charger")
                        elseif der.type ~= nil and der.type ~= "" then
                            add_other(extras, seen, tostring(der.type))
                        end
                    end
                end
            end

            if (dev.device_type == "energy_meter" or dev.device_type == "meter") and not is_meter then
                is_meter = true
                if not first_meter then first_meter = tostring(dev.sn) end
            elseif not is_meter and dev.device_type == "v2x_charger" then
                add_other(extras, seen, "charger")
            elseif not is_meter and (dev.device_type == "inverter" or dev.device_type == "pv") then
                add_other(extras, seen, "PV inverter")
            elseif not is_meter and dev.device_type == "battery" then
                add_other(extras, seen, "battery")
            end
        end
    end

    if recognised == 0 then
        return nil, nil, extras, "no recognised Zap devices found"
    end

    local selected_meter = pinned_meter_serial or first_p1 or first_meter
    return selected_meter, extras, extras, nil
end

local function other_resources_message(extras)
    if type(extras) ~= "table" or #extras == 0 then return nil end
    local names = table.concat(extras, ", ")
    return "Zap also lists a " .. names
        .. ". Add "
        .. names
        .. " in FTW with its own driver. This Zap driver is the P1/HAN meter only."
end

local function apply_discovery(selected_meter, extras)
    meter_serial = selected_meter
    other_resources = extras or {}
    discovered = true
    discovery_last_success = host.millis()
    meter_fail_count = 0
    clear_discovery_backoff()

    -- Legacy fallback for older Zap firmware without /api/crypto. Current
    -- firmware overwrites this with the gateway's own zap-* serial.
    if not gateway_serial and meter_serial then host.set_sn(meter_serial) end

    host.log("info", "Zap: P1/HAN meter=" .. tostring(meter_serial or "none")
        .. ", other_resources=" .. tostring(#other_resources))

    local msg = other_resources_message(other_resources)
    if msg and not warned_other then
        host.log("warn", "Zap: " .. msg)
        warned_other = true
    end
end

local function maybe_discover()
    local now = host.millis()
    local due = not discovered or discovery_last_success == 0
        or now - discovery_last_success >= discovery_interval_ms
    if not due or discovery_in_backoff() then return discovered end

    discovery_last_attempt = now
    local selected_meter, extras, _, err = discover_devices()
    if err then
        bump_discovery_backoff()
        host.log("warn", "Zap: discovery failed: " .. tostring(err)
            .. " (retry in " .. discovery_backoff_ms .. "ms)")
        return discovered
    end
    apply_discovery(selected_meter, extras)
    return true
end

local meter_fields = {
    { "l1_w", "L1_W", "W" }, { "l2_w", "L2_W", "W" }, { "l3_w", "L3_W", "W" },
    { "l1_v", "L1_V", "V" }, { "l2_v", "L2_V", "V" }, { "l3_v", "L3_V", "V" },
    { "l1_a", "L1_A", "A" }, { "l2_a", "L2_A", "A" }, { "l3_a", "L3_A", "A" },
    { "freq_hz", "Hz", "Hz" },
    { "total_import_wh", "total_import_Wh", "Wh" },
    { "total_export_wh", "total_export_Wh", "Wh" },
}

local function emit_meter(data)
    if type(data) ~= "table" or type(data.meter) ~= "table" then return false end
    local raw = data.meter
    local w = number(raw.W)
    if w == nil then return false end

    local reading = { w = w }
    for _, mapping in ipairs(meter_fields) do
        local value = number(raw[mapping[2]])
        if value ~= nil then
            reading[mapping[1]] = value
            host.emit_metric("meter_" .. mapping[1], value, mapping[3])
        end
    end
    -- Keep the established local FTW aliases while also emitting the clean
    -- Sourceful federation names consumed by internal/nova.
    reading.import_wh = reading.total_import_wh
    reading.export_wh = reading.total_export_wh
    host.emit("meter", reading)
    return true
end

local function emit_other_resource_notice()
    host.emit_metric("other_resources", #other_resources, "")
end

----------------------------------------------------------------------------
-- Fingerprint
----------------------------------------------------------------------------

function driver_fingerprint(target)
    local base = target and target.base_url
    if not base or base == "" then return nil end

    -- Current firmware has a strong identity signature.
    local crypto_ok, crypto_body = pcall(host.http_get, base .. "/api/crypto")
    if crypto_ok and crypto_body then
        local dec_ok, crypto = pcall(host.json_decode, crypto_body)
        if dec_ok and type(crypto) == "table" and crypto.publicKey and crypto.serialNumber
            and (crypto.deviceName == "software_zap" or string.sub(tostring(crypto.serialNumber), 1, 4) == "zap-") then
            return true, {
                make = "Sourceful", model = "Zap", serial = tostring(crypto.serialNumber), confidence = 1.0,
            }
        end
    end

    -- Legacy fallback: older field units lacked /api/crypto but exposed the
    -- characteristic devices list. Keep them discoverable at lower confidence.
    local ok, body, err = pcall(host.http_get, base .. "/api/devices")
    if not ok or err or not body then return nil end
    local dec_ok, data = pcall(host.json_decode, body)
    if not dec_ok or type(data) ~= "table" or type(data.devices) ~= "table" then return false end
    local serial = nil
    local recognised = false
    for _, dev in ipairs(data.devices) do
        if type(dev) == "table" and dev.sn and (dev.type or dev.device_type or dev.ders) then
            recognised = true
            if dev.type == "p1_uart" then serial = tostring(dev.sn) end
        end
    end
    if recognised then
        return true, { make = "Sourceful", model = "Zap", serial = serial or "", confidence = 0.85 }
    end
    return false
end

----------------------------------------------------------------------------
-- Driver lifecycle
----------------------------------------------------------------------------

function driver_init(config)
    host.set_make("Sourceful")

    if config and type(config.host) == "string" and config.host ~= "" then
        zap_host = config.host
    end
    if config then
        local port = number(config.port)
        if port and port > 0 then zap_port = port end
        local pinned = config.meter_serial or config.serial
        if type(pinned) == "string" and pinned ~= "" then
            pinned_meter_serial = pinned
            host.log("info", "Zap: using pinned meter serial " .. pinned)
        end
        local interval = number(config.discovery_interval_ms)
        if interval and interval >= 5000 then discovery_interval_ms = interval end
    end

    host.log("info", "Zap: P1/HAN meter driver initialized (host=" .. zap_host .. ")")
end

function driver_poll()
    resolve_gateway_identity()
    if not maybe_discover() then return 1000 end

    emit_other_resource_notice()

    if meter_serial then
        local data, err = fetch_json("/api/devices/" .. tostring(meter_serial) .. "/data/json")
        local ok = emit_meter(data)
        if ok then
            meter_fail_count = 0
        else
            meter_fail_count = meter_fail_count + 1
            host.log("warn", "Zap: site-meter payload unavailable (" .. meter_fail_count
                .. "/" .. METER_FAIL_REDISCOVER .. ")"
                .. (err and (": " .. tostring(err)) or ""))
            if meter_fail_count >= METER_FAIL_REDISCOVER then
                discovered = false
                discovery_last_success = 0
                meter_fail_count = 0
                host.log("warn", "Zap: repeated meter failures; device discovery invalidated")
            end
        end
    end

    return 1000
end

function driver_command(action, power_w, cmd)
    if action == "init" or action == "deinit" then return true end
    host.log("warn", "Zap: this driver is the P1/HAN meter only; ignored action=" .. tostring(action))
    return false
end

function driver_default_mode()
    -- Read-only: the meter has no mode to restore.
end

function driver_cleanup()
    gateway_serial = nil
    meter_serial = nil
    other_resources = {}
    warned_other = false
    discovered = false
    discovery_last_success = 0
    identity_last_attempt = 0
    meter_fail_count = 0
    clear_discovery_backoff()
end
