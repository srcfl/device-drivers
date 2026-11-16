-- sonnenBatterie — local JSON API v2: telemetry and battery setpoints
-- Emits: battery
-- Protocol: HTTP (local JSON API v2 on the sonnen unit). Enable the JSON API
-- in the sonnen web UI under Software-Integration, which also shows the
-- Auth-Token for config.api_token. Control needs a token with write access.
-- The unit documents the API at http://<unit>/api/doc.html.
--
-- Config example (config.yaml):
--   drivers:
--     - name: sonnen
--       lua: drivers/sonnen.lua
--       capabilities:
--         http:
--           allowed_hosts:
--             - 192.168.x.y     # LAN IP of the sonnen unit
--           allow_write: true   # control only; telemetry works without it
--       config:
--         host: "192.168.x.y"
--         port: 80
--         api_token: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
--         # max_power_w: 4000          # optional owner cap for setpoints
--         # default_operating_mode: "2" # "2" self-consumption (default) or "10" time-of-use
--
-- Sign convention (site: positive W flows INTO the site):
--   battery.w: positive = charging (sink), negative = discharging (source).
--   sonnen reports Pac_total_W positive while DISCHARGING and negative while
--   charging, so the driver negates it. Measured on a sonnenBatterie with
--   software 1.40.5 on 2026-11-13: in manual mode, a 500 W charge setpoint
--   read back over six reads as Pac_total_W -495 to -504 W, SetPoint_W -500
--   and BatteryCharging true.
--
-- Control (measured on the same unit):
--   * Setpoints apply only in manual mode, EM_OperatingMode "1". The mode is
--     changed with PUT /api/v2/configurations; PATCH and POST there return
--     404, so control needs FTW's host.http_put. Without it the driver stays
--     a telemetry driver and refuses commands.
--   * POST /api/v2/setpoint/charge/<W> or /discharge/<W> answers "true".
--   * A manual setpoint holds until it is replaced; no device-side timeout
--     has been observed. The driver therefore owns the safe path:
--       - a lease: without a fresh battery command for LEASE_MS, poll clears
--         the setpoint and returns the unit to its automatic mode;
--       - driver_default_mode does the same, and reads the mode back;
--       - init clears a manual mode left behind by a stopped FTW.
--     None of these run if FTW itself is gone. The HIL gate for that case
--     (host loss with a held setpoint) is still open.

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "sonnen",
  name         = "sonnenBatterie (local API)",
  manufacturer = "sonnen",
  version      = "2.1.0",
  protocols    = { "http" },
  capabilities = { "battery" },
  description  = "sonnenBatterie local JSON API v2: SoC, charge/discharge power and battery setpoints.",
  homepage     = "https://sonnen.de",
  authors      = { "FTW contributors" },
  http_hosts   = { },
  verification_status = "experimental",
  verification_notes = "Sign and manual-mode setpoints measured on one sonnenBatterie (software 1.40.5); control not yet HIL-accepted.",
  connection_defaults = {
    host = "",
    port = 80,
  },
  -- Secret config keys the wizard / Settings UI should render password
  -- inputs for and stuff into config.<key>.
  config_secrets = { "api_token" },
}

PROTOCOL = "http"

local MODE_MANUAL = "1"
local AUTO_MODES  = { ["2"] = true, ["10"] = true }

-- A battery command must be renewed within this window. FTW's control loop
-- dispatches every few seconds; a minute of silence means nobody is steering.
local LEASE_MS = 60000

-- Three failed hand-backs prove the unit will not take them (token without
-- write access, firmware change). The unprompted paths then stop writing;
-- an explicit command still tries, and one success re-arms them.
local DEFAULT_ATTEMPTS = 3

local sonnen_host = ""
local sonnen_port = 80
local api_token   = ""
local owner_max_w = nil

local inverter_max_w = nil  -- IC_InverterMaxPower_w, the unit's own rating
local mode           = nil  -- EM_OperatingMode as last read or written
local auto_mode      = "2"  -- automatic mode to return to; never "1"
local session        = false -- true while this driver holds manual mode
local last_command_ms = 0
local default_failures = 0

