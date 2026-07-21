-- Shelly Gen2/Gen3/Gen4 Family HTTP Driver
-- Emits: Meter only
-- Supports all Shelly devices with energy metering via auto-detection:
--   EM component:  Pro 3EM, 3EM Gen3, 3EM-63W Gen3 (3-phase)
--   EM1 component: Pro EM-50, EM Gen3 (single-phase, 1-2 channels)
--   PM1 component: Mini PM Gen3, EM Mini Gen4 (power monitor, no relay)
--   Switch component: Plus 1PM/2PM, 1PM Gen3, 2PM Gen3, Pro 4PM,
--                     Plus Plug S, Plug S Gen3, 1PM Mini Gen3 (relay + metering)
--
-- All Gen2+ Shelly devices share a JSON-RPC 2.0 API over HTTP.
-- This driver auto-detects the device type via Shelly.GetDeviceInfo and polls
-- the appropriate status endpoint.
--
-- Sign convention: Shelly positive = consumption/import (matches Sourceful meter convention)

PROTOCOL = "http"

-- Module state
local base_url = nil
local device_type = nil    -- "em", "em1", "pm1", "switch"
local channel_count = 0

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

-- HTTP GET + JSON decode with error handling
local function http_get_json(path)
    local ok, body = pcall(host.http_get, base_url .. path)
    if not ok or not body then return nil end
    local ok2, data = pcall(host.json_decode, body)
    if not ok2 or not data then return nil end
    return data
end

-- Map Shelly app name (from GetDeviceInfo.app) to device type and channel count.
-- This covers Gen2, Gen3, and Gen4 models with energy metering.
-- Unrecognized models fall back to endpoint probing.
local app_map = {
    -- 3-phase energy meters (EM component)
    Pro3EM     = { type = "em", channels = 1 },
    ["3EMG3"]  = { type = "em", channels = 1 },  -- 3EM Gen3
    S3EMG3     = { type = "em", channels = 1 },  -- 3EM Gen3 (alt)
    ["3EM63G3"]= { type = "em", channels = 1 },  -- 3EM-63W Gen3

    -- Single-phase energy meters (EM1 component)
    ProEM      = { type = "em1", channels = 2 },  -- Pro EM-50 (2-channel)
    EMG3       = { type = "em1", channels = 1 },   -- EM Gen3

    -- Power monitors (PM1 component, no relay)
    MiniPMG3   = { type = "pm1", channels = 1 },  -- Mini PM Gen3 (confirmed)
    EMMiniG4   = { type = "pm1", channels = 1 },  -- EM Mini Gen4

    -- Switches with power metering (Switch component)
    Plus1PM    = { type = "switch", channels = 1 },
    Plus2PM    = { type = "switch", channels = 2 },
    Pro4PM     = { type = "switch", channels = 4 },
    PlusPlugS  = { type = "switch", channels = 1 },
    ["1PMG3"]  = { type = "switch", channels = 1 },  -- 1PM Gen3
    S1PMG3     = { type = "switch", channels = 1 },  -- 1PM Gen3 (alt)
    ["2PMG3"]  = { type = "switch", channels = 2 },  -- 2PM Gen3
    S2PMG3     = { type = "switch", channels = 2 },  -- 2PM Gen3 (alt)
    PlugSG3    = { type = "switch", channels = 1 },  -- Plug S Gen3
    Mini1PMG3  = { type = "switch", channels = 1 },  -- 1PM Mini Gen3
    ["1MiniG3"]= { type = "switch", channels = 1 },  -- 1 Mini Gen3
    ["1PMG4"]  = { type = "switch", channels = 1 },  -- 1PM Gen4
    ["2PMG4"]  = { type = "switch", channels = 2 },  -- 2PM Gen4
}

