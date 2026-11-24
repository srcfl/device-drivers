-- go-e Charger, local HTTP API v2
-- Emits: EV
-- Protocol: HTTP on the LAN, port 80. Turn on "HTTP API v2" in the go-e app.
--
-- Source: go-e's own API v2 documentation,
--   https://github.com/goecharger/go-eCharger-API-v2
--   http-en.md                      how to read and write keys
--   API_KEYS_FIRMWARE/apikeys-en.md what each key means
--
-- Read:  GET /api/status?filter=<keys>   (comma list since firmware 051.4)
-- Write: GET /api/set?<key>=<json>        go-e takes writes as GET requests,
--        so this GET changes the charger. The reply has one entry per key:
--        true on success, or an error string.
--
-- Keys this driver uses:
--   car   1 idle (no car), 2 charging, 3 waiting for the car, 4 complete,
--         5 error, 0 unknown
--   nrg   [V1,V2,V3,VN, A1,A2,A3, W1,W2,W3,WN,Wtotal, pf1,pf2,pf3,pfN]
--   wh    energy since the car connected, Wh; eto lifetime energy, Wh
--   amp   requested current, A                     (written here)
--   frc   force state: 0 neutral, 1 off, 2 on       (written here)
--   ama   the owner's maximum current, A; mca minimum charging current, A
--   var   unit rating: 11 (11 kW, 16 A) or 22 (22 kW, 32 A)
--   acu   the current the car may take now, A; null when it may not charge
--   alw   whether the car may charge now
--   modelStatus  why the charger lets the car charge or not
--   sse   serial number; typ device type
--
-- Control:
--   An order of power_w becomes whole amps per phase, rounded down:
--     amps = floor(power_w / (voltage * phases))
--   phases is 3 unless the installation is one-phase (config.phases = 1) and
--   the car is not measured on more than one phase, or Core asks for "1p" and
--   the car is measured on exactly one. An idle charger counts as
--   three-phase, so a three-phase car never gets a one-phase sum. The result
--   never exceeds Core's max_amps_per_phase or cap_amps_per_phase, the
--   owner's ama or the unit's rating. Below the minimum (mca, at least 6 A)
--   the charger is stopped with frc=1; an order is never rounded up. A
--   non-zero order writes amp, and frc=2 only once the charger confirmed
--   amp. Only keys that differ from what the charger last reported are
--   written.
--   frc=2 forces charging past the charger's own RFID check, scheduler and
--   price logic, so FTW alone decides while it steers.
--   A resume (Core sends no order with it) uses the last order if it is at
--   most 30 s old, else the minimum, and never more than Core's last cap.
--   When a poll shows no car and FTW left the charger on, the driver stops
--   it (frc=1), so the next car does not start without FTW.
--   driver_default_mode stops the charger (frc=1), but only after FTW has
--   written to it in this run; Core runs it at every start. It returns true
--   only when the charger confirmed the stop, and tries again at most once
--   a minute.
--
-- frc is a setting, so a stop stays on the charger, as with Zaptec and
-- Easee. If FTW stops, the charger stays off until FTW starts it again or
-- the owner sets it to neutral in the go-e app.
--
-- Sign convention: w is positive while the car charges. go-e cannot
-- discharge a car.
--
-- Config example:
--   drivers:
--     - name: goe
--       lua: drivers/goe_http.lua
--       capabilities:
--         http:
--           allowed_hosts: ["192.168.1.60"]
--       config:
--         host: 192.168.1.60
--         port: 80
--         phases: 3     # optional; 1 for a one-phase installation

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "goe_http",
  name         = "go-e Charger (HTTP API v2)",
  manufacturer = "go-e",
  version      = "1.1.0",
  protocols    = { "http" },
  capabilities = { "ev" },
  description  = "go-e Charger with HTTP API v2 on the LAN. Reads power, phases and session energy, and sets the charging current and start/stop.",
  homepage     = "https://go-e.com",
  authors      = { "FTW contributors" },
  tested_models = { "Gemini flex 11kW", "Gemini flex 22kW", "go-e Pro" },
  verification_status = "experimental",
  verification_notes = "Control written from go-e's HTTP API v2 documentation; not yet confirmed on hardware.",
  connection_defaults = {
    port = 80,
  },
}

PROTOCOL = "http"