local last_attempt = 0
local backoff_ms   = 0
local BACKOFF_MIN  =  2000
local BACKOFF_MAX  = 60000

local function base_url()
    return "http://" .. sonnen_host .. ":" .. tostring(sonnen_port) .. "/api/v2"
end

local function auth()
    return { ["Auth-Token"] = api_token }
end

local function bump_backoff()
    if backoff_ms == 0 then
        backoff_ms = BACKOFF_MIN
    else
        backoff_ms = math.min(backoff_ms * 2, BACKOFF_MAX)
    end
    last_attempt = host.millis()
end

local function clear_backoff()
    backoff_ms   = 0
    last_attempt = 0
end

local function in_backoff()
    if backoff_ms == 0 then return false end
    return (host.millis() - last_attempt) < backoff_ms
end

local function decode(body)
    if body == nil then return nil end
    local ok, data = pcall(host.json_decode, body)
    if not ok then return nil end
    return data
end

-- get_json returns the decoded object, or nil and a reason. An
-- {"error": ...} body (a wrong token answers {"error":"Unauthorized"}) is a
-- failed read, never a reading.
local function get_json(path)
    local ok, body, err = pcall(host.http_get, base_url() .. path, auth())
    if not ok then return nil, tostring(body) end
    if err then return nil, tostring(err) end
    local data = decode(body)
    if type(data) ~= "table" then return nil, "JSON decode failed" end
    if data.error ~= nil then return nil, tostring(data.error) end
    return data
end

-- clamp drops obviously-broken values (NaN, sentinel huge numbers from a
-- partial JSON parse) so a single bad poll doesn't poison the battery
-- model with a 2 GW reading.
local function clamp(v, max_abs)
    local n = tonumber(v)
    if n == nil or n ~= n then return nil end
    if max_abs and math.abs(n) > max_abs then return nil end
    return n
end

-- RFC 3339 time of a latestdata sample: Timestamp is local time and
-- UTC_Offset its whole-hour offset.
local function observed_at(data)
    local ts = data.Timestamp
    local off = tonumber(data.UTC_Offset)
    if type(ts) ~= "string" or off == nil or off ~= math.floor(off) then
        return nil
    end
    local d, t = string.match(ts, "^(%d%d%d%d%-%d%d%-%d%d) (%d%d:%d%d:%d%d)$")
    if not d then return nil end
    local sign = "+"
    if off < 0 then sign = "-" end
    return string.format("%sT%s%s%02d:00", d, t, sign, math.floor(math.abs(off)))
end

local function read_configuration()
    local cfg, err = get_json("/configurations")
    if not cfg then
        return false, err
    end
    local rated = clamp(cfg.IC_InverterMaxPower_w, 100000)
    if rated and rated > 0 then
        if inverter_max_w ~= rated then host.set_rated_w(rated) end
        inverter_max_w = rated
    end
    if cfg.EM_OperatingMode ~= nil then
        mode = tostring(cfg.EM_OperatingMode)
        if AUTO_MODES[mode] then auto_mode = mode end
    end
    if cfg.DE_Software then
        host.set_model("sonnenBatterie " .. tostring(cfg.DE_Software))
    end
    return true
end

-- put_mode switches EM_OperatingMode and checks the unit's echo.
local function put_mode(target)
    if host.http_put == nil then
        return false, "this FTW has no host.http_put; sonnen control needs it"
    end
    local ok, resp, err = pcall(host.http_put, base_url() .. "/configurations",
        "EM_OperatingMode=" .. target,
        { ["Auth-Token"] = api_token,
          ["Content-Type"] = "application/x-www-form-urlencoded" })
    if not ok then err = tostring(resp) end
    if err then
        return false, "operating mode " .. target .. ": " .. tostring(err)
    end
    local data = decode(resp)
    if type(data) ~= "table" or tostring(data.EM_OperatingMode) ~= target then
        return false, "operating mode " .. target .. " not confirmed: " .. tostring(resp)
    end
    mode = target
    return true
end

