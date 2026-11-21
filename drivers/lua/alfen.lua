-- Alfen Eve (NG9xx platform) EV charger over Modbus TCP
-- Emits: ev
-- Protocol: Modbus TCP, port 502, holding registers only (FC 03/06/16)
--
-- Source: Alfen "Modbus for ACE, Configuration Guide" v1.0 (May 2025,
-- firmware 4.10), appendix E, "Socket Measurement registers", and section
-- 4.2 "Maximum current". Older copies were titled "Implementation of Modbus
-- Slave TCP/IP for Alfen NG9xx platform"; the addresses are the same.
--
-- Unit id (the doc calls it server address):
--   1 / 2  socket 1 / socket 2 -- everything this driver reads and writes
--   200    station registers (identity, station status). This driver does
--          not read them: the host speaks to one unit id per driver, and
--          the socket is the one that carries the setpoint.
--
-- Registers used (all FLOAT32 unless noted, unit 1 or 2):
--   306..311   voltage L1-N, L2-N, L3-N (V)
--   320..325   current L1, L2, L3 (A)
--   344..345   real power sum (W)
--   374..377   real energy delivered sum (FLOAT64, Wh), lifetime
--   1200       availability (U16: 1 operative, 0 inoperative)
--   1201..1205 Mode 3 state (STRING, 5 regs: "A", "B1", "C2", ...)
--   1206..1207 actual applied max current (A): what the socket lets the car take
--   1208..1209 remaining valid time of our max current (UNSIGNED32, s)
--   1210..1211 Modbus server max current (A), read/write: the setpoint
--   1212..1213 active load balancing safe current (A)
--   1214       setpoint accounted for (U16: 1 yes, 0 no)
--   1215       charge using 1 or 3 phases (U16)
--
-- Earlier versions of this driver read 326 as voltage (it is current sum),
-- 346 as session energy (it is apparent power L1), 1201 as a number (it is
-- a 5-register string) and decoded NaN as 0. All four are fixed here.
--
-- Addresses. The 2025 guide also says to subtract 1 from a register number.
-- Its own tables, the older guide, evcc and the Home Assistant community
-- driver all use the table numbers as they stand (344 for power, 1210 for
-- the setpoint), and so does this driver.
--
-- Word order. The 2025 guide says 32-bit values are sent low word first.
-- Every working integration we know (evcc, the Home Assistant community
-- driver) reads and writes high word first. The driver starts with high word
-- first and switches only when the L1 voltage proves the other order: one
-- order gives a mains voltage, the other a number near zero. A write in the
-- wrong order lands as a tiny current, so the charger pauses rather than
-- over-charges.
--
-- Setup. The charger only takes a setpoint when the installer has, in ACE
-- Service Installer: Active Load Balancing on (a paid licence), data source
-- "Energy Management System", Modbus TCP/IP, "Allow writing maximum
-- currents" on, and a safe current set. Register 1214 says whether the
-- charger uses what we write.
--
-- Validity time. Each written max current is valid for the configured time
-- (default 60 s). When it runs out the charger falls back to its safe
-- current. The setpoint is also lost on reboot. So the driver rewrites its
-- setpoint at least every 15 s while Core sends orders, and sooner when the
-- charger reports less than 20 s left. When Core stops sending orders the
-- driver stops refreshing, and the charger returns to the installer's safe
-- current on its own. That is the device's designed answer to a missing
-- energy manager, and it is part of this driver's safe stand-down.
--
-- Sign convention: an EVSE is a one-way load. Positive W is charging.

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "alfen",
  name         = "Alfen Eve (NG9xx)",
  manufacturer = "Alfen",
  version      = "1.1.0",
  protocols    = { "modbus" },
  capabilities = { "ev" },
  description  = "Alfen Eve Single/Double Pro-line and S-line (NG9xx) over Modbus TCP. Telemetry and current-limit control through the Modbus server max current.",
  homepage     = "https://alfen.com",
  authors      = { "FTW contributors" },
  tested_models = { "Eve Single Pro-line", "Eve Double Pro-line", "Eve Single S-line" },
  verification_status = "experimental",
  verification_notes = "Control written from Alfen's Modbus for ACE configuration guide v1.0; not yet confirmed on hardware.",
  connection_defaults = {
    port    = 502,
    unit_id = 1,
  },
}

