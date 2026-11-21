-- go-e Charger, Modbus TCP
-- Emits: EV
-- Protocol: Modbus TCP, port 502. Turn on Modbus in the go-e app
-- (Internet > Advanced settings > Modbus) or with /api/set?men=true.
--
-- Source: go-e's own Modbus documentation for API v2 firmware,
--   https://github.com/goecharger/go-eCharger-API-v2/blob/main/modbus-en.md
-- Word order for 32-bit values is high word first, as go-e's API v1 Modbus
-- document states. Firmware 60.3 swapped the byte order by mistake; 60.4
-- fixed it. Leave "swap bytes" and "swap registers" (msb, msr) off.
--
-- The registers this driver reads (wire address):
--   input 100      CAR_STATE  0 unknown, 1 ready (no car), 2 charging,
--                              3 waiting for the car, 4 finished, car connected
--   input 107      ERROR
--   input 108..113 VOLT_L1..L3, u32, V
--   input 114..119 AMP_L1..L3,  u32, 0.1 A
--   input 120..121 POWER_TOTAL, u32, 0.01 W
--   input 128..129 ENERGY_TOTAL, u32, 0.1 kWh
--   input 132..133 ENERGY_CHARGE, u32, 10 Ws, this charging session
--   input 200      ALLOW      1 when the charger lets the car charge
--   input 304..309 serial number, ASCII
--   holding 211    AMPERE_MAX the owner's maximum current, A
--   holding 299    AMPERE_VOLATILE  current offer, 6..32 A, not saved to EEPROM
--   holding 337    FORCE_STATE 0 neutral, 1 off, 2 on (firmware 55.6 and later)
--
-- The registers this driver writes. go-e accepts writes only with function
-- 16 (write multiple registers); function 6 is not implemented.
--   299 AMPERE_VOLATILE  the current. Not 300, AMPERE_EEPROM, which go-e
--                        rates for about 100 000 writes.
--   337 FORCE_STATE      1 stops the charger, 2 lets it charge
--
-- Control:
--   An order of power_w becomes whole amps per phase, rounded down:
--     amps = floor(power_w / (voltage * phases))
--   phases is 3 unless the installation is one-phase (config.phases = 1) and
--   the car is not measured on more than one phase, or Core asks for "1p" and
--   the car is measured on exactly one. An idle charger counts as
--   three-phase, so a three-phase car never gets a one-phase sum. The result
--   never exceeds Core's max_amps_per_phase or cap_amps_per_phase, the
--   owner's AMPERE_MAX or 32 A. Below 6 A the charger is stopped with
--   FORCE_STATE=1; an order is never rounded up. Only registers that differ
--   from what the charger last reported are written.
--   driver_default_mode stops the charger (FORCE_STATE=1), once, and only
--   after FTW has written to it in this run. Core runs it at every start.
--
-- FORCE_STATE is a setting, so it stays where FTW left it. If FTW stops, the
-- charger stays off until FTW starts it again or the owner sets it to neutral
-- in the go-e app. AMPERE_VOLATILE returns to the saved current on a reboot.
--
-- Sign convention: w is positive while the car charges. go-e cannot
-- discharge a car.
--
-- Config:
--   phases   optional 1 or 3, the installation's phase count (default 3)

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "goe",
  name         = "go-e Charger (Modbus TCP)",
  manufacturer = "go-e",
  version      = "1.1.0",
  protocols    = { "modbus" },
  capabilities = { "ev" },
  description  = "go-e Charger with API v2 firmware over Modbus TCP. Reads power, phases and session energy, and sets the charging current and start/stop (firmware 55.6 or later).",
  homepage     = "https://go-e.com",
  authors      = { "FTW contributors" },
  tested_models = { "Gemini flex 11kW", "Gemini flex 22kW", "go-e Pro" },
  verification_status = "experimental",
  verification_notes = "Control written from go-e's Modbus documentation for API v2 firmware; not yet confirmed on hardware.",
  connection_defaults = {
    port    = 502,
    unit_id = 1,
  },
}

PROTOCOL = "modbus"

local POLL_MS = 5000

local REG_CAR_STATE    = 100   -- input
local REG_MEASURE      = 107   -- input, 15 registers: ERROR .. POWER_TOTAL
local REG_ENERGY_TOTAL = 128   -- input, u32, 0.1 kWh
local REG_ENERGY_CHARGE = 132  -- input, u32, 10 Ws
local REG_ALLOW        = 200   -- input
local REG_SERIAL       = 304   -- input, 6 registers
local REG_AMPERE_MAX   = 211   -- holding
local REG_AMPERE_VOLATILE = 299 -- holding, written
local REG_FORCE_STATE  = 337   -- holding, written

local MIN_A = 6
local MAX_A = 32
local FRC_OFF, FRC_ON = 1, 2

local PHASE_ACTIVE_A = 1.0
local STALL_MS = 30000
local DEFAULT_ATTEMPTS = 3

