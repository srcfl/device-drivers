-- Easee Cloud EV Charger Driver
-- Emits: EV
-- Protocol: HTTPS (Easee Cloud REST API), optional SignalR stream
--
-- Authenticates with the user's Easee account (email + password from
-- config), reads charger state and emits DerEV readings so the dispatch
-- clamp keeps home batteries from feeding the car. With a WebSocket grant
-- it reads Easee's SignalR stream and asks REST once a minute; without
-- one it polls REST every 5 seconds. Commands always go through REST.
--
-- Config example:
--   drivers:
--     - name: easee
--       lua: drivers/easee_cloud.lua
--       capabilities:
--         http:
--           allowed_hosts: ["api.easee.com"]
--         websocket:                    # enables the stream on a Core that
--           allowed_hosts: ["streams.easee.com"]  # does not read ws_hosts
--       config:
--         email: "user@example.com"
--         password: "secret"
--         serial: "EHHZBKPF"    # optional — auto-detected if omitted
--         start_boost: false    # optional — disable the 7 A start for 6 A orders

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "easee_cloud",
  name         = "Easee Cloud",
  manufacturer = "Easee",
  version      = "1.5.0",
  protocols    = { "http" },
  capabilities = { "ev" },
  description  = "Easee Home/Charge via Cloud REST API. No local protocol needed.",
  homepage     = "https://easee.com",
  http_hosts   = { "api.easee.com" },
  ws_hosts     = { "streams.easee.com" },
  authors      = { "FTW contributors" },
  tested_models = { "Home", "Charge" },
  verification_status = "production",
  verified_by = { "frahlg@homelab-rpi:2d", "erikarenhill@fortytwo:1d" },
  verified_at = "2026-04-18",
  verification_notes = "Observations API + lifecycle commands exercised against an Easee Home charger. Session state, op_mode labels, charge/pause/resume all verified.",
  config_secrets = { "password" },
}

PROTOCOL = "http"

local BASE_URL = "https://api.easee.com/api"
local access_token = nil
local refresh_token = nil
local token_expires_at = 0   -- millis
local charger_serial = nil
local phases = 3   -- populated from config.phases (if present) in driver_init
local last_sent_phases = nil   -- tracks the last phaseMode posted to Easee
local last_phase_change_ms = 0 -- monotonic ms of the last phase flip (hysteresis)

-- After every phaseMode change, Easee resets dynamicChargerCurrent to
-- the static maxChargerCurrent value (16 A on a typical 16 A install).
-- That resets sticks for ~5–10 s on the cloud side before our follow-
-- up dynamicChargerCurrent write propagates back. To bound that
-- window, we (a) re-write dynamicChargerCurrent on the next driver_poll
-- after a phaseMode change, and (b) clamp maxChargerCurrent at init
-- when an operator config field requests it (see driver_init below).
local pending_amp_resend = false
local pending_amp_resend_at_ms = 0
local last_amps_set = nil

-- paused_state tracks whether the LAST command we successfully sent was
-- ev_pause. Easee's REST API has no way to query "are you currently
-- in user-pause" — op_mode 2 ("awaiting start") covers both "paused"
-- and "plugged in but car hasn't started a session yet". Without this
-- flag, after a controller pause + re-offer, we'd write
-- dynamicChargerCurrent=6 successfully but the contactor stays open
-- because we never sent resume_charging. We saw this in the field as
-- "easee_a=6, easee_chg=false, ev_w=0, reason=100/52" stuck states.
local paused_state = false

-- command_stalled_since_ms tracks when we last wrote a non-zero amps
-- offer that did NOT translate into actual charging. Used to surface
-- a derived diagnostic for the controller / UI so a stuck Easee
-- (firmware error, EV-side reject) is observable rather than silent.
local command_stalled_since_ms = 0

-- Easee charger physical limits. These are the manufacturer's hard
-- bounds, not operator preferences — `dynamicChargerCurrent` written
-- below the minimum is silently rejected by the unit (returns success
-- but no current actually flows), and above the max the cloud returns
-- a 4xx. The min applies when amps > 0; commanding exactly 0 always
-- pauses cleanly.
local EASEE_MIN_A = 6
local EASEE_MAX_A = 32

-- 6 A start boost. Field data (22 Oct 2026, Easee Home + Audi e-tron, 3Φ,
-- four runs): after resume_charging with dynamicChargerCurrent=6 the
-- charger reported a positive pilot only 5 min 2 s – 5 min 47 s later, even
-- with a single resume. Starting at 7 A and lowering to 6 A once the car
-- drew current started at once. evcc reports the same ~5 min firmware
-- delay and clamps the dynamic current to 7 A before its start command.
-- Here the boost is one amp per phase, held only until the charger reports
-- charging (op_mode 3) or START_BOOST_MAX_MS passes, then 6 A. It is only
-- used when 7 A fits (start_boost_fits), after a poll has seen the charger
-- not charging, and at most once per start. `start_boost: false` disables it.
local START_BOOST_A = EASEE_MIN_A + 1
local START_BOOST_MAX_MS = 90000
local start_boost_enabled = true
local boost_until_ms = nil     -- non-nil while 7 A is offered for a 6 A order
local boost_spent = false      -- one boost per start; reset by a 0 A order or a stop
local last_op_mode = nil       -- op_mode from the latest successful poll; nil before the first

-- pick_phases is the driver-level phase decision: given the requested
-- charging power, the per-phase fuse ceiling, the operator's mode
-- preference, and the time since the last flip, return how many
-- phases (1 or 3) to actually commit to this command.
--
--   * mode "1p" / "3p": locked, no hysteresis
--   * mode "auto" or empty + missing fuse data: legacy 3Φ fallback
--     (preserves pre-switching behaviour for sites that don't pass
--     fuse data in the cmd)
--   * mode "auto" with fuse data: pick 1Φ while wantW is below both
--     the configured split and the first deliverable 3Φ step. This
--     avoids the physical dead zone between a 16 A 1Φ ceiling
--     (3.68 kW at 230 V) and Easee's 6 A/phase 3Φ minimum (4.14 kW):
--     the 1Φ command saturates safely instead of a 3Φ command mapping
--     to 0 A. Hysteresis suppresses
--     a flip when less than `hold_s` seconds have passed since the
--     last change — Easee's contactor + cloud-API round-trip is
--     ~5-10 s, so flapping at every controller tick would burn the
--     contactor and never deliver useful power.
local function pick_phases(mode, want_w, voltage, max_a_per_phase, split_w, hold_s, now_ms)
    local locked = mode
    if locked == "1p" then return 1 end
    if locked ~= "auto" then return 3 end -- "" / "3p" / unknown

    -- Effective split: operator override → site fuse → 230 V × 16 A default.
    local s = split_w
    if (s == nil) or (s <= 0) then
        if voltage and voltage > 0 and max_a_per_phase and max_a_per_phase > 0 then
            s = voltage * max_a_per_phase
        else
            s = 3680
        end
    end

    -- Never switch to 3Φ before Easee can deliver its minimum current
    -- on every phase. A lower phase_split_w (explicit or fuse-derived)
    -- would otherwise turn e.g. 3.6–4.0 kW into 5 A/phase, which
    -- per_phase_amps must correctly pause as 0 A. Staying on 1Φ may
    -- saturate at the fuse ceiling for this narrow band, but it keeps
    -- useful current flowing without exceeding the installation limit.
    local v = (voltage and voltage > 0) and voltage or 230
    local min_3p_w = v * 3 * EASEE_MIN_A
    if s < min_3p_w then s = min_3p_w end

    local desired = (want_w < s) and 1 or 3

    -- Hysteresis: once we've committed to a phase count, hold it for
    -- at least `hold_s` seconds before flipping the other way.
    if last_sent_phases == nil then
        return desired
    end
    if desired == last_sent_phases then
        return desired
    end
    -- Default hold = 90 s. Field-measured against an Easee Home: a full
    -- phaseMode flip + EV ramp to steady state takes 60–90 s; a 60 s
    -- hold could let a flap-prone wantW trigger another transition
    -- mid-ramp. 90 s gives one full ramp cycle before another flip.
    local hold = (hold_s and hold_s > 0) and hold_s or 90
    if (now_ms - last_phase_change_ms) < (hold * 1000) then
        return last_sent_phases
    end
    return desired
end