-- post_setpoint sends a manual setpoint in site convention: +W charges,
-- -W discharges, 0 holds the battery idle.
local function post_setpoint(w)
    local n = math.floor(math.abs(w) + 0.5)
    local dir = "charge"
    if w < 0 then dir = "discharge" end
    local ok, resp, err = pcall(host.http_post,
        base_url() .. "/setpoint/" .. dir .. "/" .. tostring(n), "", auth())
    if not ok then err = tostring(resp) end
    if err then
        return false, dir .. " " .. n .. " W: " .. tostring(err)
    end
    if not string.find(tostring(resp), "true", 1, true) then
        return false, dir .. " " .. n .. " W refused: " .. tostring(resp)
    end
    return true
end

local function power_limit()
    local limit = inverter_max_w
    if owner_max_w and (limit == nil or owner_max_w < limit) then
        limit = owner_max_w
    end
    return limit
end

local function set_battery_power(power_w)
    if host.http_put == nil then
        return "this FTW has no host.http_put; sonnen control needs it"
    end
    local w = tonumber(power_w)
    if w == nil or w ~= w then
        return "battery command needs a numeric power_w"
    end
    if inverter_max_w == nil then
        local ok, err = read_configuration()
        if not ok then return "sonnen configuration unreadable: " .. tostring(err) end
    end
    local limit = power_limit()
    if limit == nil then
        return "sonnen did not report IC_InverterMaxPower_w; refusing an unbounded setpoint"
    end
    if w > limit then w = limit end
    if w < -limit then w = -limit end

    if mode ~= MODE_MANUAL then
        local ok, err = put_mode(MODE_MANUAL)
        if not ok then return err end
    end
    session = true
    last_command_ms = host.millis()
    local ok, err = post_setpoint(w)
    if ok then return true end
    -- The unit may have left manual mode on its own (app, portal, restart).
    -- Re-enter it once and retry before reporting the failure.
    local mode_ok, mode_err = put_mode(MODE_MANUAL)
    if not mode_ok then return mode_err end
    ok, err = post_setpoint(w)
    if ok then return true end
    return err
end

-- restore_auto hands the unit back to its automatic mode. It writes only
-- when the unit is (or may be) in manual mode, and reads the result back.
local function restore_auto_once()
    local read_ok = read_configuration()
    if read_ok and mode ~= MODE_MANUAL then
        session = false
        return true
    end
    if not read_ok and not session and mode ~= MODE_MANUAL then
        -- Unreachable, and nothing says this driver ever took control:
        -- there is nothing to undo, and no state to confirm.
        return false
    end
    -- Clear the setpoint first so a failed mode switch never leaves a
    -- charge or discharge request standing.
    local cleared, clear_err = post_setpoint(0)
    local restored, restore_err = put_mode(auto_mode)
    if not restored then
        host.log("warn", "sonnen: returning to automatic mode failed: " .. tostring(restore_err))
        return false
    end
    if not cleared then
        host.log("warn", "sonnen: clearing the setpoint failed: " .. tostring(clear_err))
    end
    if read_configuration() and mode ~= auto_mode then
        host.log("warn", "sonnen: unit reports mode " .. tostring(mode)
            .. " after restoring " .. auto_mode)
        return false
    end
    session = false
    host.log("info", "sonnen: returned to automatic mode " .. auto_mode)
    return true
end

local function restore_auto()
    if restore_auto_once() then
        default_failures = 0
        return true
    end
    default_failures = default_failures + 1
    return false
end

----------------------------------------------------------------------------
-- Driver interface
----------------------------------------------------------------------------

