-- zap.lua
-- Sourceful Zap P1/HAN site meter, with optional read-only PV and battery.
--
-- Default: FTW uses Zap as the HAN/P1 meter on the gateway, nothing else.
-- If Zap also lists an inverter, battery or charger, this driver logs that
-- and leaves those resources alone. Add them in FTW with their own drivers.
--
-- Opt-in: when Zap is the only reader — closed inverter Modbus, or an
-- RS-485 bus Zap already owns — set read_pv / read_battery. The driver
-- never writes. Using Zap as a write proxy is not supported.
--
-- Emits: meter; pv and battery only when opted in
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
--       # read_pv: true               # opt-in; default is P1/HAN only
--       # read_battery: true          # opt-in; telemetry only
--       # discovery_interval_ms: 60000
--
-- Site convention (the official Zap model already uses the same signs):
--   meter:  +W import, -W export
--   pv:     -W generation
--   battery:+W charge, -W discharge

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "sourceful-zap",
  name         = "Sourceful Zap (P1/HAN meter)",
  manufacturer = "Sourceful",
  version      = "3.1.0",
  protocols    = { "http" },
  capabilities = { "meter", "pv", "battery" },
  read_only    = true,
  description  = "P1/HAN site meter from a Sourceful Zap. Optionally read PV and battery telemetry from devices Zap already talks to. Prefer a native driver; use this when Zap is the only reader. The driver never writes.",
  homepage     = "https://developer.sourceful.energy/docs/api/zap-local-api",
  authors      = { "Sourceful Energy", "FTW contributors" },
  http_hosts   = { "zap.local" },
  verification_status = "production",
  verified_by = { "erikarenhill@fortytwo:3d" },
  verified_at = "2026-07-17",
  verification_notes = "P1/HAN live-hardware verified against the official Zap Local API (srcful-zap-x-firmware 96e0258). PV aggregation was live-hardware verified on the same API before the 3.0 meter-only cut; it returns as an operator opt-in. Battery payloads are contract-tested against the firmware serializers. Inverters, batteries and chargers found on Zap are not ingested unless read_pv / read_battery is set.",
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
local tracked = {}
local discovered = false
local other_resources = {}
local warned_other = false

local read_pv = false
local read_battery = false
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

local function cfg_true(v)
    return v == true or v == "true" or v == 1 or v == "1"
end

local function bounded(v, min_value, max_value)
    local n = number(v)
    if n == nil then return nil end
    if min_value ~= nil and n < min_value then return nil end
    if max_value ~= nil and n > max_value then return nil end
    return n
end

-- Zap firmware can surface downstream integer overflow sentinels when an
-- inverter is offline. A known nameplate rating gives a quantifiable guard:
-- anything above 10x nameplate cannot be a real operating point, while the
-- generous factor cannot trim a legitimate transient. Without a rating we do
-- not guess a residential ceiling; validation is limited to finite numbers.
local function sane_power(v, rated_power_w)
    local n = number(v)
    if n == nil then return nil end
    local rated = number(rated_power_w) or 0
    if rated > 0 and math.abs(n) > rated * 10 then return nil end
    return n
end

local function metric_tag(sn)
    local tag = string.lower(tostring(sn or "device"))
    tag = string.gsub(tag, "[^%w]+", "_")
    tag = string.gsub(tag, "^_+", "")
    tag = string.gsub(tag, "_+$", "")
    if tag == "" then return "device" end
    return tag
end

local function base_url()
    local host = zap_host
    if string.sub(host, 1, 7) == "http://" or string.sub(host, 1, 8) == "https://" then
        return host
    end
    if zap_port ~= 80 then
        return "http://" .. host .. ":" .. tostring(zap_port)
    end
    return "http://" .. host
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