-- per_phase_amps converts the requested W into the dynamicChargerCurrent
-- value Easee expects. Voltage and per-phase fuse ceiling come from
-- the cmd (controller-supplied) so a 240 V or 220 V mains is handled
-- without hard-coding 230. The result is rounded (not floored) and
-- clamped to [0, EASEE_MAX_A] AND to the per-phase fuse ceiling so
-- the breaker stays safe even if the controller sent a value above
-- what the fuse tolerates.
local function per_phase_amps(power_w, voltage, p, max_a_per_phase)
    local v = (voltage and voltage > 0) and voltage or 230
    local raw = ((power_w or 0) / v / p) + 0.5
    local amps = math.floor(raw)
    if amps < 0 then amps = 0 end
    if amps > EASEE_MAX_A then amps = EASEE_MAX_A end
    if max_a_per_phase and max_a_per_phase > 0 and amps > max_a_per_phase then
        amps = math.floor(max_a_per_phase) -- never breach the fuse
    end
    -- Below Easee's hardware minimum, pause cleanly instead of leaving
    -- the charger in "I requested 4 A but nothing flows" limbo.
    if amps > 0 and amps < EASEE_MIN_A then amps = 0 end
    return amps
end

-- Easee error bodies have historically echoed submitted form data
-- (credentials, tokens). Strip the body and keep only the status prefix
-- so nothing sensitive ever lands in the driver log.
local function redact_http_err(err)
    if err == nil then return "request failed" end
    return tostring(err):match("^(HTTP %d+)") or "request failed"
end

-- Wrapped transport. A host whose http_get raises, or a vendor API
-- that answers with garbage, must degrade to (nil, err) — never kill
-- the driver mid-poll.
local function safe_http_get(url, headers)
    local ok, resp, err = pcall(host.http_get, url, headers)
    if not ok then return nil, tostring(resp) end
    return resp, err
end

local function safe_json_decode(s)
    if s == nil then return nil end
    local ok, data = pcall(host.json_decode, s)
    if not ok then return nil end
    return data
end

-- ---- Auth helpers ----

local function login(email, password)
    local body = host.json_encode({userName = email, password = password})
    local resp, err = host.http_post(BASE_URL .. "/accounts/login", body)
    if err then
        host.log("error", "Easee login failed: " .. redact_http_err(err))
        return false
    end
    local data = safe_json_decode(resp)
    if not data or not data.accessToken then
        host.log("error", "Easee login: no accessToken in response")
        return false
    end
    access_token = data.accessToken
    refresh_token = data.refreshToken
    -- expiresIn is seconds; convert to absolute millis
    local expires_in = data.expiresIn or 3600
    token_expires_at = host.millis() + (expires_in * 1000) - 60000 -- refresh 1 min early
    host.log("info", "Easee: logged in, token expires in " .. expires_in .. "s")
    return true
end

local function do_refresh()
    if not access_token or not refresh_token then return false end
    local body = host.json_encode({
        accessToken = access_token,
        refreshToken = refresh_token
    })
    local resp, err = host.http_post(BASE_URL .. "/accounts/refresh_token", body)
    if err then
        host.log("warn", "Easee token refresh failed: " .. redact_http_err(err))
        return false
    end
    local data = safe_json_decode(resp)
    if not data or not data.accessToken then
        host.log("warn", "Easee refresh: no accessToken, will re-login")
        return false
    end
    access_token = data.accessToken
    refresh_token = data.refreshToken
    local expires_in = data.expiresIn or 3600
    token_expires_at = host.millis() + (expires_in * 1000) - 60000
    host.log("debug", "Easee: token refreshed")
    return true
end

local function ensure_auth(email, password)
    if access_token and host.millis() < token_expires_at then
        return true
    end
    -- Try refresh first, fall back to full login
    if access_token and do_refresh() then
        return true
    end
    return login(email, password)
end

local function auth_headers()
    return {Authorization = "Bearer " .. (access_token or "")}
end

-- ---- API helpers ----

local function get_chargers()
    local resp, err = safe_http_get(BASE_URL .. "/chargers", auth_headers())
    if err then return nil, err end
    return safe_json_decode(resp), nil
end

-- Observation IDs (from developer.easee.com/docs/charger-observation-ids)
local OBS_DYN_CURRENT     = 48
local OBS_ALLOCATED_L1    = 70   -- circuit total allocated current L1; L2 71, L3 72
local OBS_REASON_NO_CUR   = 96
local OBS_CABLE_LOCKED    = 103
local OBS_OP_MODE         = 109
local OBS_OUTPUT_CURRENT  = 114  -- current signalled to the car with the pilot
local OBS_TOTAL_POWER     = 120
local OBS_SESSION_ENERGY  = 121
local OBS_LIFETIME_ENERGY = 124
local OBS_CURRENT         = 183
local OBS_VOLTAGE         = 194
local OBS_SESSION_START   = 223

local OBS_IDS = "48,70,71,72,96,103,109,114,120,121,124,183,194,223"
local OBS_WANTED = {}
for id in OBS_IDS:gmatch("%d+") do OBS_WANTED[tonumber(id)] = true end

-- The latest value and source time of each observation, from REST and the
-- stream alike. Easee records an observation when it changes, so a value
-- stays current until a newer one arrives.
local latest, latest_at, latest_pushed = {}, {}, {}