local POLL_MS = 5000
local RETRY_MS = 10000
local STATUS_KEYS = "car,amp,ama,mca,var,acu,alw,frc,nrg,wh,eto,modelStatus,sse,typ"

-- IEC 61851 offers no current below 6 A; go-e documents amp up to 32 A.
local MIN_A = 6
local MAX_A = 32
local FRC_OFF, FRC_ON = 1, 2

-- A car taking less than this on a phase is not using that phase.
local PHASE_ACTIVE_A = 1.0
-- An order the charger blocks for this long is reported as stalled.
local STALL_MS = 30000
-- A resume reuses an order at most this old; older, it starts at the minimum.
local ORDER_FRESH_MS = 30000
-- A stop the charger refused is tried again after this long.
local RETRY_STOP_MS = 60000

local MODEL_STATUS_LABELS = {
  [1]  = "overtemperature",
  [2]  = "waiting for RFID or app",
  [4]  = "force state off",
  [5]  = "scheduler",
  [6]  = "energy limit reached",
  [16] = "price fallback",
  [17] = "price fallback",
  [18] = "automatic stop fallback",
  [22] = "simulated unplugging",
  [23] = "phase switch",
  [24] = "minimum pause",
  [26] = "error",
  [27] = "load management",
  [28] = "OCPP",
  [29] = "reconnect delay",
  [30] = "adapter limit",
  [31] = "underfrequency control",
  [32] = "unbalanced load",
  [34] = "grid monitoring",
  [35] = "OCPP fallback",
  [37] = "OCPP inoperable",
  [38] = "undervoltage control",
  [39] = "zero setpoint",
  [40] = "initializing",
  [41] = "failsafe limit",
}

local base_url = nil
local identity_set = false

-- What the charger reported at the last good poll, updated by every write it
-- confirmed since. amp and frc are forgotten when a poll fails, so the next
-- order writes again rather than trusting an old reading.
local dev = {}
local measured_phases = nil
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

-- GET a URL and decode its JSON. Returns nil and a reason on any failure.
local function http_get_json(url)
  local ok, body, err = pcall(host.http_get, url)
  if not ok then return nil, tostring(body) end
  if not body then return nil, tostring(err or "no reply") end
  local ok2, data = pcall(host.json_decode, body)
  if not ok2 or type(data) ~= "table" then return nil, "reply is not JSON" end
  return data
end

local function device_max_a()
  local cap = MAX_A
  local var = num(dev.var)
  if var == 11 then cap = 16 end
  local ama = num(dev.ama)
  if ama and ama >= MIN_A and ama < cap then cap = ama end
  return cap
end

local function device_min_a()
  local mca = num(dev.mca)
  if mca and mca > MIN_A and mca <= MAX_A then return mca end
  return MIN_A
end

-- Whole amps per phase for a power order. Rounds down and never up.
local function amps_for(power_w, cmd)
  power_w = num(power_w)
  if not power_w or power_w <= 0 then return 0 end
  if type(cmd) ~= "table" then cmd = {} end
  local voltage = num(cmd.voltage)
  if not voltage or voltage < 100 then voltage = measured_v or 230 end
  -- Divide by one phase only when the installation is one-phase and the
  -- car is not measured on more, or Core asks for "1p" and the car is
  -- measured on exactly one. An idle charger proves nothing, so a
  -- three-phase car never gets a one-phase sum.
  local live = measured_phases or 0
  local phases = 3
  if (phases_cfg == 1 and live <= 1) or (cmd.phase_mode == "1p" and live == 1) then phases = 1 end
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

-- One key in one /api/set request. True only when the reply confirms it.
local function set_key(key, value)
  local query = key .. "=" .. string.format("%d", value)
  ftw_wrote = true
  local reply, err = http_get_json(base_url .. "/api/set?" .. query)
  if not reply then
    host.log("warn", "go-e: write " .. query .. " failed: " .. tostring(err))
    return false
  end
  if reply[key] ~= true then
    host.log("warn", string.format("go-e: charger refused %s: %s", query, tostring(reply[key])))
    return false
  end
  dev[key] = value
  return true
end