PROTOCOL = "modbus"

----------------------------------------------------------------------------
-- Registers
----------------------------------------------------------------------------
local REG_MEASURE   = 306   -- 306..377 in one read: voltages .. energy
local MEASURE_COUNT = 72
local REG_STATUS    = 1200  -- 1200..1215 in one read
local STATUS_COUNT  = 16
local REG_SETPOINT  = 1210  -- Modbus server max current, FLOAT32 r/w

----------------------------------------------------------------------------
-- Control limits
----------------------------------------------------------------------------
local MIN_A          = 6       -- IEC 61851 minimum; below it we write 0
local HW_MAX_A       = 32      -- NG9xx hardware maximum
local STEPS_PER_A    = 10      -- FLOAT32 setpoint: round down to 0.1 A
local REFRESH_MS     = 15000   -- rewrite well inside the 60 s default validity
local REFRESH_LEFT_S = 20      -- ... or sooner when the charger says so
local REFRESH_MIN_MS = 3000    -- never rewrite the same value faster than this
local READBACK_MS    = 30000   -- rewrite a value the charger lost, at this pace
local PAUSE_HOLD_MS  = 10000   -- keep a pause through Core's 3 s contactor cycle
local STALL_MS       = 30000
local ACTIVE_PHASE_A = 2       -- a phase carrying this much is in use
local WRITE_ATTEMPTS = 3       -- default mode stops after this many refusals

----------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------
local max_a_cfg = HW_MAX_A

local low_word_first = false   -- see "Word order" above
local order_known = false

local ordered_a = nil          -- Core's latest order, after every cap
local paused = false
local paused_at = 0
local written_a = nil          -- last value the charger accepted; nil = unknown
local written_at = 0
local commanded = false        -- FTW has written a setpoint in this process
local default_failures = 0

local readback_a = nil         -- register 1210 from the last poll
local valid_left_s = nil       -- register 1208 from the last poll
local seen_phases = 0          -- most phases seen carrying current this plug-in
local stall_since = nil

----------------------------------------------------------------------------
-- Reads
----------------------------------------------------------------------------

-- The host counts every failed modbus_read against the poll whether or not
-- Lua caught it, so a block this charger does not answer would cost a failed
-- read on every poll and the stale-telemetry watchdog would take the site
-- offline. Ask three times, since one miss can be a slow link, then leave it
-- alone until restart. No read sits on the command path, so giving up never
-- vetoes a command.
local GIVE_UP_AFTER = 3
local read_failures = {}

