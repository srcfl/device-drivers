-- OpenEVSE, local HTTP API of the OpenEVSE WiFi firmware (4.1.9 and later)
-- Emits: EV
-- Protocol: HTTP on the LAN, port 80
--
-- Source: OpenEVSE's own OpenAPI description of the WiFi firmware,
--   https://github.com/OpenEVSE/openevse_esp32_firmware/blob/master/api.yml
--   models/Status.yaml, models/Properties.yaml, models/Config.yaml
-- and the firmware's claim handling in src/evse_man.h and evse_man.cpp.
--
-- Read:
--   GET /status            state, vehicle, power (W), amp (mA), voltage,
--                          pilot (A), session_energy (Wh), watthour (Wh)
--   GET /claims/<client>   this driver's own claim, 404 when it has none
--   GET /config            min_current_hard, max_current_soft,
--                          max_current_hard, is_threephase, serial numbers
--                          (read once a minute)
--
-- Write: POST /claims/<client> with {"state": "active", "charge_current": A}
--   or {"state": "disabled"}. A claim at the API priority (500) outranks the
--   schedule, solar divert and boost, and is outranked by the charger's own
--   manual override, RFID, OCPP and limits. The firmware raises a claimed
--   current below its minimum up to the minimum, so this driver never claims
--   less than the minimum: it claims "disabled" instead. The host has no
--   DELETE, so the claim is never released, only set to "disabled".
--
-- The firmware has no registered claim id for FTW. This driver uses
-- 0x46540001 ("FT", client 1). The firmware parses the id as a signed
-- 32-bit number, so an id from the "unregistered" vendor 0xFFFE would not
-- arrive intact. A reboot drops all claims; the claim read-back notices and
-- the next order claims again.
--
-- State (status.state): 1 no car, 2 car connected, 3 charging, 4 ventilation
-- required, 5..11 faults, 254 sleeping, 255 disabled.
--
-- Control:
--   An order of power_w becomes whole amps per phase, rounded down:
--     amps = floor(power_w / (voltage * phases))
--   phases is 3 unless the installation is one-phase (config.phases = 1) and
--   the charger reports it is not three-phase (is_threephase false). OpenEVSE
--   reports one current, not one per phase, so it cannot show a car on one
--   phase, and Core's "1p" alone does not divide by one. The result never
--   exceeds Core's max_amps_per_phase or cap_amps_per_phase or the charger's
--   own maximum. Below its minimum (at least 6 A) the claim is "disabled"; an
--   order is never rounded up. A claim is written only when it differs from
--   the one the charger reports.
--   A resume (Core sends no order with it) uses the last order if it is at
--   most 30 s old, else the minimum, and never more than Core's last cap.
--   When a poll shows no car and FTW's claim left the charger on, the driver
--   claims "disabled", so the next car does not start without FTW. The claim
--   keeps auto_release off.
--   driver_default_mode claims "disabled", but only after FTW has written to
--   the charger in this run; Core runs it at every start. It returns true
--   only when the charger accepted the claim, and tries again at most once a
--   minute.
--
-- A stand-down stays on the charger, as with Zaptec and Easee: the
-- "disabled" claim holds until FTW claims again, the owner uses the manual
-- override, or the charger reboots.
--
-- Sign convention: w is positive while the car charges.
--
-- Config example:
--   drivers:
--     - name: openevse
--       lua: drivers/openevse.lua
--       capabilities:
--         http:
--           allowed_hosts: ["192.168.1.70"]
--       config:
--         host: 192.168.1.70
--         port: 80
--         phases: 1         # optional; 1 for a one-phase installation (default 3)
--         username: ""      # optional; only when an admin password is set
--         password: ""      # blank user means openevseadmin on current firmware

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "openevse",
  name         = "OpenEVSE",
  manufacturer = "OpenEVSE",
  version      = "1.1.0",
  protocols    = { "http" },
  capabilities = { "ev" },
  description  = "OpenEVSE with the WiFi firmware's HTTP API on the LAN. Reads power and session energy, and sets the charging current and start/stop through a claim.",
  homepage     = "https://www.openevse.com",
  authors      = { "FTW contributors" },
  tested_models = { "OpenEVSE WiFi" },
  verification_status = "experimental",
  verification_notes = "Control written from OpenEVSE's WiFi firmware API description (api.yml); not yet confirmed on hardware.",
  config_secrets = { "password" },
  connection_defaults = {
    port = 80,
  },
}

PROTOCOL = "http"

local POLL_MS = 5000
local RETRY_MS = 10000
local CONFIG_EVERY_MS = 60000