-- Bring the charger to amps (0 stops it). Writes only what differs, and
-- turns the charger on only after it confirmed the current.
local function apply(amps)
  if amps <= 0 then
    if dev.frc ~= FRC_OFF and not set_key("frc", FRC_OFF) then return false end
    left_on = false
    return true
  end
  if dev.amp ~= amps and not set_key("amp", amps) then return false end
  if dev.frc ~= FRC_ON and not set_key("frc", FRC_ON) then return false end
  left_on = true
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
    host.log("info", "go-e: no car; stopped the charger FTW had left on")
  else
    unplug_try_ms = now
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
  host.set_make("go-e")
end

function driver_poll()
  local data, err = http_get_json(base_url .. "/api/status?filter=" .. STATUS_KEYS)
  if not data then
    host.log("warn", "go-e: status read failed: " .. tostring(err))
    dev.amp, dev.frc = nil, nil
    measured_phases, measured_v = nil, nil
    stalled_since = nil
    return RETRY_MS
  end

  if not identity_set and type(data.sse) == "string" and data.sse ~= "" then
    host.set_sn(data.sse)
    if type(data.typ) == "string" and data.typ ~= "" then host.set_model(data.typ) end
    identity_set = true
  end

  dev.amp, dev.frc = num(data.amp), num(data.frc)
  dev.ama, dev.mca, dev.var = num(data.ama), num(data.mca), num(data.var)

  local nrg = type(data.nrg) == "table" and data.nrg or {}
  local v = { num(nrg[1]), num(nrg[2]), num(nrg[3]) }
  local a = { num(nrg[5]), num(nrg[6]), num(nrg[7]) }
  local w = { num(nrg[8]), num(nrg[9]), num(nrg[10]) }
  local power_w = num(nrg[12])
  if not power_w then
    -- Power is what Core reads first. Without it nothing is reported.
    host.log("warn", "go-e: status has no total power")
    measured_phases, measured_v = nil, nil
    return RETRY_MS
  end

  local active, v_sum, v_n = 0, 0, 0
  for i = 1, 3 do
    if a[i] and a[i] >= PHASE_ACTIVE_A then active = active + 1 end
    if v[i] and v[i] > 100 then v_sum, v_n = v_sum + v[i], v_n + 1 end
  end
  measured_phases = active > 0 and active or nil
  measured_v = v_n > 0 and (v_sum / v_n) or nil

  local car = num(data.car)
  local connected, charging = nil, nil
  if car == 1 then
    connected, charging = false, false
  elseif car == 2 then
    connected, charging = true, true
  elseif car == 3 or car == 4 then
    connected, charging = true, false
  end

  -- The car finished on its own: go-e reports car 4, "complete".
  local request_active = nil
  if car == 4 then request_active = false elseif car == 2 then request_active = true end

  -- Offered current: 0 while FTW (or the owner) forced the charger off.
  local max_a = dev.amp
  if dev.frc == FRC_OFF then max_a = 0 end

  local status = num(data.modelStatus)
  local reason = nil
  if connected and not charging and status then reason = MODEL_STATUS_LABELS[status] end

  -- Stalled: FTW turned the charger on with a usable current, a car waits,
  -- and the charger itself does not let it charge.
  local stalled = false
  local ordered_on = dev.frc == FRC_ON and (dev.amp or 0) >= MIN_A
  if car == 3 and ordered_on and data.alw == false then
    local now = host.millis()
    stalled_since = stalled_since or now
    stalled = (now - stalled_since) >= STALL_MS
  else
    stalled_since = nil
  end

  host.emit("ev", {
    w                       = power_w,
    connected               = connected,
    charging                = charging,
    request_active          = request_active,
    session_wh              = num(data.wh),
    lifetime_wh             = num(data.eto),
    max_a                   = max_a,
    current_limit_a         = num(data.acu),
    device_limit_a          = dev.ama,
    device_limit_age_s      = dev.ama and 0 or nil,
    phases                  = measured_phases,
    reason_no_current       = reason and status or nil,
    reason_no_current_label = reason,
    command_stalled         = stalled,
    l1_v = v[1], l2_v = v[2], l3_v = v[3],
    l1_a = a[1], l2_a = a[2], l3_a = a[3],
    l1_w = w[1], l2_w = w[2], l3_w = w[3],
  })

  stop_if_unplugged(connected, host.millis())
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
      host.log("warn", "go-e: Core's last cap leaves no room for the minimum current; not starting")
      return false
    end
    ok = apply(amps)
  else
    host.log("warn", "go-e: unknown action " .. tostring(action))
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