----------------------------------------------------------------------------
-- Absent-register guard
----------------------------------------------------------------------------
-- The host counts every failed modbus_read against the poll whether or not
-- Lua caught it. A register this driver can live without stops being read
-- once it has failed three times in a row; a restart asks again. The car
-- state and the measurement block are read every poll: without them there
-- is nothing to report, and nothing is reported.
local GIVE_UP_AFTER = 3
local read_failures = {}

local function read_block(addr, count, kind)
  local ok, regs = pcall(host.modbus_read, addr, count, kind)
  if ok and type(regs) == "table" and #regs >= count then return regs end
  return nil
end

local function probe_read(addr, count, kind)
  if (read_failures[addr] or 0) >= GIVE_UP_AFTER then return nil end
  local regs = read_block(addr, count, kind)
  if regs then
    read_failures[addr] = nil
    return regs
  end
  local failures = (read_failures[addr] or 0) + 1
  read_failures[addr] = failures
  if failures == GIVE_UP_AFTER then
    host.log("info", string.format(
      "go-e: register %d did not answer %d times; leaving it alone " ..
      "until restart", addr, GIVE_UP_AFTER))
  end
  return nil
end

----------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------

-- What the charger reported, updated by every write it took. amp and frc
-- are forgotten when the measurement read fails, so the next order writes
-- again rather than trusting an old reading.
local dev = {}
local measured_phases = nil
local measured_v = nil
local serial_set = false

local phases_cfg = 3           -- config.phases: the installation's phase count
-- Core runs driver_default_mode at every start. It stands down only after FTW
-- wrote to the charger in this run, or found it already holding FTW's order,
-- so a charger FTW never steered keeps the owner's own setting.
local ftw_wrote = false
local last_order_a = nil
local stood_down = false
local default_failures = 0
local stalled_since = nil

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

-- Work on the 16-bit halves: a 32-bit Lua build overflows hi * 65536.
local function u32(hi, lo)
  return hi * 65536.0 + lo
end