-- 0x46540001, written in decimal: the claim id is part of the URL.
local CLAIM_CLIENT = "1179910145"

local MIN_A = 6
local MAX_A = 32
local STALL_MS = 30000
-- A resume reuses an order at most this old; older, it starts at the minimum.
local ORDER_FRESH_MS = 30000
-- A stop the device refused is tried again after this long.
local RETRY_STOP_MS = 60000

local STATE_LABELS = {
  [4]   = "ventilation required",
  [5]   = "diode check failed",
  [6]   = "GFCI fault",
  [7]   = "no ground",
  [8]   = "stuck relay",
  [9]   = "GFCI self-test failed",
  [10]  = "over temperature",
  [11]  = "over current",
  [254] = "sleeping",
  [255] = "disabled",
}

local base_url = nil
local headers = nil
local identity_set = false

-- The charger's own limits, from /config.
local limits = {}
local config_read_ms = nil
local config_due_ms = 0

-- This driver's claim as the charger last reported it, or as a write it
-- accepted since. false: the charger holds no claim from FTW. nil: unknown.
local claim = nil
local measured_v = nil

local phases_cfg = 3           -- config.phases: the installation's phase count
-- Core runs driver_default_mode at every start. It stands down only after FTW
-- wrote to the charger in this run, or found it already holding FTW's order,
-- so a charger FTW never steered keeps the owner's own setting.
local ftw_wrote = false
local order_a, order_ms = nil, nil  -- the last order (0 included) and when
local cap_a = nil                   -- Core's last per-phase cap, A
local left_on = false               -- FTW's last write left the charger on
local stood_down = false            -- default mode has stopped the charger
local stand_down_try_ms = nil       -- when a refused stand-down was tried
local unplug_try_ms = nil           -- when a refused unplug stop was tried
local stalled_since = nil

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