-- Try to detect device type by probing status endpoints
local function detect_by_probing()
    local em = http_get_json("/rpc/EM.GetStatus?id=0")
    if em then return "em", 1 end

    local em1 = http_get_json("/rpc/EM1.GetStatus?id=0")
    if em1 then
        local em1_ch2 = http_get_json("/rpc/EM1.GetStatus?id=1")
        return "em1", em1_ch2 and 2 or 1
    end

    local pm1 = http_get_json("/rpc/PM1.GetStatus?id=0")
    if pm1 then
        local pm1_ch2 = http_get_json("/rpc/PM1.GetStatus?id=1")
        return "pm1", pm1_ch2 and 2 or 1
    end

    local sw = http_get_json("/rpc/Switch.GetStatus?id=0")
    if sw then
        local count = 1
        for i = 1, 3 do
            local ch = http_get_json("/rpc/Switch.GetStatus?id=" .. i)
            if ch then count = count + 1 else break end
        end
        return "switch", count
    end

    return nil, 0
end

----------------------------------------------------------------------------
-- EM polling (Pro 3EM -- 3-phase)
----------------------------------------------------------------------------

local function poll_em()
    local data = http_get_json("/rpc/EM.GetStatus?id=0")
    if not data or data.a_act_power == nil or data.b_act_power == nil or data.c_act_power == nil then
        return nil
    end

    local meter = {}

    -- Per-phase power, voltage, current
    meter.l1_w = data.a_act_power or 0
    meter.l2_w = data.b_act_power or 0
    meter.l3_w = data.c_act_power or 0
    meter.w    = meter.l1_w + meter.l2_w + meter.l3_w

    meter.l1_v = data.a_voltage or 0
    meter.l2_v = data.b_voltage or 0
    meter.l3_v = data.c_voltage or 0

    meter.l1_a = data.a_current or 0
    meter.l2_a = data.b_current or 0
    meter.l3_a = data.c_current or 0

    meter.hz = data.a_freq or 0

    -- Energy counters (Wh natively)
    local a_imp = data.a_aenergy and data.a_aenergy.total or 0
    local b_imp = data.b_aenergy and data.b_aenergy.total or 0
    local c_imp = data.c_aenergy and data.c_aenergy.total or 0
    meter.import_wh = a_imp + b_imp + c_imp

    local a_exp = data.a_ret_aenergy and data.a_ret_aenergy.total or 0
    local b_exp = data.b_ret_aenergy and data.b_ret_aenergy.total or 0
    local c_exp = data.c_ret_aenergy and data.c_ret_aenergy.total or 0
    meter.export_wh = a_exp + b_exp + c_exp

    return meter
end

----------------------------------------------------------------------------
-- EM1 polling (Pro EM-50, EM Gen3 -- single-phase per channel)
----------------------------------------------------------------------------

local function poll_em1()
    local meter = {}
    local total_w = 0
    local total_import = 0
    local total_export = 0
	local successful_channels = 0

    for i = 0, channel_count - 1 do
        local data = http_get_json("/rpc/EM1.GetStatus?id=" .. i)
		if data and data.act_power ~= nil then
			successful_channels = successful_channels + 1
            local phase_w = data.act_power or 0
            total_w = total_w + phase_w

            -- Map channels to phases
            local phase = i + 1
            if phase == 1 then
                meter.l1_w = phase_w
                meter.l1_v = data.voltage or 0
                meter.l1_a = data.current or 0
            elseif phase == 2 then
                meter.l2_w = phase_w
                meter.l2_v = data.voltage or 0
                meter.l2_a = data.current or 0
            end

            meter.hz = data.freq or meter.hz or 0

            local imp = data.aenergy and data.aenergy.total or 0
            local exp = data.ret_aenergy and data.ret_aenergy.total or 0
            total_import = total_import + imp
            total_export = total_export + exp
        end
    end

	if successful_channels ~= channel_count then return nil end

    meter.w = total_w
    meter.import_wh = total_import
    meter.export_wh = total_export

    return meter
end

----------------------------------------------------------------------------
-- PM1 polling (Mini PM Gen3 -- power monitor, no relay)
----------------------------------------------------------------------------