local function record_for(by_sn, records, sn)
    local rec = by_sn[sn]
    if rec then return rec end
    rec = {
        sn = sn,
        meter = false,
        is_p1 = false,
        pv = false,
        pv_rated_w = 0,
        battery = false,
        battery_rated_w = 0,
        battery_capacity_wh = 0,
    }
    by_sn[sn] = rec
    records[#records + 1] = rec
    return rec
end

-- GET /api/devices describes connection points and DERs. The P1/HAN meter is
-- always taken. PV and battery are ingested only when the operator opts in.
-- Zap's per-DER `enabled` flag controls Nova publishing, not local reads.
local function discover_devices()
    local data, err = fetch_json("/api/devices")
    if err then return nil, nil, nil, err end
    if type(data.devices) ~= "table" then
        return nil, nil, nil, "unexpected payload (no devices array)"
    end

    local records = {}
    local records_by_sn = {}
    local first_p1 = nil
    local first_meter = nil
    local recognised = 0
    local extras = {}
    local seen = {}

    for _, dev in ipairs(data.devices) do
        if type(dev) == "table" and dev.sn then
            local sn = tostring(dev.sn)
            local rec = record_for(records_by_sn, records, sn)
            recognised = recognised + 1

            if dev.type == "p1_uart" then
                rec.meter = true
                rec.is_p1 = true
                if not first_p1 then first_p1 = sn end
                if not first_meter then first_meter = sn end
            end

            if type(dev.ders) == "table" then
                for _, der in ipairs(dev.ders) do
                    if type(der) == "table" then
                        if der.type == "meter" then
                            rec.meter = true
                            if not first_meter then first_meter = sn end
                        elseif der.type == "pv" then
                            if read_pv then
                                rec.pv = true
                                rec.pv_rated_w = number(der.rated_power) or number(der.installed_power) or rec.pv_rated_w
                            else
                                add_other(extras, seen, "PV inverter")
                            end
                        elseif der.type == "battery" then
                            if read_battery then
                                rec.battery = true
                                rec.battery_rated_w = number(der.rated_power) or rec.battery_rated_w
                                rec.battery_capacity_wh = number(der.capacity) or rec.battery_capacity_wh
                            else
                                add_other(extras, seen, "battery")
                            end
                        elseif der.type == "v2x_charger" or der.type == "ev" then
                            add_other(extras, seen, "charger")
                        elseif der.type ~= nil and der.type ~= "" and der.type ~= "meter" then
                            add_other(extras, seen, tostring(der.type))
                        end
                    end
                end
            end

            if (dev.device_type == "energy_meter" or dev.device_type == "meter") and not rec.meter then
                rec.meter = true
                if not first_meter then first_meter = sn end
            elseif not rec.meter and not rec.pv and not rec.battery then
                if dev.device_type == "v2x_charger" then
                    add_other(extras, seen, "charger")
                elseif dev.device_type == "inverter" or dev.device_type == "pv" then
                    if read_pv then
                        rec.pv = true
                    else
                        add_other(extras, seen, "PV inverter")
                    end
                elseif dev.device_type == "battery" then
                    if read_battery then
                        rec.battery = true
                    else
                        add_other(extras, seen, "battery")
                    end
                end
            end
        end
    end

    if recognised == 0 then
        return nil, nil, extras, "no recognised Zap devices found"
    end

    local selected_meter = pinned_meter_serial or first_p1 or first_meter
    if pinned_meter_serial then
        local pinned = record_for(records_by_sn, records, pinned_meter_serial)
        pinned.meter = true
    end
    return records, selected_meter, extras, nil
end

local function count_kind(kind)
    local n = 0
    for _, rec in ipairs(tracked) do
        if rec[kind] then n = n + 1 end
    end
    return n
end

local function other_resources_message(extras)
    if type(extras) ~= "table" or #extras == 0 then return nil end
    local names = table.concat(extras, ", ")
    return "Zap also lists a " .. names
        .. ". Add those devices in FTW with their own drivers, or turn on read_pv / read_battery on this Zap when it is the only reader. This driver never writes."
end

local function apply_discovery(records, selected_meter, extras)
    tracked = records or {}
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
        .. ", pv=" .. tostring(count_kind("pv"))
        .. ", battery=" .. tostring(count_kind("battery"))
        .. ", other_resources=" .. tostring(#other_resources)
        .. ", read_pv=" .. tostring(read_pv)
        .. ", read_battery=" .. tostring(read_battery))

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
    local records, selected_meter, extras, err = discover_devices()
    if err then
        bump_discovery_backoff()
        host.log("warn", "Zap: discovery failed: " .. tostring(err)
            .. " (retry in " .. discovery_backoff_ms .. "ms)")
        return discovered
    end
    apply_discovery(records, selected_meter, extras)
    return true
end

local function emit_optional_metric(name, value, unit)
    local n = number(value)
    if n ~= nil then host.emit_metric(name, n, unit) end
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

    local meter_reading = { w = w }
    for _, mapping in ipairs(meter_fields) do
        local value = number(raw[mapping[2]])
        if value ~= nil then
            meter_reading[mapping[1]] = value
            host.emit_metric("meter_" .. mapping[1], value, mapping[3])
        end
    end
    -- Keep the established local FTW aliases while also emitting the clean
    -- Sourceful federation names consumed by internal/nova.
    meter_reading.import_wh = meter_reading.total_import_wh
    meter_reading.export_wh = meter_reading.total_export_wh
    host.emit("meter", meter_reading)
    return true
end

local function wants_snapshot(rec)
    if not rec then return false end
    if meter_serial and rec.sn == meter_serial then return true end
    if rec.pv or rec.battery then return true end
    return false
end

local function snapshot_map()
    local out = {}
    for _, rec in ipairs(tracked) do
        if wants_snapshot(rec) then
            local data, err = fetch_json("/api/devices/" .. tostring(rec.sn) .. "/data/json")
            if data then
                out[rec.sn] = data
            elseif rec.sn == meter_serial then
                host.log("warn", "Zap: site-meter fetch failed: " .. tostring(err))
            else
                host.log("debug", "Zap: device fetch failed for " .. rec.sn .. ": " .. tostring(err))
            end
        end
    end
    if meter_serial and not out[meter_serial] then
        local data, err = fetch_json("/api/devices/" .. tostring(meter_serial) .. "/data/json")
        if data then
            out[meter_serial] = data
        else
            host.log("warn", "Zap: site-meter fetch failed: " .. tostring(err))
        end
    end
    return out
end

local function emit_pv(snapshots)
    local source_count = count_kind("pv")
    if source_count == 0 then return end

    local total_w = 0
    local total_generation_wh = 0
    local any_power = false
    local any_generation = false
    local total_rated_w = 0
    local any_rating = false

    for _, rec in ipairs(tracked) do
        local data = snapshots[rec.sn]
        local pv = data and data.pv
        if rec.pv and type(pv) == "table" then
            local rated = number(pv.rated_power_W) or rec.pv_rated_w
            if rated and rated > 0 then
                total_rated_w = total_rated_w + rated
                any_rating = true
            end
            local w = sane_power(pv.W, rated)
            if w ~= nil and w <= 0 then
                total_w = total_w + w
                any_power = true
                if source_count > 1 then
                    host.emit_metric("pv_w_" .. metric_tag(rec.sn), w, "W")
                end
            elseif w ~= nil then
                host.log("warn", "Zap: rejected positive PV power for " .. rec.sn .. ": " .. w .. "W")
            end

            local generation = bounded(pv.total_generation_Wh, 0, nil)
            if generation ~= nil then
                total_generation_wh = total_generation_wh + generation
                any_generation = true
            end

            local tag = source_count > 1 and ("_" .. metric_tag(rec.sn)) or ""
            emit_optional_metric("pv_heatsink_c" .. tag, number(pv.heatsink_C), "°C")
            emit_optional_metric("pv_mppt1_v" .. tag, number(pv.mppt1_V), "V")
            emit_optional_metric("pv_mppt1_a" .. tag, number(pv.mppt1_A), "A")
            emit_optional_metric("pv_mppt2_v" .. tag, number(pv.mppt2_V), "V")
            emit_optional_metric("pv_mppt2_a" .. tag, number(pv.mppt2_A), "A")
        end
    end

    if any_power then
        -- Zap already reports generation as negative. Force the site
        -- convention so a sign error in firmware cannot import as load.
        local pv_reading = {}
        pv_reading.w = -math.abs(total_w)
        if any_generation then
            pv_reading.lifetime_wh = total_generation_wh
            pv_reading.total_generation_wh = total_generation_wh
        end
        if any_rating then pv_reading.rated_w = total_rated_w end
        host.emit("pv", pv_reading)
        host.emit_metric("pv_w", pv_reading.w, "W")
    end
end

local function emit_battery(snapshots)
    local source_count = count_kind("battery")
    if source_count == 0 then return end

    local total_w = 0
    local any_power = false
    local soc_sum = 0
    local soc_count = 0
    local weighted_soc_sum = 0
    local weight_sum = 0
    local weighted_count = 0
    local total_charge_wh = 0
    local total_discharge_wh = 0
    local any_charge_energy = false
    local any_discharge_energy = false
    local total_rated_w = 0
    local any_rating = false
    local single = nil

    for _, rec in ipairs(tracked) do
        local data = snapshots[rec.sn]
        local battery = data and data.battery
        if rec.battery and type(battery) == "table" then
            single = battery
            local rated = number(battery.rated_power_W) or rec.battery_rated_w
            if rated and rated > 0 then
                total_rated_w = total_rated_w + rated
                any_rating = true
            end
            local w = sane_power(battery.W, rated)
            if w ~= nil then
                total_w = total_w + w
                any_power = true
            end

            -- Firmware SoC_nom_fract is 0-1. Identifier keeps the
            -- catalog check that soc is already a fraction, not percent.
            local soc_already_fract = bounded(battery.SoC_nom_fract, 0, 1)
            local soc = soc_already_fract
            if soc ~= nil then
                soc_sum = soc_sum + soc
                soc_count = soc_count + 1
                local capacity = bounded(battery.capacity_Wh, 0, nil) or bounded(rec.battery_capacity_wh, 0, nil)
                if capacity and capacity > 0 then
                    weighted_soc_sum = weighted_soc_sum + soc * capacity
                    weight_sum = weight_sum + capacity
                    weighted_count = weighted_count + 1
                end
            end

            local charge = bounded(battery.total_charge_Wh, 0, nil)
            if charge ~= nil then total_charge_wh = total_charge_wh + charge; any_charge_energy = true end
            local discharge = bounded(battery.total_discharge_Wh, 0, nil)
            if discharge ~= nil then total_discharge_wh = total_discharge_wh + discharge; any_discharge_energy = true end

            local tag = source_count > 1 and ("_" .. metric_tag(rec.sn)) or ""
            if source_count > 1 and w ~= nil then host.emit_metric("battery_w" .. tag, w, "W") end
            if source_count > 1 and soc ~= nil then host.emit_metric("battery_soc" .. tag, soc, "fraction") end
            emit_optional_metric("battery_dc_v" .. tag, number(battery.V), "V")
            emit_optional_metric("battery_dc_a" .. tag, number(battery.A), "A")
            emit_optional_metric("battery_temp_c" .. tag, number(battery.heatsink_C), "°C")
        end
    end

    if not any_power then return end
    local battery_reading = { w = total_w }
    if soc_count > 0 then
        if weighted_count == soc_count and weight_sum > 0 then
            battery_reading.soc = weighted_soc_sum / weight_sum
        else
            battery_reading.soc = soc_sum / soc_count
        end
        battery_reading.soc_nom_fract = battery_reading.soc
    end
    if any_charge_energy then
        battery_reading.charge_wh = total_charge_wh
        battery_reading.total_charge_wh = total_charge_wh
    end
    if any_discharge_energy then
        battery_reading.discharge_wh = total_discharge_wh
        battery_reading.total_discharge_wh = total_discharge_wh
    end
    if any_rating then battery_reading.rated_w = total_rated_w end

    if source_count == 1 and single then
        battery_reading.v = number(single.V)
        battery_reading.a = number(single.A)
        battery_reading.temp_c = number(single.heatsink_C)
    end

    host.emit("battery", battery_reading)
    host.emit_metric("battery_w", total_w, "W")
    if battery_reading.soc ~= nil then host.emit_metric("battery_soc", battery_reading.soc, "fraction") end
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
        read_pv = cfg_true(config.read_pv)
        read_battery = cfg_true(config.read_battery)
        local interval = number(config.discovery_interval_ms)
        if interval and interval >= 5000 then discovery_interval_ms = interval end
    end

    host.log("info", "Zap: P1/HAN meter driver initialized (host=" .. zap_host
        .. ", read_pv=" .. tostring(read_pv)
        .. ", read_battery=" .. tostring(read_battery) .. ")")
end

function driver_poll()
    resolve_gateway_identity()
    if not maybe_discover() then return 1000 end

    emit_other_resource_notice()

    local snapshots = snapshot_map()
    if meter_serial then
        local ok = emit_meter(snapshots[meter_serial])
        if ok then
            meter_fail_count = 0
        else
            meter_fail_count = meter_fail_count + 1
            host.log("warn", "Zap: site-meter payload unavailable (" .. meter_fail_count
                .. "/" .. METER_FAIL_REDISCOVER .. ")")
            if meter_fail_count >= METER_FAIL_REDISCOVER then
                discovered = false
                discovery_last_success = 0
                meter_fail_count = 0
                host.log("warn", "Zap: repeated meter failures; device discovery invalidated")
            end
        end
    end

    if read_pv then emit_pv(snapshots) end
    if read_battery then emit_battery(snapshots) end

    return 1000
end

function driver_command(action, power_w, cmd)
    if action == "init" or action == "deinit" then return true end
    host.log("warn", "Zap: this driver is read-only; ignored action=" .. tostring(action))
    return false
end

function driver_default_mode()
    -- Read-only: the meter has no mode to restore.
end

function driver_cleanup()
    gateway_serial = nil
    meter_serial = nil
    tracked = {}
    other_resources = {}
    warned_other = false
    discovered = false
    discovery_last_success = 0
    identity_last_attempt = 0
    meter_fail_count = 0
    clear_discovery_backoff()
end