local function num(v)
  if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
    return nil
  end
  return v
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local q = { math.floor(n / 262144) % 64, math.floor(n / 4096) % 64,
                math.floor(n / 64) % 64, n % 64 }
    out[#out + 1] = B64:sub(q[1] + 1, q[1] + 1) .. B64:sub(q[2] + 1, q[2] + 1) ..
      (b and B64:sub(q[3] + 1, q[3] + 1) or "=") .. (c and B64:sub(q[4] + 1, q[4] + 1) or "=")
  end
  return table.concat(out)
end

-- GET and decode JSON. Returns the table, or nil and a reason.
local function http_get_json(path)
  local ok, body, err = pcall(host.http_get, base_url .. path, headers)
  if not ok then return nil, tostring(body) end
  if not body then return nil, tostring(err or "no reply") end
  local ok2, data = pcall(host.json_decode, body)
  if not ok2 or type(data) ~= "table" then return nil, "reply is not JSON" end
  return data
end

local function device_min_a()
  local m = limits.min_a
  if m and m > MIN_A and m <= MAX_A then return m end
  return MIN_A
end

local function device_max_a()
  local cap = MAX_A
  if limits.hard_a and limits.hard_a >= MIN_A and limits.hard_a < cap then cap = limits.hard_a end
  if limits.soft_a and limits.soft_a >= MIN_A and limits.soft_a < cap then cap = limits.soft_a end
  return cap
end

-- Whole amps per phase for a power order. Rounds down and never up.
local function amps_for(power_w, cmd)
  power_w = num(power_w)
  if not power_w or power_w <= 0 then return 0 end
  if type(cmd) ~= "table" then cmd = {} end
  local voltage = num(cmd.voltage)
  if not voltage or voltage < 100 then voltage = measured_v or 230 end
  -- OpenEVSE reports one current, not one per phase, so it cannot show a car
  -- on exactly one phase. Divide by one only when the owner set phases: 1
  -- and the charger's /config says it is not three-phase. Unknown counts as
  -- three-phase, so a three-phase car never gets a one-phase sum.
  local phases = 3
  if phases_cfg == 1 and limits.threephase == false then phases = 1 end
  -- 0.001 A of slack so float rounding cannot turn 6.0 into 5.
  local amps = math.floor(power_w / (voltage * phases) + 0.001)
  local limit = device_max_a()
  local max_cmd = num(cmd.max_amps_per_phase)
  if max_cmd and max_cmd > 0 and max_cmd < limit then limit = max_cmd end
  local cap_cmd = num(cmd.cap_amps_per_phase)
  if cap_cmd and cap_cmd >= 0 and cap_cmd < limit then limit = cap_cmd end
  limit = math.floor(limit + 0.001)
  if amps > limit then amps = limit end
  if amps < device_min_a() then return 0 end
  return amps
end

-- Claim amps (0 claims "disabled"). Writes only when the claim differs.
local function apply(amps)
  local want = amps > 0 and "active" or "disabled"
  if claim and claim.state == want and (want == "disabled" or claim.charge_current == amps) then
    left_on = want == "active"
    return true
  end
  local body = { state = want, auto_release = false }
  ftw_wrote = true
  if want == "active" then body.charge_current = amps end
  local ok, reply, err = pcall(host.http_post, base_url .. "/claims/" .. CLAIM_CLIENT,
    host.json_encode(body), headers)
  if not ok or not reply then
    host.log("warn", "OpenEVSE: claim " .. want .. " failed: " .. tostring(ok and err or reply))
    return false
  end
  local ok2, data = pcall(host.json_decode, reply)
  if ok2 and type(data) == "table" and data.msg ~= nil and data.msg ~= "done" then
    host.log("warn", "OpenEVSE: charger refused the claim: " .. tostring(data.msg))
    return false
  end
  claim = { state = want, charge_current = want == "active" and amps or nil }
  left_on = want == "active"
  return true
end

-- Core's per-phase cap in an order, in whole amps, or nil when it sent none.
local function order_cap(cmd)
  if type(cmd) ~= "table" then return nil end
  local cap = nil
  local m = num(cmd.max_amps_per_phase)
  if m and m > 0 then cap = m end
  local c = num(cmd.cap_amps_per_phase)
  if c and c >= 0 and (not cap or c < cap) then cap = c end
  if not cap then return nil end
  return math.floor(cap + 0.001)
end

-- The current for a resume: the last order while it is fresh, else the
-- minimum, never above Core's last cap. nil when even the minimum is too much.
local function resume_amps(now)
  local amps = device_min_a()
  if order_a and order_a > 0 and order_ms and now - order_ms <= ORDER_FRESH_MS then
    amps = order_a
  end
  if amps > device_max_a() then amps = device_max_a() end
  if cap_a and amps > cap_a then amps = cap_a end
  amps = math.floor(amps)
  if amps < device_min_a() then return nil end
  return amps
end

-- A car left; if FTW left the charger on, stop it so the next car waits for
-- FTW. A refused stop is tried again after RETRY_STOP_MS.
local function stop_if_unplugged(connected, now)
  if connected ~= false or not left_on then
    unplug_try_ms = nil
    return
  end
  if unplug_try_ms and now - unplug_try_ms < RETRY_STOP_MS then return end
  if apply(0) then
    unplug_try_ms = nil
    host.log("info", "OpenEVSE: no car; stopped the charger FTW had left on")
  else
    unplug_try_ms = now
  end
end

local function read_config(now)
  local cfg = http_get_json("/config")
  if not cfg then return end
  limits.min_a = num(cfg.min_current_hard)
  limits.soft_a = num(cfg.max_current_soft)
  limits.hard_a = num(cfg.max_current_hard)
  if type(cfg.is_threephase) == "boolean" then limits.threephase = cfg.is_threephase end
  config_read_ms = now
  if not identity_set then
    local sn = cfg.wifi_serial or cfg.evse_serial
    if type(sn) == "string" and sn ~= "" then host.set_sn(sn) end
    if type(cfg.firmware) == "string" and cfg.firmware ~= "" then
      host.set_model("OpenEVSE " .. cfg.firmware)
    end
    identity_set = true
  end
end

----------------------------------------------------------------------------
-- Driver interface
----------------------------------------------------------------------------

function driver_init(config)
  config = config or {}
  local port = config.port or 80
  base_url = "http://" .. tostring(config.host) .. ":" .. tostring(port)
  local p = tonumber(config.phases)
  if p == 1 or p == 3 then phases_cfg = p end
  local password = config.password
  if type(password) == "string" and password ~= "" then
    local user = config.username
    if type(user) ~= "string" or user == "" then user = "openevseadmin" end
    headers = { Authorization = "Basic " .. base64(user .. ":" .. password) }
  end
  host.set_make("OpenEVSE")
end

function driver_poll()
  local now = host.millis()
  local st, err = http_get_json("/status")
  if not st then
    host.log("warn", "OpenEVSE: status read failed: " .. tostring(err))
    claim, measured_v, stalled_since = nil, nil, nil
    return RETRY_MS
  end

  if now >= config_due_ms then
    config_due_ms = now + CONFIG_EVERY_MS
    read_config(now)
  end

  -- The claim this driver holds, as the charger reports it.
  local c, cerr = http_get_json("/claims/" .. CLAIM_CLIENT)
  if c then
    claim = { state = c.state, charge_current = num(c.charge_current) }
  elseif type(cerr) == "string" and cerr:find("HTTP 404", 1, true) then
    claim = false
  else
    claim = nil
  end

  local voltage = num(st.voltage)
  measured_v = (voltage and voltage > 100) and voltage or nil
  local power_w = num(st.power)
  local amp_ma = num(st.amp)
  if not power_w and voltage and amp_ma then
    -- Older firmware has no power key. amp is mA per phase, and the
    -- firmware itself triples the power of a three-phase setup.
    power_w = voltage * amp_ma / 1000
    if limits.threephase then power_w = power_w * 3 end
  end
  if not power_w then
    host.log("warn", "OpenEVSE: status has no power")
    return RETRY_MS
  end

  local state = num(st.state)
  local connected = nil
  if num(st.vehicle) then
    connected = st.vehicle == 1
  elseif state == 1 then
    connected = false
  elseif state == 2 or state == 3 then
    connected = true
  end
  local charging = nil
  if state then charging = (state == 3) end

  local session_wh = num(st.session_energy)
  if not session_wh and num(st.wattsec) then session_wh = st.wattsec / 3600 end
  local lifetime_wh = num(st.watthour)
  if not lifetime_wh and num(st.total_energy) then lifetime_wh = st.total_energy * 1000 end

  -- max_a is what this driver's claim offers; current_limit_a what the
  -- charger lets the car take after every claim is settled.
  local max_a = nil
  if claim then
    if claim.state == "active" then max_a = claim.charge_current
    elseif claim.state == "disabled" then max_a = 0 end
  end
  local current_limit_a = nil
  if state == 254 or state == 255 then
    current_limit_a = 0
  elseif state then
    current_limit_a = num(st.pilot)
  end

  local reason = nil
  if connected and not charging and state then reason = STATE_LABELS[state] end

  -- Stalled: FTW claims a usable current, a car is connected, and the
  -- charger stays asleep or disabled.
  local stalled = false
  local ordered_on = claim and claim.state == "active" and (claim.charge_current or 0) >= MIN_A
  if connected and ordered_on and (state == 254 or state == 255) then
    stalled_since = stalled_since or now
    stalled = (now - stalled_since) >= STALL_MS
  else
    stalled_since = nil
  end

  host.emit("ev", {
    w                       = power_w,
    connected               = connected,
    charging                = charging,
    session_wh              = session_wh,
    lifetime_wh             = lifetime_wh,
    max_a                   = max_a,
    current_limit_a         = current_limit_a,
    device_limit_a          = config_read_ms and limits.soft_a or nil,
    device_limit_age_s      = (config_read_ms and limits.soft_a) and (now - config_read_ms) / 1000 or nil,
    phases                  = (config_read_ms and limits.threephase ~= nil) and (limits.threephase and 3 or 1) or nil,
    reason_no_current       = reason and state or nil,
    reason_no_current_label = reason,
    command_stalled         = stalled,
    l1_v                    = voltage,
  })

  stop_if_unplugged(connected, now)
  return POLL_MS
end

function driver_command(action, power_w, cmd)
  if action == "init" or action == "deinit" then return true end
  if not base_url then return false end
  local now = host.millis()
  local ok
  if action == "ev_set_current" then
    local cap = order_cap(cmd)
    if cap then cap_a = cap end
    local amps = amps_for(power_w, cmd)
    ok = apply(amps)
    if ok then order_a, order_ms = amps, now end
  elseif action == "ev_pause" then
    ok = apply(0)
  elseif action == "ev_resume" or action == "ev_start" then
    local amps = resume_amps(now)
    if not amps then
      host.log("warn", "OpenEVSE: Core's last cap leaves no room for the minimum current; not starting")
      return false
    end
    ok = apply(amps)
  else
    host.log("warn", "OpenEVSE: unknown action " .. tostring(action))
    return false
  end
  if ok then
    ftw_wrote = true
    stood_down, stand_down_try_ms = false, nil
  end
  return ok
end

-- Stand down when FTW can no longer steer: stop the charger. True only when
-- the charger confirmed the stop, or FTW never wrote to it in this run. A
-- refused stop returns false and is tried again at most once a minute, so a
-- charger that will not take the write is not written every tick.
function driver_default_mode()
  if not base_url or not ftw_wrote or stood_down then return true end
  local now = host.millis()
  if stand_down_try_ms and now - stand_down_try_ms < RETRY_STOP_MS then return false end
  if apply(0) then
    stood_down, stand_down_try_ms = true, nil
    return true
  end
  stand_down_try_ms = now
  return false
end

function driver_cleanup()
  base_url = nil
end