local function probe_read(addr, count, kind)
    if (read_failures[addr] or 0) >= GIVE_UP_AFTER then return nil end
    local ok, regs = pcall(host.modbus_read, addr, count, kind)
    if ok and regs and regs[count] ~= nil then
        read_failures[addr] = nil
        return regs
    end
    local failures = (read_failures[addr] or 0) + 1
    read_failures[addr] = failures
    if failures == GIVE_UP_AFTER then
        host.log("info", string.format(
            "Alfen: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

-- IEEE-754 float32 from two 16-bit words, high word first. Kept in Lua: this
-- is arithmetic, not I/O. Works on the halves, because combining them first
-- overflows a 32-bit integer build. NaN and infinity mean "not available"
-- (the charger fills absent registers with 0xFFFF), so they return nil.
local function decode_f32(hi, lo)
    if hi == nil or lo == nil then return nil end
    local sign = 1
    if hi >= 0x8000 then sign = -1; hi = hi - 0x8000 end
    local exponent = math.floor(hi / 128)
    local mantissa = (hi % 128) * 65536.0 + lo
    if exponent == 0xFF then return nil end
    if exponent == 0 then
        if mantissa == 0 then return 0 end
        return sign * mantissa * 2^-149
    end
    return sign * (1 + mantissa / 8388608.0) * 2^(exponent - 127)
end

-- IEEE-754 float64 from four 16-bit words, most significant first.
local function decode_f64(w1, w2, w3, w4)
    if w1 == nil or w2 == nil or w3 == nil or w4 == nil then return nil end
    local sign = 1
    if w1 >= 0x8000 then sign = -1; w1 = w1 - 0x8000 end
    local exponent = math.floor(w1 / 16)
    if exponent == 0x7FF then return nil end
    local mantissa = ((w1 % 16) * 65536.0 + w2) * 65536.0 * 65536.0
        + w3 * 65536.0 + w4
    if exponent == 0 then return 0 end -- subnormal: not a meter reading
    return sign * (1 + mantissa / 2^52) * 2^(exponent - 1023)
end

-- FLOAT32 words for a current. Only ever called with 0 or MIN_A..HW_MAX_A.
local function encode_f32(x)
    if x == nil or x <= 0 then return 0, 0 end
    local exponent = 0
    local m = x
    while m >= 2 do m = m / 2; exponent = exponent + 1 end
    while m < 1 do m = m * 2; exponent = exponent - 1 end
    local frac = math.floor((m - 1) * 8388608 + 0.5)
    if frac >= 8388608 then frac = 0; exponent = exponent + 1 end
    local hi = (exponent + 127) * 128 + math.floor(frac / 65536)
    local lo = frac % 65536
    return hi, lo
end

local function words(regs, base, addr, n)
    local i = addr - base + 1
    if n == 2 then
        if low_word_first then return regs[i + 1], regs[i] end
        return regs[i], regs[i + 1]
    end
    if low_word_first then return regs[i + 3], regs[i + 2], regs[i + 1], regs[i] end
    return regs[i], regs[i + 1], regs[i + 2], regs[i + 3]
end

local function f32_at(regs, base, addr)
    return decode_f32(words(regs, base, addr, 2))
end

local function u32_at(regs, base, addr)
    local hi, lo = words(regs, base, addr, 2)
    if hi == nil or lo == nil then return nil end
    if hi == 0xFFFF and lo == 0xFFFF then return nil end
    return hi * 65536.0 + lo
end

local function plausible_voltage(v)
    return v ~= nil and v >= 80 and v <= 300
end

-- Decide the word order from the L1 voltage, once. Until then (and on a
-- charger that reports 0 V) the high-word-first default stands.
local function learn_word_order(regs)
    if order_known then return end
    local a, b = regs[1], regs[2]
    local high_first = decode_f32(a, b)
    local low_first = decode_f32(b, a)
    if plausible_voltage(high_first) and not plausible_voltage(low_first) then
        low_word_first, order_known = false, true
    elseif plausible_voltage(low_first) and not plausible_voltage(high_first) then
        low_word_first, order_known = true, true
        host.log("info", "Alfen: charger sends 32-bit values low word first")
    end
end

-- Two ASCII characters per register, high byte first, ended by a zero.
local function decode_ascii(regs, from, n)
    local s = ""
    for i = from, from + n - 1 do
        local r = regs[i]
        if r == nil then break end
        local hi, lo = math.floor(r / 256), r % 256
        if hi == 0 then break end
        if hi < 32 or hi > 126 then return nil end
        s = s .. string.char(hi)
        if lo == 0 then break end
        if lo < 32 or lo > 126 then return nil end
        s = s .. string.char(lo)
    end
    return s
end

-- IEC 61851 Mode 3 states as the guide's appendix F lists them. A digit 1
-- means the charger sends no PWM: it is not offering current.
local MODE3 = {
    A  = { connected = false, charging = false },
    B1 = { connected = true,  charging = false, offering = false },
    B2 = { connected = true,  charging = false, offering = true,  request = false },
    C1 = { connected = true,  charging = false, offering = false, request = true },
    C2 = { connected = true,  charging = true,  offering = true,  request = true },
    D1 = { connected = true,  charging = false, offering = false, request = true },
    D2 = { connected = true,  charging = true,  offering = true,  request = true },
    E  = { connected = false, charging = false, fault = true },
    F  = { connected = false, charging = false, fault = true },
}

----------------------------------------------------------------------------
-- Control
----------------------------------------------------------------------------

local function num(v)
    if type(v) == "number" and v == v then return v end
    return nil
end

-- Watts to amps per phase, rounded down to the 0.1 A step. Phases is the
-- larger of Core's phase mode (1p is 1, anything else 3) and the phases seen
-- carrying current this plug-in, so a three-phase car on a one-phase order
-- never gets three times the power. The 0.001-step slack only absorbs float
-- error (4140 W / 690 V must be 6 A, not 5.9 A).
local function amps_for(power_w, cmd)
    power_w = num(power_w)
    if power_w == nil or power_w <= 0 then return 0 end
    cmd = type(cmd) == "table" and cmd or {}
    local voltage = num(cmd.voltage)
    if voltage == nil or voltage <= 0 then voltage = 230 end
    local phases = cmd.phase_mode == "1p" and 1 or 3
    if seen_phases > phases then phases = seen_phases end
    local amps = power_w / (voltage * phases)
    local cap = max_a_cfg
    local fuse = num(cmd.max_amps_per_phase)
    if fuse ~= nil and fuse > 0 and fuse < cap then cap = fuse end
    local room = num(cmd.cap_amps_per_phase)
    if room ~= nil and room >= 0 and room < cap then cap = room end
    if amps > cap then amps = cap end
    amps = math.floor(amps * STEPS_PER_A + 0.001) / STEPS_PER_A
    if amps < MIN_A then return 0 end
    return amps
end

local function write_setpoint(amps)
    local hi, lo = encode_f32(amps)
    local regs = low_word_first and { lo, hi } or { hi, lo }
    local ok, res = pcall(host.modbus_write_multi, REG_SETPOINT, regs)
    if not ok or (res ~= nil and res ~= true) then
        host.log("warn", "Alfen: writing max current " .. tostring(amps) ..
            " A failed: " .. tostring(res))
        written_a = nil
        return false
    end
    written_a, written_at = amps, host.millis()
    readback_a = nil       -- the next poll reads the new value
    default_failures = 0   -- one success proves the register takes writes
    return true
end

-- Write only on change, except for the refresh the validity time requires
-- and a value the charger lost (a reboot clears it).
local function apply(amps)
    local age = host.millis() - written_at
    local due = written_a ~= amps
    if not due and age >= REFRESH_MS then due = true end
    if not due and valid_left_s ~= nil and valid_left_s <= REFRESH_LEFT_S
        and age >= REFRESH_MIN_MS then
        due = true
    end
    if not due and readback_a ~= nil and math.abs(readback_a - amps) >= 0.05
        and age >= READBACK_MS then
        due = true
    end
    if not due then return true end
    local ok = write_setpoint(amps)
    if ok then commanded = true end
    return ok
end

----------------------------------------------------------------------------
-- Driver interface
----------------------------------------------------------------------------

function driver_init(config)
    host.set_make("Alfen")
    if type(config) == "table" then
        local cap = tonumber(config.max_a)
        if cap and cap >= MIN_A and cap < HW_MAX_A then max_a_cfg = cap end
    end
end

function driver_poll()
    local now = host.millis()
    local m = probe_read(REG_MEASURE, MEASURE_COUNT, "holding")
    local s = probe_read(REG_STATUS, STATUS_COUNT, "holding")

    if m then learn_word_order(m) end

    local power_w, energy_wh
    local v = {}
    local a = {}
    if m then
        power_w = f32_at(m, REG_MEASURE, 344)
        energy_wh = decode_f64(words(m, REG_MEASURE, 374, 4))
        for i = 1, 3 do
            v[i] = f32_at(m, REG_MEASURE, 304 + 2 * i)  -- 306, 308, 310
            a[i] = f32_at(m, REG_MEASURE, 318 + 2 * i)  -- 320, 322, 324
        end
    end

    local state, applied_a, safe_a, accounted, phase_setting, available
    readback_a, valid_left_s = nil, nil
    if s then
        available = s[1]
        state = MODE3[decode_ascii(s, 2, 5) or ""]
        applied_a = f32_at(s, REG_STATUS, 1206)
        valid_left_s = u32_at(s, REG_STATUS, 1208)
        readback_a = f32_at(s, REG_STATUS, 1210)
        safe_a = f32_at(s, REG_STATUS, 1212)
        accounted = s[15]
        phase_setting = s[16]
    end

    local connected = state and state.connected
    local charging = state and state.charging

    -- Phases in use, remembered for the plug-in so a pause does not make a
    -- three-phase car look single-phase again.
    if connected == false then
        seen_phases = 0
    elseif charging then
        local active = 0
        for i = 1, 3 do
            if a[i] and a[i] >= ACTIVE_PHASE_A then active = active + 1 end
        end
        if active > seen_phases then seen_phases = active end
    end

    -- Stalled: we offer at least the minimum, the car is plugged in, and the
    -- charger has sent no PWM for 30 s.
    local stalled = false
    if connected and (written_a or 0) >= MIN_A and state.offering == false then
        stall_since = stall_since or now
        stalled = (now - stall_since) >= STALL_MS
    else
        stall_since = nil
    end

    local reason
    if connected and not charging then
        if available == 0 then
            reason = "charger not operative"
        elseif accounted == 0 and (written_a or 0) >= MIN_A then
            reason = "charger ignores the Modbus setpoint"
        elseif state.request == false then
            reason = "vehicle not requesting current"
        elseif written_a == 0 then
            reason = "current limit below minimum"
        elseif state.offering == false then
            reason = "charger not offering current"
        end
    end

    local phases
    if seen_phases > 0 then
        phases = seen_phases
    elseif phase_setting == 1 or phase_setting == 3 then
        phases = phase_setting
    end

    -- Power is the defining reading: without it there is nothing to report.
    if power_w ~= nil then
        host.emit("ev", {
            w               = power_w,
            connected       = connected,
            charging        = charging,
            request_active  = state and state.request,
            total_charge_wh = energy_wh,
            l1_v = v[1], l2_v = v[2], l3_v = v[3],
            l1_a = a[1], l2_a = a[2], l3_a = a[3],
            max_a           = readback_a,
            current_limit_a = applied_a,
            phases          = phases,
            reason_no_current_label = reason,
            command_stalled = stalled,
        })
    end

    if valid_left_s then host.emit_metric("ev_setpoint_valid_s", valid_left_s, "s") end
    if safe_a then host.emit_metric("ev_safe_current_a", safe_a, "A") end
    if accounted == 0 or accounted == 1 then
        host.emit_metric("ev_setpoint_accounted", accounted)
    end

    return 5000
end

function driver_command(action, power_w, cmd)
    if action == "init" or action == "deinit" then
        return true
    end
    local now = host.millis()

    if action == "ev_set_current" then
        local amps = amps_for(power_w, cmd)
        ordered_a = amps
        if paused and amps > 0 and (now - paused_at) >= PAUSE_HOLD_MS then
            paused = false
        end
        return apply(paused and 0 or amps)
    end

    if action == "ev_pause" then
        paused, paused_at = true, now
        return apply(0)
    end

    if action == "ev_resume" or action == "ev_start" then
        paused = false
        -- No order yet: the next ev_set_current sets the current.
        if ordered_a == nil then return true end
        return apply(ordered_a)
    end

    host.log("warn", "Alfen: unknown action " .. tostring(action))
    return false
end

-- Stand down: write 0 A once and stop refreshing. When the validity time
-- runs out the charger goes to its own safe current. Nothing is written if
-- FTW never wrote a setpoint in this process, so a telemetry-only site keeps
-- charging as its installer set it up.
function driver_default_mode()
    ordered_a, paused = 0, false
    if not commanded or written_a == 0 then return true end
    -- A charger that refuses the write would otherwise be asked again on
    -- every watchdog tick for the life of the session.
    if default_failures >= WRITE_ATTEMPTS then return true end
    if write_setpoint(0) then return true end
    default_failures = default_failures + 1
    return false
end

function driver_cleanup()
end