local function decode_ascii(regs)
  local out = {}
  for i = 1, #regs do
    local hi, lo = math.floor(regs[i] / 256), regs[i] % 256
    for _, b in ipairs({ hi, lo }) do
      if b >= 32 and b < 127 then out[#out + 1] = string.char(b) end
    end
  end
  return (table.concat(out):gsub("%s+$", ""))
end

local function device_max_a()
  local ama = dev.ama
  if ama and ama >= MIN_A and ama < MAX_A then return ama end
  return MAX_A
end

-- Whole amps per phase for a power order. Rounds down and never up.
local function amps_for(power_w, cmd)
  if type(power_w) ~= "number" or power_w ~= power_w or power_w <= 0 then return 0 end
  if type(cmd) ~= "table" then cmd = {} end
  local voltage = type(cmd.voltage) == "number" and cmd.voltage or nil
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
  local max_cmd = cmd.max_amps_per_phase
  if type(max_cmd) == "number" and max_cmd > 0 and max_cmd < limit then limit = max_cmd end
  local cap_cmd = cmd.cap_amps_per_phase
  if type(cap_cmd) == "number" and cap_cmd >= 0 and cap_cmd < limit then limit = cap_cmd end
  limit = math.floor(limit + 0.001)
  if amps > limit then amps = limit end
  if amps < MIN_A then return 0 end
  return amps
end

local function write_one(addr, value, what)
  ftw_wrote = true
  local ok, err = pcall(host.write_registers, addr, { value })
  if ok and (err == nil or err == "") then return true end
  host.log("warn", string.format("go-e: write %s=%d failed: %s", what, value, tostring(err)))
  return false
end

-- Bring the charger to amps (0 stops it). Writes only what differs.
local function apply(amps)
  if amps <= 0 then
    if dev.frc == FRC_OFF then return true end
    if not write_one(REG_FORCE_STATE, FRC_OFF, "FORCE_STATE") then return false end
    dev.frc = FRC_OFF
    return true
  end
  if dev.amp ~= amps then
    if not write_one(REG_AMPERE_VOLATILE, amps, "AMPERE_VOLATILE") then return false end
    dev.amp = amps
  end
  if dev.frc ~= FRC_ON then
    if not write_one(REG_FORCE_STATE, FRC_ON, "FORCE_STATE") then return false end
    dev.frc = FRC_ON
  end
  return true
end

----------------------------------------------------------------------------
-- Driver interface
----------------------------------------------------------------------------

function driver_init(config)
  config = config or {}
  local p = tonumber(config.phases)
  if p == 1 or p == 3 then phases_cfg = p end
  host.set_make("go-e")
end

function driver_poll()
  local st = read_block(REG_CAR_STATE, 1, "input")
  local m = st and read_block(REG_MEASURE, 15, "input")
  if not m then
    host.log("warn", "go-e: state or measurement read failed")
    dev.amp, dev.frc = nil, nil
    measured_phases, measured_v = nil, nil
    stalled_since = nil
    return POLL_MS
  end

  if not serial_set then
    local sn = probe_read(REG_SERIAL, 6, "input")
    if sn then
      local s = decode_ascii(sn)
      if s ~= "" then host.set_sn(s) end
      serial_set = true
    end
  end

  -- m[1] is ERROR (107); the pairs that follow start at 108.
  local v = { u32(m[2], m[3]), u32(m[4], m[5]), u32(m[6], m[7]) }
  local a = { u32(m[8], m[9]) / 10, u32(m[10], m[11]) / 10, u32(m[12], m[13]) / 10 }
  local power_w = u32(m[14], m[15]) / 100

  local active, v_sum, v_n = 0, 0, 0
  for i = 1, 3 do
    if a[i] >= PHASE_ACTIVE_A then active = active + 1 end
    if v[i] > 100 and v[i] < 300 then v_sum, v_n = v_sum + v[i], v_n + 1 end
  end
  measured_phases = active > 0 and active or nil
  measured_v = v_n > 0 and (v_sum / v_n) or nil

  local max_regs = probe_read(REG_AMPERE_MAX, 1, "holding")
  if max_regs then
    local ama = max_regs[1]
    dev.ama = (ama >= MIN_A and ama <= MAX_A) and ama or nil
  end
  local amp_regs = probe_read(REG_AMPERE_VOLATILE, 1, "holding")
  if amp_regs then
    local amp = amp_regs[1]
    dev.amp = (amp >= MIN_A and amp <= MAX_A) and amp or nil
  end
  local frc_regs = probe_read(REG_FORCE_STATE, 1, "holding")
  if frc_regs then
    local frc = frc_regs[1]
    dev.frc = (frc >= 0 and frc <= 2) and frc or nil
  end
  local allow_regs = probe_read(REG_ALLOW, 1, "input")
  local allow = allow_regs and allow_regs[1] or nil

  local session_wh, lifetime_wh = nil, nil
  local e = probe_read(REG_ENERGY_TOTAL, 2, "input")
  if e then lifetime_wh = u32(e[1], e[2]) * 100 end
  local s = probe_read(REG_ENERGY_CHARGE, 2, "input")
  if s then session_wh = u32(s[1], s[2]) * 10 / 3600 end

  local car = st[1]
  local connected, charging = nil, nil
  if car == 1 then
    connected, charging = false, false
  elseif car == 2 then
    connected, charging = true, true
  elseif car == 3 or car == 4 then
    connected, charging = true, false
  end
  local request_active = nil
  if car == 4 then request_active = false elseif car == 2 then request_active = true end

  local max_a = dev.amp
  if dev.frc == FRC_OFF then max_a = 0 end

  local stalled = false
  local ordered_on = dev.frc == FRC_ON and (dev.amp or 0) >= MIN_A
  if car == 3 and ordered_on and allow == 0 then
    local now = host.millis()
    stalled_since = stalled_since or now
    stalled = (now - stalled_since) >= STALL_MS
  else
    stalled_since = nil
  end

  host.emit("ev", {
    w                  = power_w,
    connected          = connected,
    charging           = charging,
    request_active     = request_active,
    session_wh         = session_wh,
    lifetime_wh        = lifetime_wh,
    max_a              = max_a,
    device_limit_a     = dev.ama,
    device_limit_age_s = max_regs and dev.ama and 0 or nil,
    phases             = measured_phases,
    command_stalled    = stalled,
    l1_v = v[1], l2_v = v[2], l3_v = v[3],
    l1_a = a[1], l2_a = a[2], l3_a = a[3],
  })

  return POLL_MS
end

function driver_command(action, power_w, cmd)
  if action == "init" or action == "deinit" then return true end

  local ok
  if action == "ev_set_current" then
    local amps = amps_for(power_w, cmd)
    ok = apply(amps)
    if ok and amps > 0 then last_order_a = amps end
  elseif action == "ev_pause" then
    ok = apply(0)
  elseif action == "ev_resume" or action == "ev_start" then
    local amps = last_order_a or MIN_A
    if amps > device_max_a() then amps = device_max_a() end
    amps = math.floor(amps)
    ok = apply(amps)
  else
    host.log("warn", "go-e: unknown action " .. tostring(action))
    return false
  end
  if ok then
    ftw_wrote = true
    stood_down = false
    default_failures = 0
  end
  return ok
end

-- Stand down when FTW can no longer steer: stop the charger once. After
-- DEFAULT_ATTEMPTS refusals in a row it stops trying and reports the default
-- as held, so a charger that will not take the write is not written every tick.
function driver_default_mode()
  if not ftw_wrote or stood_down then return true end
  if default_failures >= DEFAULT_ATTEMPTS then return true end
  if apply(0) then
    stood_down = true
    default_failures = 0
    return true
  end
  default_failures = default_failures + 1
  return false
end

function driver_cleanup()
end