function driver_init(config)
    host.set_make("sonnen")

    if config then
        if type(config.host) == "string" and config.host ~= "" then
            sonnen_host = config.host
        end
        if config.port then
            sonnen_port = tonumber(config.port) or 80
        end
        if type(config.api_token) == "string" and config.api_token ~= "" then
            api_token = config.api_token
        end
        local cap = tonumber(config.max_power_w)
        if cap and cap > 0 then owner_max_w = cap end
        local dm = config.default_operating_mode
        if dm ~= nil and AUTO_MODES[tostring(dm)] then
            auto_mode = tostring(dm)
        end
    end

    if sonnen_host == "" then
        host.log("error", "sonnen: config.host required (LAN IP of the sonnen unit)")
        return
    end
    if api_token == "" then
        host.log("warn", "sonnen: config.api_token is empty — JSON API v2 requires an Auth-Token; enable it in the sonnen web UI under Software-Integration")
    end

    local ok, err = read_configuration()
    if not ok then
        host.log("warn", "sonnen: reading configurations failed: " .. tostring(err))
    elseif mode == MODE_MANUAL and host.http_put ~= nil then
        -- Manual mode with nobody steering: a previous FTW stopped while it
        -- held a setpoint. Hand the unit back before anything else.
        host.log("warn", "sonnen: unit is in manual mode at start; restoring automatic mode " .. auto_mode)
        restore_auto()
    end

    host.log("info", "sonnen: driver initialized (host=" .. sonnen_host
        .. ":" .. tostring(sonnen_port) .. ", mode=" .. tostring(mode) .. ")")
end

function driver_poll()
    if sonnen_host == "" then
        return 10000
    end
    if in_backoff() then
        return 1000
    end

    local data, err = get_json("/latestdata")
    if not data then
        bump_backoff()
        host.log("warn", "sonnen: fetch failed: " .. tostring(err)
            .. " (retry in " .. backoff_ms .. "ms)")
        return 1000
    end
    clear_backoff()

    local pac_w   = clamp(data.Pac_total_W,   30000)
    if pac_w == nil then
        host.log("warn", "sonnen: latestdata has no usable Pac_total_W")
        return 1000
    end
    local rsoc    = clamp(data.RSOC,            100)
    -- USOC is the user-visible SoC the unit clamps usable energy against;
    -- prefer it over RSOC (raw SoC) so the EMS sees the same headroom the
    -- sonnen will actually deliver / accept.
    local usoc    = clamp(data.USOC,            100)
    local prod_w  = clamp(data.Production_W,  30000) or 0
    local cons_w  = clamp(data.Consumption_W, 30000) or 0
    local cap_wh  = clamp(data.FullChargeCapacity, 1000000)
    local set_w   = clamp(data.SetPoint_W,    30000)
    local seen_at = observed_at(data)

    local soc_pct = usoc or rsoc or 0
    local battery = {
        w   = -pac_w,  -- sonnen: + = discharge; site: + = charge
        soc = soc_pct / 100.0,
        control_power_w = -pac_w,
        control_power_available = seen_at ~= nil,
    }
    if seen_at then
        battery.control_power_observed_at = seen_at
    end
    if set_w then
        battery.setpoint_w = -set_w
    end
    if cap_wh then
        battery.capacity_wh = cap_wh
    end
    host.emit("battery", battery)

    host.emit_metric("battery_rsoc",          rsoc or 0)
    host.emit_metric("battery_usoc",          usoc or 0)
    host.emit_metric("battery_pac_w",         pac_w)   -- vendor sign
    host.emit_metric("battery_production_w",  prod_w)
    host.emit_metric("battery_consumption_w", cons_w)
    if cap_wh then
        host.emit_metric("battery_capacity_wh", cap_wh)
    end

    -- The lease: a held setpoint nobody renews goes back to the unit.
    if session and host.millis() - last_command_ms > LEASE_MS
       and default_failures < DEFAULT_ATTEMPTS then
        host.log("info", "sonnen: no battery command for "
            .. math.floor(LEASE_MS / 1000) .. " s; returning to automatic mode")
        restore_auto()
    end

    return 1000
end

function driver_command(action, power_w, cmd)
    if sonnen_host == "" then
        return "sonnen: config.host is not set"
    end
    if action == "init" then
        return true
    elseif action == "battery" then
        return set_battery_power(power_w)
    elseif action == "deinit" then
        if restore_auto() then return true end
        return "sonnen: could not return to automatic mode"
    end
    return "unsupported action: " .. tostring(action)
end

function driver_default_mode()
    if sonnen_host == "" or host.http_put == nil then
        return true
    end
    if default_failures >= DEFAULT_ATTEMPTS then
        -- The unit has refused every write; repeating them on each watchdog
        -- tick only floods the log. Report the default as held.
        return true
    end
    return restore_auto()
end

function driver_cleanup()
    clear_backoff()
end