-- source_time_key makes an RFC 3339 time comparable as a string: seconds
-- since 1970 and nine fractional digits, whatever the offset and precision,
-- so "…03:49:08.1Z" and "…05:49:08.1000000+02:00" give the same key. A time
-- that is not RFC 3339, or names a day that does not exist, gives nil.
-- Written by Segran for srcfl/device-drivers#183.
local function source_time_key(stamp)
    if type(stamp) ~= "string" then return nil end
    local year, month, day, hour, minute, second, suffix = stamp:match(
        "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$")
    if not year then return nil end
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    hour, minute, second = tonumber(hour), tonumber(minute), tonumber(second)
    if year < 1970 or month < 1 or month > 12 or hour > 23 or minute > 59 or second > 59 then return nil end
    local leap = year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
    local lengths = {31, leap and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
    if day < 1 or day > lengths[month] then return nil end
    local fraction = ""
    if suffix:sub(1, 1) == "." then
        local digits, zone = suffix:match("^%.(%d+)(.*)$")
        if not digits or #digits > 9 then return nil end
        fraction, suffix = digits, zone
    end
    local offset = 0
    if suffix ~= "Z" then
        local sign, oh, om = suffix:match("^([+-])(%d%d):(%d%d)$")
        if not sign then return nil end
        oh, om = tonumber(oh), tonumber(om)
        if oh > 23 or om > 59 then return nil end
        offset = (oh * 60 + om) * 60 * (sign == "+" and 1 or -1)
    end
    local function leaps(y)
        return math.floor(y / 4) - math.floor(y / 100) + math.floor(y / 400)
    end
    local days = 365 * (year - 1970) + leaps(year - 1) - leaps(1969) + day - 1
    for m = 1, month - 1 do days = days + lengths[m] end
    local seconds = days * 86400 + hour * 3600 + minute * 60 + second - offset
    if seconds < 0 then return nil end
    return string.format("%012d", seconds) .. "." .. fraction .. string.rep("0", 9 - #fraction)
end

-- note_observation records a sample. SignalR delivers one connection's
-- messages in order, so a pushed sample always applies. A REST reply can be
-- older than what the stream pushed since, cached before the change; then it
-- does not apply. Otherwise REST applies as it always has, so one bad stamp
-- cannot hold a value. The same instant keeps its first spelling, so a
-- source time never looks new because the other source wrote it
-- differently. Returns true when REST brought a newer, different value.
local observation_confirmed_ms, observation_confirmed_wall_ms = {}, {}

local function note_observation(id, value, at, pushed)
    if not OBS_WANTED[id] then return false end
    local new_key, old_key = source_time_key(at), source_time_key(latest_at[id])
    local newer = false
    if new_key and old_key then
        if not pushed and latest_pushed[id] and new_key < old_key then return false end
        if new_key == old_key then at = latest_at[id] end
        newer = new_key > old_key
    end
    local changed = value ~= latest[id]
    latest[id], latest_at[id], latest_pushed[id] = value, at, pushed
    observation_confirmed_ms[id] = host.millis()
    observation_confirmed_wall_ms[id] = host.unix_ms and host.unix_ms() or nil
    return not pushed and newer and changed
end

-- REST sends JSON numbers and booleans. The stream sends every value as a
-- string: "The value is always transmitted as a string, regardless of the
-- underlying data type" (developer.easee.com/docs/signalr-stream).
local function observation_value(value)
    if type(value) ~= "string" then return value end
    local word = value:lower()
    if word == "true" then return true end
    if word == "false" then return false end
    return tonumber(value) or value
end

local last_power_observed_at = nil
local validated_session_id = nil
local observed_session_id = nil
local departed_session_id = nil
local session_lookups_ms = {}
local last_session_lookup_ms = nil
local last_session_mode = nil

local function invalidate_session_proof()
    -- An unreadable charger may have changed cars during the gap. Keep the
    -- gap unknown, but require fresh proof when observations return.
    validated_session_id = nil
    observed_session_id = nil
    last_session_mode = nil
end

-- state_problem says why a set of observations cannot be reported. op_mode 0
-- is Easee's sign that the cloud no longer hears from the charger.
local function state_problem(obs)
    local mode = obs[OBS_OP_MODE]
    if type(mode) ~= "number" or mode < 0 or mode > 6 or mode % 1 ~= 0 then
        return "missing charger state"
    end
    if mode == 0 then
        return "charger offline; connection unknown"
    end
    if mode >= 2 and (type(obs[OBS_TOTAL_POWER]) ~= "number" or
       type(obs[OBS_SESSION_ENERGY]) ~= "number" or obs[OBS_SESSION_ENERGY] < 0) then
        return "missing session measurement"
    end
    return nil
end

-- REST can answer from an older cache after a newer reply: a late reply once
-- turned a measured 10.242 kW into 0 W (srcfl/device-drivers#183). A REST
-- reply is not used when its power time goes back from the last one used,
-- gives another value at the same instant, or, while a car is connected,
-- cannot be read. Such replies one after another for UNORDERED_RESET_MS
-- mean the time itself is wrong, for example a stamp from the future or a
-- format this parser does not know, so the driver uses them rather than go
-- silent: an older time starts the order again, and unreadable ones are
-- used as they come until a readable time arrives. A disconnect starts the
-- order again too. A run of rejected replies ends after a gap of more than
-- UNORDERED_RESET_MS between them, such as an outage.
local UNORDERED_RESET_MS = 30000
local accepted_power_key, accepted_power_value = nil, nil
local unordered_since_ms, unordered_last_ms, unreadable_logged = nil, nil, false
local function power_order_problem(obs, stamps, now)
    local value, key = obs[OBS_TOTAL_POWER], source_time_key(stamps[OBS_TOTAL_POWER])
    local disconnected = obs[OBS_OP_MODE] == 1
    local problem = nil
    if not key then
        if not disconnected then problem = "missing or invalid power source timestamp" end
    elseif accepted_power_key and key < accepted_power_key then
        problem = "out-of-order power observation"
    elseif key == accepted_power_key and value ~= accepted_power_value then
        problem = "conflicting power at one source timestamp"
    end
    if problem then
        if not unordered_since_ms or now - unordered_last_ms > UNORDERED_RESET_MS then
            unordered_since_ms = now
        end
        unordered_last_ms = now
        if now - unordered_since_ms < UNORDERED_RESET_MS then return problem end
        if not key then
            if not unreadable_logged then
                host.log("warn", "Easee: power times unreadable for 30 s; using replies as they come")
            end
            unreadable_logged = true
            return nil
        end
        host.log("warn", "Easee: power times went back for 30 s; using the newest reply")
    end
    unordered_since_ms, unreadable_logged = nil, false
    if disconnected then
        accepted_power_key, accepted_power_value = nil, nil
    else
        accepted_power_key, accepted_power_value = key, value
    end
    return nil
end

-- get_observations reads REST. The caller checks the reply with state_problem
-- and power_order_problem.
local function get_observations(serial)
    local url = "https://api.easee.com/state/" .. serial .. "/observations?ids=" .. OBS_IDS
    local resp, err = safe_http_get(url, auth_headers())
    if err then return nil, err end
    local decoded = safe_json_decode(resp)
    if type(decoded) ~= "table" then return nil, "decode failed" end
    local list = decoded.observations or decoded
    local obs = {}
    local timestamps = {}
    for _, item in ipairs(list) do
        if item.id then
            obs[item.id] = observation_value(item.value)
            timestamps[item.id] = item.timestamp
        end
    end
    return obs, nil, timestamps
end

-- Match observation 223 to the vendor's current-session endpoint. sessionEnd
-- can be populated while a car is merely paused; it is not cable-disconnect
-- proof (confirmed on hardware, 2026-09-13). Mode 4 also means the car paused
-- or stopped drawing. Keep the same identity until disconnect or a new ID.
-- https://developer.easee.com/reference/chargers_getongoingsessiondetails
-- https://developer.easee.com/docs/api-command-and-control
local function normalized_session_start(value)
    if type(value) ~= "string" or
       not value:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d") then return nil end
    return (value:gsub("%+00:00$", "Z"):gsub("%.0+Z$", "Z"))
end

local function current_session_id(obs, op_mode)
    local began_charging = op_mode == 3 and last_session_mode ~= 3
    last_session_mode = op_mode
    if op_mode == 0 or op_mode == 1 then
        if op_mode == 1 then departed_session_id = observed_session_id or departed_session_id end
        validated_session_id = nil
        observed_session_id = nil
        return nil
    end
    local raw = obs[OBS_SESSION_START]
    local session = type(raw) == "table" and raw or nil
    if type(raw) == "string" then session = safe_json_decode(raw) end
    if type(session) ~= "table" then return nil end
    local id = tonumber(session.Id)
    local start = normalized_session_start(session.Start)
    if not id or id <= 0 or id % 1 ~= 0 or not start then return nil end
    local identity = string.format("%.0f", id) .. ":" .. start
    if identity == departed_session_id then return nil end
    local identity_changed = identity ~= observed_session_id
    if identity_changed then
        observed_session_id = identity
        validated_session_id = nil
    end
    if validated_session_id == identity then return identity end
    -- A pause is still an open session. Ask the ongoing-session endpoint
    -- before restoring its identity; observation 223 alone may be historical.

    -- The vendor allows ten requests per hour, not one per normal poll.
    local now = host.millis()
    local recent = {}
    for _, at in ipairs(session_lookups_ms) do
        if now - at < 3600000 then table.insert(recent, at) end
    end
    session_lookups_ms = recent
    -- Spread failed retries across the hour. A new session or a transition to
    -- charging may try sooner, while retaining the minute and hourly limits.
    local retry_ms = (identity_changed or began_charging) and 60000 or 360000
    if #recent >= 10 or (last_session_lookup_ms and now - last_session_lookup_ms < retry_ms) then
        return nil
    end
    last_session_lookup_ms = now
    table.insert(session_lookups_ms, now)
    local body, err = safe_http_get(BASE_URL .. "/chargers/" .. charger_serial .. "/sessions/ongoing", auth_headers())
    if err then return nil end
    local ongoing = safe_json_decode(body)
    if type(ongoing) ~= "table" or tonumber(ongoing.sessionId) ~= id or
       normalized_session_start(ongoing.sessionStart) ~= start then return nil end
    validated_session_id = identity
    return identity
end

-- ---- SignalR stream ----
-- Easee pushes every observation change over SignalR and recommends it for
-- reads, with REST for commands (support reply, 24 Oct 2026). REST polling
-- every 5 s costs about 720 requests an hour per charger.
--   https://developer.easee.com/docs/signalr-stream — hub, the
--     SubscribeWithCurrentState(serial, true) call, ProductUpdate messages
--     {mid, dataType, id, timestamp, value}
--   https://developer.easee.com/docs/api-and-streaming
--   https://developer.easee.com/changelog/signalr-uri-change — the hub moved
--     from api.easee.cloud/hubs to streams.easee.com/hubs
-- The wire format is Microsoft's SignalR JSON hub protocol over WebSockets:
--   https://github.com/dotnet/aspnetcore/blob/main/src/SignalR/docs/specs/TransportProtocols.md
--   https://github.com/dotnet/aspnetcore/blob/main/src/SignalR/docs/specs/HubProtocol.md
-- Open wss://{hub} with the access token, send {"protocol":"json","version":1};
-- then each JSON message ends with the 0x1E record separator. Message types
-- used here: 1 invocation, 3 completion, 6 ping, 7 close.
--
-- The driver skips POST {hub}/negotiate. Its connectionToken is required
-- only by the long polling and server-sent events transports
-- (TransportProtocols.md); a WebSocket without one starts a new connection
-- (HttpConnectionDispatcher.GetOrCreateConnectionAsync). Easee's hub runs on
-- Kestrel behind an AWS load balancer that pins a client to a server with a
-- cookie (AWSALB, seen 24 Oct 2026). The host's HTTP and WebSocket clients
-- share no cookies, so a negotiated token could reach a server that does not
-- know it. Skipping it also makes connecting one network call, which the
-- host bounds; the poll and any command wait behind it.
--
-- The stream cannot say that the cloud lost the charger (REST's op_mode 0),
-- so REST still reads once a minute while the stream is up, and the driver
-- reports only what a REST read in the last 90 s vouches for. A connected
-- stream can also stop delivering. When a REST read shows a change the
-- stream has not pushed, the stream owes it: if it does not arrive within
-- 10 s, the stream stops and REST takes over.
--
-- Core grants the WebSocket from ws_hosts in the DRIVER table (srcfl/ftw#1822)
-- or, on a Core that does not read it, from capabilities.websocket in the
-- driver config. Without a grant the driver polls REST as before.
local STREAM_WS = "wss://streams.easee.com/hubs/products"
local RS = "\30"
local STREAM_POLL_MS = 2000      -- poll cadence while streaming; Core's control loop ticks every 2 s
local STREAM_PING_MS = 15000     -- a SignalR server drops a client silent for 30 s by default
local STREAM_SILENT_MS = 60000   -- the server pings every 15 s; a minute of nothing is a dead stream
local STREAM_OPEN_MS = 30000     -- handshake and subscription must finish within this
local STREAM_OWED_MS = 10000     -- how long a change REST saw may wait for the stream
local REST_CONFIRM_MS = 60000    -- REST cadence while the stream is up
local REST_FRESH_MS = 90000      -- how long a REST read vouches that the cloud hears the charger

local stream_state = "off"       -- off, handshake, subscribe, up; disabled without a grant
local stream_buf = ""
local stream_token = nil         -- the access token the open stream signed in with
local stream_opened_ms, stream_up_ms, stream_rx_ms, stream_tx_ms = 0, 0, 0, 0
local stream_retry_ms = 0
local stream_failures = 0
local stream_owed = nil          -- {id, key, value, since, why}: a reading the stream has not delivered
local rest_next_ms = 0           -- streaming only: when REST reads next
local heard_ms = nil             -- when REST last showed the cloud hears the charger
local last_blocked = nil         -- why the streamed state was last not reportable, for the log

local function stream_send(text, now)
    local ok, sent, err = pcall(host.ws_send, text .. RS)
    if ok and sent then
        stream_tx_ms = now
        return true
    end
    return false, ok and err or sent
end

-- stream_stop closes the stream and schedules the next try. A planned stop
-- reconnects at once. Failures back off from 5 s to 5 min; a REST read that
-- finds the stream complete starts the count again.
local function stream_stop(why, now, planned)
    pcall(host.ws_close)
    stream_owed = nil
    if planned then
        stream_retry_ms = now
    else
        stream_failures = stream_failures + 1
        local wait = math.min(5000 * 2 ^ (stream_failures - 1), 300000)
        stream_retry_ms = now + wait
        if stream_state == "up" then
            host.log("warn", "Easee: SignalR stream down (" .. why .. "); REST every 5 s until it is back")
        else
            host.log("warn", string.format("Easee: SignalR stream failed (%s); retry in %d s",
                why, math.floor(wait / 1000)))
        end
    end
    stream_state, stream_buf, stream_token = "off", "", nil
end

-- A missing grant is configuration, not an outage: stop trying until restart.
local function stream_disable(why)
    pcall(host.ws_close)
    stream_state = "disabled"
    host.log("info", "Easee: no SignalR stream (" .. why .. "); REST every 5 s. Streaming needs " ..
        "WebSocket access to streams.easee.com: ws_hosts on a Core that reads it, or " ..
        "capabilities.websocket in the driver config.")
end

-- Server text goes into the log; keep it short.
local function brief(text)
    return tostring(text):sub(1, 120)
end

local function not_granted(err)
    local text = tostring(err)
    return text:find("capability not granted", 1, true) or text:find("not in allowed_hosts", 1, true)
end

-- Keep only the status of an HTTP error and drop any query from the text.
local function host_err(err)
    local text = tostring(err)
    return text:match("^(HTTP %d+)") or brief(text:gsub("%?[^%s\"']*", ""))
end

-- stream_open runs on the poll and waits for the WebSocket dial, which the
-- host bounds (5 s from srcfl/ftw#1822, 15 s before), so it reads the clock
-- again before it schedules anything.
local function stream_open(now)
    if type(host.ws_open) ~= "function" then return stream_disable("host has no WebSocket") end
    local ok, opened, oerr = pcall(host.ws_open, STREAM_WS, auth_headers())
    now = host.millis()
    if not ok or not opened then
        local why = ok and oerr or opened
        if not_granted(why) then return stream_disable("no WebSocket grant") end
        return stream_stop("open: " .. host_err(why), now)
    end
    stream_state, stream_buf, stream_token, stream_owed = "handshake", "", access_token, nil
    stream_opened_ms, stream_rx_ms = now, now
    local sent, serr = stream_send('{"protocol":"json","version":1}', now)
    if not sent then return stream_stop("handshake: " .. tostring(serr), now) end
end

-- Only state, power and energy are owed: what Core needs to report and
-- control. Diagnostic readings may change without a push.
local function owed_kind(id)
    return id == OBS_OP_MODE or id == OBS_TOTAL_POWER or id == OBS_SESSION_ENERGY
end

local function owe(id, key, value, now, why)
    if not stream_owed then
        stream_owed = { id = id, key = key, value = value, since = now, why = why }
    end
end

-- stream_update records a pushed sample. One Core could not read, with a
-- time that is not RFC 3339, is skipped, and so is a state, power or
-- energy reading that is not a number; the stream then owes that reading.
-- Before the subscription completes the stream replays its current state,
-- which can be older than a REST read just before it; the newer one stays.
local function stream_update(id, value, at, now)
    if not OBS_WANTED[id] then return end
    local key = source_time_key(at)
    if not key or (owed_kind(id) and type(value) ~= "number") then
        if owed_kind(id) then owe(id, "", nil, now, "sent a reading it cannot use") end
        return
    end
    local held = source_time_key(latest_at[id])
    if stream_state ~= "up" and held and key < held then return end
    note_observation(id, value, at, true)
    if stream_owed and stream_owed.id == id and (key >= stream_owed.key or value == stream_owed.value) then
        stream_owed = nil
    end
end

-- stream_message handles one SignalR message and returns a reason to stop.
local function stream_message(text, now)
    local m = safe_json_decode(text)
    if type(m) ~= "table" then return "unreadable message" end
    if stream_state == "handshake" then
        -- The first message answers the handshake: {} or {"error": "..."}.
        if m.error ~= nil then return "handshake refused: " .. brief(m.error) end
        stream_state = "subscribe"
        local sent, err = stream_send(host.json_encode({
            type = 1, invocationId = "0", target = "SubscribeWithCurrentState",
            -- Easee serials are upper case; a config may not be.
            arguments = { charger_serial:upper(), true },
        }), now)
        if not sent then return "subscribe: " .. tostring(err) end
    elseif m.type == 1 and m.target == "ProductUpdate" and type(m.arguments) == "table" then
        local u = m.arguments[1]
        if type(u) == "table" and tostring(u.mid):upper() == charger_serial:upper() then
            stream_update(tonumber(u.id), observation_value(u.value), u.timestamp, now)
        end
    elseif m.type == 3 and m.invocationId == "0" then
        if m.error ~= nil then return "subscribe refused: " .. brief(m.error) end
        stream_state, stream_up_ms = "up", now
        host.log("info", "Easee: SignalR stream up for " .. charger_serial .. "; REST once a minute")
    elseif m.type == 7 then
        return "server closed" .. (m.error ~= nil and (": " .. brief(m.error)) or "")
    end
    return nil
end

-- stream_service connects, reads what arrived since the last poll and keeps
-- the connection alive. It never fails the poll: REST covers any gap.
local function stream_service(now)
    if stream_state == "disabled" then return end
    if stream_state ~= "off" and stream_token ~= access_token then
        -- The stream signed in with the old token; Easee may close it when
        -- that token expires.
        stream_stop("token renewed", now, true)
    end
    if stream_state == "off" then
        if now >= stream_retry_ms then stream_open(now) end
        return
    end
    local ok, frames = pcall(host.ws_messages)
    if not ok or type(frames) ~= "table" then frames = {} end
    for _, frame in ipairs(frames) do
        -- FTW's host queues "" when the connection ends.
        if frame == "" then return stream_stop("closed", now) end
        stream_rx_ms = now
        stream_buf = stream_buf .. frame
        local cut = stream_buf:find(RS, 1, true)
        while cut do
            local problem = stream_message(stream_buf:sub(1, cut - 1), now)
            stream_buf = stream_buf:sub(cut + 1)
            if problem then return stream_stop(problem, now) end
            cut = stream_buf:find(RS, 1, true)
        end
    end
    if #stream_buf > 1048576 then return stream_stop("message without end", now) end
    local open_ok, is_open = pcall(host.ws_is_open)
    if not open_ok or not is_open then return stream_stop("closed", now) end
    if now - stream_rx_ms >= STREAM_SILENT_MS then return stream_stop("silent for 60 s", now) end
    if stream_owed and now - stream_owed.since >= STREAM_OWED_MS then
        return stream_stop(stream_owed.why, now)
    end
    if stream_state ~= "up" and now - stream_opened_ms >= STREAM_OPEN_MS then
        return stream_stop("no subscription within 30 s", now)
    end
    if now - stream_tx_ms >= STREAM_PING_MS then
        local sent, err = stream_send('{"type":6}', now)
        if not sent then return stream_stop("ping: " .. tostring(err), now) end
    end
end

-- ---- State mapping ----
-- Easee chargerOpMode (observation 109):
--   1 = disconnected (standby)
--   2 = awaiting start (connected, not charging)
--   3 = charging
--   4 = completed
--   5 = error
--   6 = ready to charge

local OP_MODE_LABELS = {
    [0] = "offline",
    [1] = "disconnected",
    [2] = "awaiting start",
    [3] = "charging",
    [4] = "completed",
    [5] = "error",
    [6] = "ready",
}

-- Easee ReasonForNoCurrent. 0 = charger OK (no reason to surface).
-- Source: developer.easee.com/docs/enumerations
local REASON_LABELS = {
    [0]   = nil, -- no reason
    [1]   = "max circuit current too low",
    [2]   = "dynamic circuit current too low",
    [3]   = "offline fallback circuit current too low",
    [4]   = "circuit fuse too low",
    [5]   = "waiting in queue",
    [6]   = "waiting in fully charged queue",
    [7]   = "illegal grid type",
    [8]   = "no current request from car",
    [9]   = "master communication lost",
    [10]  = "equalizer current too low",
    [11]  = "phase not connected",
    [25]  = "current limited by circuit fuse",
    [26]  = "current limited by circuit max current",
    [27]  = "current limited by dynamic circuit current",
    [28]  = "current limited by equalizer",
    [29]  = "current limited by circuit load balancing",
    [30]  = "current limited by offline settings",
    [50]  = "secondary unit not requesting current",
    [51]  = "max charger current too low",
    [52]  = "max dynamic charger current too low",
    [53]  = "charger disabled",
    [54]  = "pending scheduled charging",
    [55]  = "pending authorization",
    [56]  = "charger in error state",
    [57]  = "erratic EV",
    [75]  = "limited by cable rating",
    [76]  = "limited by schedule",
    [77]  = "limited by charger max current",
    [78]  = "limited by dynamic charger current",
    [79]  = "car not drawing current",
    [80]  = "current ramping",
    [81]  = "limited by car",
    -- Easee's public enumeration doesn't define 100. Field observation:
    -- we see it when the EV is the side rejecting the offer (Tesla
    -- charge-on-solar window, charge limit reached, scheduled charging
    -- still active, transient handshake hiccup). Labelling it
    -- "undefined error" misleads operators into chasing a charger
    -- problem when the wallbox is fine.
    [100] = "EV not accepting current",
}

-- Easee's own load balancing can hold the car below FTW's order. In a field
-- trace (srcfl/ftw#1763, 23 Oct 2026) FTW ordered 15 A and the charger read
-- back 15 A (observation 48), while the circuit's allocated current (70-72)
-- and the current signalled to the car (114) fell to 12, 14 and 13 A; the
-- car took 8.2-8.9 kW instead of 10.4 kW. Easee records a value when it
-- changes, so a value answers the order when it was recorded at or after
-- the order, or when the order has stood ORDER_SETTLE_MS since the driver
-- saw it and the value has not moved.
local ORDER_SETTLE_MS = 30000
local order_seen_a, order_seen_ms = nil, 0
-- When Easee lets the car take the order again, the car needs a few seconds
-- to draw it and the cloud to report that. Until then the reading still
-- shows the old limit's draw, so the old limit is kept for up to
-- LIMIT_RELEASE_HOLD_MS while the car charges below the order.
local LIMIT_RELEASE_HOLD_MS = 20000
local last_limit_a, last_limited_by, last_limit_ms = nil, nil, nil

local email, password, configured_max_a
local device_limit_a, device_limit_read_ms
local settings_poll_ms = 0

-- read_settings GETs the charger's static config block (phaseMode,
-- maxChargerCurrent, etc.) and surfaces it via the init log so the
-- operator can spot a firmware-locked phaseMode that would silently
-- ignore our writes. Easee's API uses `/config` for reads and
-- `/settings` for writes — they're not symmetric. Returns the
-- decoded table or nil + err string. Active firmware-lock detection
-- (compare requested phaseMode after a write) is a follow-up; this
-- driver's contribution is the diagnostic logging at init.
local function read_settings(serial)
    local resp, err = safe_http_get(BASE_URL .. "/chargers/" .. serial .. "/config", auth_headers())
    if err then return nil, redact_http_err(err) end
    local decoded = safe_json_decode(resp)
    if decoded == nil then
        return nil, "decode failed (non-JSON response)"
    end
    return decoded, nil
end

-- write_setting POSTs a single key:value into the charger's settings
-- endpoint. Used at init for maxChargerCurrent (one-shot install
-- clamp) and for phaseMode / dynamicChargerCurrent on every command.
local function write_setting(serial, body_table)
    local _, err = host.http_post(
        BASE_URL .. "/chargers/" .. serial .. "/settings",
        host.json_encode(body_table), auth_headers())
    return err
end

-- start_boost_fits: 7 A per phase fits when Core's cap for this charger
-- (cap_amps_per_phase: its room below the fuse and the import limit, after
-- other chargers' share), the order's max_amps_per_phase and the charger's
-- static limit, read from /config, all allow it. max_amps_per_phase alone is
-- the fuse rating, not the room left: a 6 A order on a phase with room for
-- 6.4 A would draw 7 A, Core would see an overage and stop the car, and the
-- next start would boost again. A Core that sends no cap gets no boost.
-- Checked on every order while a boost runs.
local function start_boost_fits(cmd, max_a)
    local cap = cmd and type(cmd.cap_amps_per_phase) == "number" and cmd.cap_amps_per_phase or nil
    return cap ~= nil and math.floor(cap) >= START_BOOST_A and
        max_a ~= nil and math.floor(max_a) >= START_BOOST_A and
        device_limit_a ~= nil and device_limit_a >= START_BOOST_A
end

-- end_start_boost writes the ordered 6 A. A failed write leaves the boost
-- running, so the next poll or order tries again.
local function end_start_boost(why)
    local werr = write_setting(charger_serial, {dynamicChargerCurrent = EASEE_MIN_A})
    if werr ~= nil then
        host.log("warn", "Easee: start boost step-down failed (will retry): " .. redact_http_err(werr))
        return false
    end
    host.log("info", "Easee: start boost ended (" .. why .. "), dynamicChargerCurrent=6 A")
    boost_until_ms = nil
    last_amps_set = EASEE_MIN_A
    return true
end

-- clear_start_boost drops the boost without a write and re-arms it. A running
-- boost left 7 A in last_amps_set; it becomes hold_a, what the charger should
-- hold, so a pending phaseMode re-assert cannot write 7 A outside the window
-- and the cap check.
local function clear_start_boost(hold_a)
    if boost_until_ms ~= nil then last_amps_set = hold_a end
    boost_until_ms = nil
    boost_spent = false
end

function driver_init(config)
    host.set_make("Easee")

    email = config and config.email
    password = config and config.password
    charger_serial = config and config.serial
    -- UI writes "" for an unselected <select>. In Lua "" is truthy, so the
    -- auto-detect branch below would never fire without this normalization.
    if charger_serial == "" then charger_serial = nil end
    if email == "" then email = nil end
    if password == "" then password = nil end

    -- Phases: default to 3 since that's the common European install.
    -- Users on a single-phase service (Easee Home <11 kW) must set
    -- `phases: 1` in config, otherwise amperage math for ev_set_current
    -- is 3x under-requested and can fall below the 6 A Easee minimum
    -- (silently halting the session).
    if config and tonumber(config.phases) then
        local p = math.floor(tonumber(config.phases))
        if p == 1 or p == 2 or p == 3 then phases = p end
    end

    -- Optional `max_charger_current` config: clamps the charger's
    -- static maxChargerCurrent to this value via the settings API at
    -- init. Bounds the post-phaseMode-reset window (Easee resets
    -- dynamicChargerCurrent → maxChargerCurrent on every phase flip;
    -- if the install's maxChargerCurrent is higher than the per-phase
    -- fuse can sustain, the post-reset window can briefly exceed
    -- safe bounds before the next 5 s controller tick claws it back).
    if config and tonumber(config.max_charger_current) then
        local m = tonumber(config.max_charger_current)
        if m > 0 and m <= EASEE_MAX_A then
            configured_max_a = m
        end
    end

    if config and (config.start_boost == false or config.start_boost == "false") then
        start_boost_enabled = false
    end

    if not email or not password then
        host.log("error", "Easee: email and password required in driver config")
        return
    end

    if not ensure_auth(email, password) then
        host.log("error", "Easee: initial login failed")
        return
    end

    -- Auto-detect serial if not provided
    if not charger_serial then
        local chargers, cerr = get_chargers()
        if cerr or not chargers or #chargers == 0 then
            host.log("error", "Easee: could not list chargers: " .. redact_http_err(cerr))
            return
        end
        charger_serial = chargers[1].id
        host.log("info", "Easee: auto-detected charger " .. tostring(charger_serial))
    end

    host.set_sn(charger_serial)

    -- Probe firmware-side settings so operators know what the charger
    -- itself is committed to BEFORE our first phaseMode write goes out
    -- (silent overrides got us 30 minutes of confusion in the field —
    -- see the PR description for the test session).
    local settings, serr = read_settings(charger_serial)
    if settings then
        local fw_pm = tonumber(settings.phaseMode)
        local fw_max = tonumber(settings.maxChargerCurrent)
        if fw_max and fw_max >= 0 and fw_max <= EASEE_MAX_A then
            device_limit_a, device_limit_read_ms = fw_max, host.millis()
        end
        settings_poll_ms = host.millis()
        host.log("info", "Easee: firmware settings — phaseMode=" .. tostring(fw_pm) ..
            " (1=1p,2=auto,3=3p), maxChargerCurrent=" .. tostring(fw_max) .. "A")
        -- Apply the operator's max_charger_current clamp if it differs.
        if configured_max_a and fw_max ~= configured_max_a then
            local werr = write_setting(charger_serial, {maxChargerCurrent = configured_max_a})
            if werr == nil then
                device_limit_a, device_limit_read_ms = nil, nil -- wait for readback
                settings_poll_ms = host.millis() - 60000
                host.log("info", "Easee: maxChargerCurrent clamped to " ..
                    tostring(configured_max_a) .. " A (was " .. tostring(fw_max) .. " A)")
            else
                host.log("warn", "Easee: maxChargerCurrent write failed: " ..
                    redact_http_err(werr))
            end
        end
    elseif serr then
        host.log("warn", "Easee: could not read firmware settings: " .. serr)
    end

    host.log("info", "Easee: driver initialized for " .. charger_serial)
end

function driver_poll()
    if not charger_serial or not email then
        return 10000
    end

    if not ensure_auth(email, password) then
        host.log("warn", "Easee: auth failed, skipping poll")
        return 10000
    end

    -- The boost window ends on time even when observations fail.
    if boost_until_ms ~= nil and host.millis() >= boost_until_ms then
        end_start_boost("timeout")
    end

    stream_service(host.millis())

    -- Without the stream REST reads on every poll, as before. With it, REST
    -- reads once a minute to show the cloud still hears from the charger.
    local streaming = stream_state == "up"
    local rest_due = not streaming or host.millis() >= rest_next_ms
    local values, err, stamps
    if rest_due then values, err, stamps = get_observations(charger_serial) end
    local now = host.millis()
    local rest_read, held_back = false, false
    if rest_due then
        local problem = err or state_problem(values)
        local unordered = not problem and power_order_problem(values, stamps, now)
        rest_next_ms = now + ((problem or unordered) and 10000 or REST_CONFIRM_MS)
        if problem then
            host.log("warn", "Easee: observations poll failed: " .. (err and redact_http_err(err) or problem))
            -- The cloud answered that it does not hear the charger.
            if not err then heard_ms = nil end
        elseif unordered then
            held_back = true
            host.log("warn", "Easee: observations reply not used: " .. unordered)
        else
            -- Without the stream the reply is the whole state, as before.
            if not streaming then latest, latest_at, latest_pushed = {}, {}, {} end
            for id in pairs(OBS_WANTED) do
                if values[id] ~= nil or stamps[id] ~= nil then
                    if note_observation(id, values[id], stamps[id], false) and streaming and owed_kind(id) then
                        owe(id, source_time_key(stamps[id]), values[id], now, "missed a change REST saw")
                    end
                end
            end
            -- A REST read that finds the stream complete resets its back-off.
            if streaming and not stream_owed then stream_failures = 0 end
            heard_ms, rest_read = now, true
        end
    end

    -- Report what this poll's REST read showed, or, while the stream is up,
    -- what it pushed since a REST read in the last 90 s. Otherwise report
    -- nothing, as before, so stale values never look current.
    local vouched = rest_read or
        (stream_state == "up" and heard_ms ~= nil and now - heard_ms <= REST_FRESH_MS)
    local blocked = vouched and state_problem(latest)
    if blocked and blocked ~= last_blocked then
        host.log("warn", "Easee: not reporting streamed state: " .. blocked)
    end
    last_blocked = blocked or nil
    if not vouched or blocked then
        -- An unreadable charger may have changed cars during the gap. A
        -- reply held back for its order is not a gap.
        if not held_back then invalidate_session_proof() end
        return stream_state == "up" and STREAM_POLL_MS or 10000
    end
    local obs, timestamps = latest, latest_at

    local op_mode = obs[OBS_OP_MODE] or 1
    local power_w = (obs[OBS_TOTAL_POWER] or 0) * 1000  -- kW → W
    local session_wh = (obs[OBS_SESSION_ENERGY] or 0) * 1000  -- kWh → Wh
    local connected = (op_mode >= 2 and op_mode <= 6)
    local charging = (op_mode == 3)
    -- op_mode 0 is the sentinel Easee emits when the cloud hasn't heard
    -- from the unit recently. Anything else means the charger itself is
    -- responsive even when no car is plugged in.
    local is_online = (op_mode ~= 0)

    -- Easee records an observation only when its value changes, so a steady
    -- charge keeps an old TotalPower timestamp; on hardware it stayed
    -- unchanged for over five minutes. A new value carries its source time.
    -- An unchanged one was confirmed by a REST read of a charger the cloud
    -- still hears from (state_problem rejects op_mode 0): this poll's, or
    -- one in the last 90 s while the stream would have pushed a change. So
    -- omit the source time and let the host stamp the reading when it arrives.
    local power_observed_at = timestamps[OBS_TOTAL_POWER]
    if power_observed_at ~= nil and power_observed_at == last_power_observed_at then
        power_observed_at = nil
    else
        last_power_observed_at = power_observed_at
    end

    local reason_code = obs[OBS_REASON_NO_CUR]
    -- ReasonForNoCurrent describes a blocked offer. An older reason is not
    -- a current fault while the charger reports both charging and power.
    local reason_at = source_time_key(timestamps[OBS_REASON_NO_CUR])
    local power_at = source_time_key(timestamps[OBS_TOTAL_POWER])
    if charging and power_w > 100 and reason_at and power_at and reason_at <= power_at then
        reason_code = nil
    end
    local cable_locked = obs[OBS_CABLE_LOCKED]
    if cable_locked ~= nil then cable_locked = (cable_locked == 1 or cable_locked == true) end
    local dyn_current = obs[OBS_DYN_CURRENT]

    -- Derive actual per-phase amps from the live total power +
    -- per-phase voltage (when available) — diagnostic counterpart to
    -- the `max_a` field which only echoes whatever we last wrote.
    -- Operators wanting "is the EV actually drawing what we asked
    -- for?" should compare actual_amps_per_phase against max_a.
    --
    -- Only computed for the canonical 1Φ / 3Φ configurations. Earlier
    -- driver_init permitted config.phases=2 (a misconfigured site,
    -- or a transitional state before the first successful phaseMode
    -- write). Dividing by 2 there would yield a "per-phase" number
    -- that doesn't correspond to any real cabling — better to omit
    -- the field than mislead the operator with a fictitious value.
    local actual_amps_per_phase = nil
    local v_obs = obs[OBS_VOLTAGE]
    if power_w > 0 and (phases == 1 or phases == 3) then
        local vv = (v_obs and v_obs > 0) and v_obs or 230
        actual_amps_per_phase = power_w / vv / phases
    end

    -- command_stalled: true when we've been offering >0 A for >30 s but
    -- the charger isn't drawing AND Easee is reporting an EV-side or
    -- "max dynamic too low" reason. Lets the controller / UI tell the
    -- difference between "EV declined" (legitimate, e.g. Tesla SoC
    -- limit reached) and "wallbox accepted but contactor stuck"
    -- (needs operator attention). Note: connected==true is required so
    -- a disconnected cable doesn't latch the flag.
    local command_stalled = false
    local stalled_reason = (reason_code == 52) or (reason_code == 53) or (reason_code == 100)
    if connected and (last_amps_set or 0) > 0 and not charging and stalled_reason then
        if command_stalled_since_ms == 0 then
            command_stalled_since_ms = now
        elseif (now - command_stalled_since_ms) >= 30000 then
            command_stalled = true
        end
    else
        command_stalled_since_ms = 0
    end

    -- request_active: false ONLY when the vehicle side has explicitly
    -- stopped requesting current — Easee reason 50 ("secondary unit
    -- not requesting current"; the vehicle is the secondary unit) or
    -- op_mode 4 ("completed"). Every other reason (52/53/100 = the box
    -- throttled it, pending authorization, schedules, fuse limits)
    -- keeps the default true, so a pause the box itself ordered is
    -- never mistaken for the car declining. The host debounces this
    -- for 90 s before acting on it (session-completion latch,
    -- manual-hold auto-release), so a brief 50 during session
    -- handshake is harmless. Field observation 2026-08-29: a car at
    -- its own charge limit held reason 50 all night while the box kept
    -- offering 11 kW and paged the operator twice about it.
    local request_active = true
    if connected and not charging and (reason_code == 50 or op_mode == 4) then
        request_active = false
    end

    -- current_limit_a is the current signalled to the car while it is below
    -- the order the charger holds and answers it. current_limited_by names
    -- the load balancer only when the circuit's allocation is below the order
    -- too and no higher than that current, so the allocation explains it.
    -- ReasonForNoCurrent is not used here: an older reason is not proof.
    if dyn_current ~= order_seen_a then order_seen_a, order_seen_ms = dyn_current, now end
    local order_at = source_time_key(timestamps[OBS_DYN_CURRENT])
    local order_settled = now - order_seen_ms >= ORDER_SETTLE_MS
    local function confirmed_current(id)
        local value, value_at = obs[id], source_time_key(timestamps[id])
        if type(value) ~= "number" or value ~= value or value < 0 or value > 80 or not value_at then return nil end
        local confirmed = observation_confirmed_ms[id]
        if not confirmed or now - confirmed > REST_FRESH_MS then return nil end
        local wall = host.unix_ms and host.unix_ms() or nil
        if wall and tonumber(value_at) * 1000 > wall then return nil end
        return value, value_at
    end
    local function answering(id)
        local value, value_at = confirmed_current(id)
        if value ~= nil and (order_settled or (value_at and order_at and value_at >= order_at)) then return value end
        return nil
    end
    -- The charger must hold FTW's last order: while it reads back an older
    -- one, the pilot may be following the new order. The charger's own
    -- static limit is device_limit_a, not its load balancing.
    local current_limit_a, current_limited_by = nil, nil
    local pilot_a = answering(OBS_OUTPUT_CURRENT)
    if charging and type(dyn_current) == "number" and last_amps_set ~= nil and
       math.abs(last_amps_set - dyn_current) <= 0.5 and
       pilot_a and pilot_a > 0 and pilot_a < dyn_current - 0.5 then
        current_limit_a = pilot_a
        local low, high, n = nil, nil, 0
        for id = OBS_ALLOCATED_L1, OBS_ALLOCATED_L1 + 2 do
            local a = answering(id)
            if a then
                n, high = n + 1, math.max(high or a, a)
                if a > 0 then low = math.min(low or a, a) end
            end
        end
        -- A three-phase car gets the lowest share of the phases it uses; a
        -- phase with none is not one of them. A one-phase car uses one
        -- phase, which the driver does not know, so the highest.
        local allocated_a = (phases == 1) and high or (n == 3 and low or nil)
        local own_limit = device_limit_a ~= nil and pilot_a >= device_limit_a - 0.5
        if allocated_a and allocated_a > 0 and allocated_a < dyn_current - 0.5 and allocated_a <= pilot_a + 0.5 and
           not own_limit then
            current_limited_by = "load_balancer"
        end
    end
    if current_limit_a then
        last_limit_a, last_limited_by, last_limit_ms = current_limit_a, current_limited_by, now
    elseif last_limit_ms and now - last_limit_ms < LIMIT_RELEASE_HOLD_MS and charging and
           type(dyn_current) == "number" and actual_amps_per_phase and actual_amps_per_phase < dyn_current - 1 then
        current_limit_a, current_limited_by = last_limit_a, last_limited_by
    end

    local raw_pilot = confirmed_current(OBS_OUTPUT_CURRENT)
    local limit_age_s = device_limit_read_ms and (host.millis() - device_limit_read_ms) / 1000
    host.emit("ev", {
        w                       = power_w,
        connected               = connected,
        charging                = charging,
        request_active          = request_active,
        session_wh              = session_wh,
        power_observed_at       = power_observed_at,
        -- Control verification needs distinct source samples. A fresh cloud
        -- reply alone does not establish a new physical power measurement.
        control_power_observed_at = timestamps[OBS_TOTAL_POWER],
        control_power_available = obs[OBS_TOTAL_POWER] ~= nil and timestamps[OBS_TOTAL_POWER] ~= nil,
        -- The cloud records power only on change, and the driver reports only
        -- what a REST read of a charger the cloud still hears from vouches for
        -- (see vouched above). An unchanged value is therefore still current,
        -- so a steady charge stays measured.
        control_power_confirmed = obs[OBS_TOTAL_POWER] ~= nil and timestamps[OBS_TOTAL_POWER] ~= nil,
        power_max_age_s         = 180,
        energy_observed_at      = timestamps[OBS_SESSION_ENERGY],
        state_observed_at       = timestamps[OBS_OP_MODE],
        reason_observed_at      = timestamps[OBS_REASON_NO_CUR],
        session_id              = current_session_id(obs, op_mode),
        op_mode                 = op_mode,                     -- 1=disc,2=awaiting,3=charging,4=completed,5=error,6=ready
        state_label             = OP_MODE_LABELS[op_mode] or "unknown",
        reason_no_current       = reason_code,                 -- int: 0=ok; why NOT drawing current
        reason_no_current_label = reason_code and REASON_LABELS[reason_code], -- nil if 0/ok, string otherwise
        is_online               = is_online,
        cable_locked            = cable_locked,
        device_limit_a          = device_limit_a,
        device_limit_age_s      = limit_age_s,
        current_limit_a         = current_limit_a,             -- A signalled to the car, below the order
        current_limited_by      = current_limited_by,          -- "load_balancer" or nil
        pilot_a                 = raw_pilot,
        pilot_observed_at       = raw_pilot ~= nil and timestamps[OBS_OUTPUT_CURRENT] or nil,
        pilot_confirmed_at_ms   = raw_pilot ~= nil and observation_confirmed_wall_ms[OBS_OUTPUT_CURRENT] or 0,
        dynamic_limit_a         = dyn_current,
        max_a                   = dyn_current,                 -- last-set dynamic limit (echoes our write, may lag)
        actual_amps_per_phase   = actual_amps_per_phase,       -- live per-phase A derived from totalPower
        phases                  = phases,                      -- our committed phase count (1 or 3)
        command_stalled         = command_stalled,             -- offer>0 but contactor open >30s on stall reason
    })

    -- Defense against Easee's post-phaseMode reset of dynamicChargerCurrent
    -- → maxChargerCurrent. driver_command sets pending_amp_resend=true
    -- right after a successful phaseMode write; on the next poll
    -- (≥ ~5 s later, by which time the cloud has settled) we re-write
    -- our intended amps to overcome the reset. Idempotent — same write
    -- as the controller would issue on its next 5 s tick, just earlier.
    --
    -- Only clear the flag on success. A transient network failure or
    -- 5xx leaves it pending so the NEXT poll retries instead of
    -- silently leaving the charger pinned at maxChargerCurrent. The
    -- controller's own 5 s tick is the safety floor; this just
    -- accelerates convergence in the common case.
    if pending_amp_resend and last_amps_set ~= nil and host.millis() >= pending_amp_resend_at_ms then
        local werr = write_setting(charger_serial, {dynamicChargerCurrent = last_amps_set})
        if werr == nil then
            host.log("info", "Easee: re-asserted dynamicChargerCurrent=" .. tostring(last_amps_set) ..
                " A after phaseMode reset")
            pending_amp_resend = false
        else
            host.log("warn", "Easee: dynamicChargerCurrent re-assert failed (will retry next poll): " ..
                redact_http_err(werr))
        end
    end

    -- 6 A start boost: step down to the ordered 6 A as soon as the charger
    -- reports charging. The timeout is checked above, before observations.
    if boost_until_ms ~= nil and charging then
        end_start_boost("charging")
    end
    -- A session that stops charging may need a new boost on its next start.
    if last_op_mode == 3 and not charging and boost_until_ms == nil then
        boost_spent = false
    end
    last_op_mode = op_mode

    if obs[OBS_VOLTAGE] then
        host.emit_metric("ev_voltage_v", obs[OBS_VOLTAGE])
    end
    if obs[OBS_CURRENT] then
        host.emit_metric("ev_current_a", obs[OBS_CURRENT])
    end
    if obs[OBS_LIFETIME_ENERGY] then
        host.emit_metric("ev_lifetime_kwh", obs[OBS_LIFETIME_ENERGY])
    end
    if dyn_current then
        host.emit_metric("ev_dynamic_current_a", dyn_current)
    end

    -- Static ceiling and dynamic offer are different. Refresh the ceiling
    -- once a minute and report its age even when a later read fails.
    if now - settings_poll_ms >= 60000 then
        settings_poll_ms = now
        local settings = read_settings(charger_serial)
        local limit = settings and tonumber(settings.maxChargerCurrent)
        if limit and limit >= 0 and limit <= EASEE_MAX_A then
            device_limit_a, device_limit_read_ms = limit, host.millis()
        end
    end

    return stream_state == "up" and STREAM_POLL_MS or 5000
end

local function post_command(path)
    local _, err = host.http_post(
        BASE_URL .. "/chargers/" .. charger_serial .. path,
        "null", auth_headers())
    return err == nil
end

function driver_command(action, power_w, cmd)
    if not charger_serial or not ensure_auth(email, password) then return false end

    if action == "ev_start" then
        local ok = post_command("/commands/start_charging")
        if ok then paused_state = false end
        return ok
    elseif action == "ev_pause" then
        local ok = post_command("/commands/pause_charging")
        if ok then
            paused_state = true
            -- Keep the 6 A order, not 0 A: Core's contactor cycle sends
            -- ev_resume after ev_pause with no new order in between.
            clear_start_boost(EASEE_MIN_A)
        end
        return ok
    elseif action == "ev_resume" then
        local ok = post_command("/commands/resume_charging")
        if ok then paused_state = false end
        return ok
    elseif action == "ev_set_current" then
        -- Driver-level phase decision: read the operator's preferences
        -- + site fuse from the cmd, decide 1Φ vs 3Φ here based on
        -- the requested W and the voltage we know about. The Go
        -- controller does NOT pick phases; it just allocates power.
        local mode    = (cmd and type(cmd.phase_mode)       == "string") and cmd.phase_mode       or ""
        local split   = (cmd and type(cmd.phase_split_w)    == "number") and cmd.phase_split_w    or 0
        local hold_s  = (cmd and type(cmd.min_phase_hold_s) == "number") and cmd.min_phase_hold_s or 0
        local voltage = (cmd and type(cmd.voltage)          == "number" and cmd.voltage > 0)          and cmd.voltage          or 230
        local max_a   = (cmd and type(cmd.max_amps_per_phase) == "number" and cmd.max_amps_per_phase > 0) and cmd.max_amps_per_phase or nil

        local now_ms = host.millis()
        local requested_phases = pick_phases(mode, power_w or 0, voltage, max_a, split, hold_s, now_ms)

        -- POST phaseMode FIRST when it differs. Easee's settings
        -- endpoint accepts phaseMode = 1 (locked-1p), 2 (auto), 3
        -- (locked-3p). We only ever lock — "auto" is our concern, not
        -- the charger's.
        local phase_changed = false
        if last_sent_phases ~= requested_phases then
            -- A live phase flip (notably 1Φ→3Φ) won't move the Easee
            -- contactor while a session is charging: the phase count is only
            -- latched when a session (re)starts. So on a real mid-session flip
            -- pause first; the phaseMode write reconfigures, and the auto-
            -- resume below (amps > 0 && paused_state) re-closes the contactor
            -- on the new phase count. Operator-confirmed: a manual
            -- pause+resume was the only thing that flipped 1Φ→3Φ. Skip on the
            -- first command of a session (last_sent_phases == nil) — there's no
            -- live contactor to recycle. 2026-05-30.
            if last_sent_phases ~= nil then
                if post_command("/commands/pause_charging") then
                    paused_state = true
                    host.log("info", "Easee: pause to flip phaseMode " ..
                        tostring(last_sent_phases) .. "→" .. tostring(requested_phases))
                end
            end
            local pm_err = write_setting(charger_serial, {phaseMode = requested_phases})
            if pm_err == nil then
                phases = requested_phases
                last_sent_phases = requested_phases
                last_phase_change_ms = now_ms
                phase_changed = true
                host.log("info", "Easee: phaseMode → " .. tostring(requested_phases))
            else
                host.log("warn", "Easee: phaseMode write failed; skipping current write to avoid overcurrent on stale phase: " ..
                    redact_http_err(pm_err))
                -- CRITICAL: power_w was budgeted against requested_phases
                -- (e.g. 7400 W with the intent of 3Φ → 32 A/phase).
                -- Computing amps against the unchanged phase count would
                -- command 32 A on a single phase — tripping a 16 A
                -- breaker. Fail the command; controller retries next tick.
                return false
            end
        end

        local amps = per_phase_amps(power_w, voltage, phases, max_a)
        local write_a = amps
        local boosting = false
        local boost_end = nil
        if amps == EASEE_MIN_A then
            if boost_until_ms ~= nil then
                -- Keep 7 A within the window while it still fits and the
                -- charger has not started; do not restart the window.
                -- Otherwise this write of 6 A ends the boost.
                if now_ms >= boost_until_ms then
                    boost_end = "timeout"
                elseif last_op_mode == 3 then
                    boost_end = "charging"
                elseif not start_boost_fits(cmd, max_a) then
                    boost_end = "no room for 7 A"
                else
                    write_a, boosting = START_BOOST_A, true
                end
            elseif start_boost_enabled and not boost_spent and start_boost_fits(cmd, max_a) and
                last_op_mode ~= nil and last_op_mode ~= 3 then
                -- An unknown op_mode may be charging: after a driver reload
                -- the car can already charge at 6 A before the first poll.
                write_a, boosting = START_BOOST_A, true
            end
        end
        local err = write_setting(charger_serial, {dynamicChargerCurrent = write_a})
        if err == nil then
            if boosting then
                if boost_until_ms == nil then
                    boost_until_ms = now_ms + START_BOOST_MAX_MS
                    boost_spent = true
                    host.log("info", "Easee: start boost 7 A for a 6 A start (Easee delays ~5 min at 6 A)")
                end
            else
                if boost_end ~= nil then
                    host.log("info", "Easee: start boost ended (" .. boost_end .. "), dynamicChargerCurrent=6 A")
                end
                boost_until_ms = nil
                if amps == 0 then boost_spent = false end
            end
            last_amps_set = write_a
            -- After a phaseMode change, schedule one re-write of
            -- dynamicChargerCurrent on the next driver_poll. Easee's
            -- cloud resets it to maxChargerCurrent during the phase
            -- transition; this defends against the reset window
            -- without waiting for the controller's 5 s tick.
            if phase_changed then
                pending_amp_resend = true
                pending_amp_resend_at_ms = now_ms + 5000
            end
            -- Auto-resume after pause. The controller's contract used
            -- to be: ev_pause → (later) ev_resume → ev_set_current.
            -- In practice the controller drops ev_resume in some
            -- transitions and just re-issues ev_set_current with a
            -- non-zero offer — Easee accepts the new
            -- dynamicChargerCurrent but the contactor stays open
            -- because pause is still active (op_mode=2,
            -- reason_no_current=52 or 100, ev_w=0). Defensively
            -- send resume_charging when we know we're paused and
            -- the new offer is > 0. Idempotent on the Easee side;
            -- a failure here doesn't fail the command (the offer
            -- itself succeeded, controller will retry next tick).
            if amps > 0 and paused_state then
                if post_command("/commands/resume_charging") then
                    paused_state = false
                    host.log("info", "Easee: auto-resumed after pause (offer=" ..
                        tostring(amps) .. " A)")
                end
            end
        end
        return err == nil
    end

    return false
end

function driver_default_mode()
    -- Stand-down when FTW can no longer steer: pause and clamp offered
    -- current to 0 A. Missing serial/auth is not an error — nothing to
    -- release yet.
    if not charger_serial or not email or not password then
        return
    end
    if not ensure_auth(email, password) then
        return
    end
    if post_command("/commands/pause_charging") then
        paused_state = true
    end
    clear_start_boost(0)
    local err = write_setting(charger_serial, {dynamicChargerCurrent = 0})
    if err == nil then
        last_amps_set = 0
    else
        host.log("warn", "Easee: default_mode current clamp failed: " ..
            redact_http_err(err))
    end
end

function driver_cleanup()
    if stream_state ~= "off" and stream_state ~= "disabled" then pcall(host.ws_close) end
    stream_state = "off"
    access_token = nil
    refresh_token = nil
end