local function poll_pm1()
    local meter = {}
    local total_w = 0
    local total_import = 0
    local total_export = 0
	local successful_channels = 0

    for i = 0, channel_count - 1 do
        local data = http_get_json("/rpc/PM1.GetStatus?id=" .. i)
		if data and data.apower ~= nil then
			successful_channels = successful_channels + 1
            local phase_w = data.apower or 0
            total_w = total_w + phase_w

            local phase = i + 1
            if phase == 1 then
                meter.l1_w = phase_w
                meter.l1_v = data.voltage or 0
                meter.l1_a = data.current or 0
            elseif phase == 2 then
                meter.l2_w = phase_w
                meter.l2_v = data.voltage or 0
                meter.l2_a = data.current or 0
            end

            meter.hz = data.freq or meter.hz or 0

            local imp = data.aenergy and data.aenergy.total or 0
            local exp = data.ret_aenergy and data.ret_aenergy.total or 0
            total_import = total_import + imp
            total_export = total_export + exp
        end
    end

	if successful_channels ~= channel_count then return nil end

    meter.w = total_w
    meter.import_wh = total_import
    meter.export_wh = total_export

    return meter
end

----------------------------------------------------------------------------
-- Switch polling (Plus 1PM/2PM, Pro 4PM, Plus Plug S)
----------------------------------------------------------------------------

local function poll_switch()
    local meter = {}
    local total_w = 0
    local total_import = 0
    local total_export = 0
	local successful_channels = 0

    for i = 0, channel_count - 1 do
        local data = http_get_json("/rpc/Switch.GetStatus?id=" .. i)
		if data and data.apower ~= nil then
			successful_channels = successful_channels + 1
            local phase_w = data.apower or 0
            total_w = total_w + phase_w

            -- Map channels to phases (ch0=l1, ch1=l2, ch2=l3)
            local phase = i + 1
            if phase == 1 then
                meter.l1_w = phase_w
                meter.l1_v = data.voltage or 0
                meter.l1_a = data.current or 0
            elseif phase == 2 then
                meter.l2_w = phase_w
                meter.l2_v = data.voltage or 0
                meter.l2_a = data.current or 0
            elseif phase == 3 then
                meter.l3_w = phase_w
                meter.l3_v = data.voltage or 0
                meter.l3_a = data.current or 0
            end

            meter.hz = data.freq or meter.hz or 0

            local imp = data.aenergy and data.aenergy.total or 0
            local exp = data.ret_aenergy and data.ret_aenergy.total or 0
            total_import = total_import + imp
            total_export = total_export + exp
        end
    end

	if successful_channels ~= channel_count then return nil end

    meter.w = total_w
    meter.import_wh = total_import
    meter.export_wh = total_export

    return meter
end

----------------------------------------------------------------------------
-- Driver interface
----------------------------------------------------------------------------

function driver_init(config)
    local port = config.port or 80
    base_url = "http://" .. config.host .. ":" .. port
    host.set_make("Shelly")

    -- Detect device type via GetDeviceInfo
    local info = http_get_json("/rpc/Shelly.GetDeviceInfo")
    if info and info.app then
        local mapping = app_map[info.app]
        if mapping then
            device_type = mapping.type
            channel_count = mapping.channels
            host.log("Shelly detected: " .. info.app .. " -> " .. device_type .. " (" .. channel_count .. " ch)")
            return
        end
    end

    -- Fallback: probe endpoints
    host.log("Shelly app name not recognized, probing endpoints")
    device_type, channel_count = detect_by_probing()
    if device_type then
        host.log("Shelly probed: " .. device_type .. " (" .. channel_count .. " ch)")
    else
        host.log("Shelly: no supported device detected")
    end
end

function driver_poll()
    if not device_type then return 5000 end

    local meter = nil
    if device_type == "em" then
        meter = poll_em()
    elseif device_type == "em1" then
        meter = poll_em1()
    elseif device_type == "pm1" then
        meter = poll_pm1()
    elseif device_type == "switch" then
        meter = poll_switch()
    end

    if meter then
        host.emit("meter", meter)
    end

    return 5000
end

function driver_cleanup()
    base_url = nil
    device_type = nil
    channel_count = 0
end
