-- Etrel INCH EV charger (Modbus TCP)
-- Emits: ev
-- Controls: charging current per phase, pause and resume.
--
-- Register map: Etrel's "INCH SmartHome Modbus TCP Registers" list. The copy
-- this driver was written from is the 2023 sheet kept in
-- github.com/RustyDust/sonnen-charger. Etrel now publishes V6.0 (August 2025)
-- in its Knowledge Centre (page "Modbus Communication with INCH products"),
-- which needs firmware 7.1.1 for every register. V6.0 was not checked here.
--
--   Input registers, function code 4, big-endian words and bytes:
--     0       connector status (Int16, see STATUS below)
--     4..5    target current from power management or Modbus (Float32, A)
--     8..13   L1..L3 voltage (Float32, V)
--     14..19  L1..L3 current (Float32, A)
--     26..27  total active power (Float32, kW)
--     30..31  energy of the running session (Float32, kWh)
--     990     serial number (10 registers, ASCII)
--     1000    model (10 registers, ASCII)
--     1015    software version (5 registers, ASCII)
--     1028..9 custom max current (Float32, A), set by the installer
--
--   Holding registers, function code 16 only:
--     8..9    set current setpoint (Float32, A). Exception 12 means
--             "current setpoint too high".
--
-- The list also has "pause charging" (2) and "stop charging" (1). Both are
-- one-way triggers, and the list names no register that undoes them, so this
-- driver never writes them. It pauses by writing a 0 A setpoint, as evcc's
-- Etrel charger does, and resumes by writing a current again. "Cancel current
-- setpoint" (10) hands the charger back to its own limit, which is the full
-- installation current, so it is not a safe stand-down either.
--
-- Not covered: the second connector of an INCH Duo. evcc and the Home
-- Assistant integration ha-etrel-inch address it 100 registers higher, but the
-- register list used here does not say so.
--
-- Session energy: evcc found register 30 stays 0 on some firmware
-- (evcc-io/evcc#5346). A zero is left out rather than reported, since it
-- cannot be told from a real one.
--
-- Watchdog: ha-etrel-inch reports two charger settings, a monitoring interval
-- and a fallback current the charger takes when Modbus goes quiet. This driver
-- polls every 5 s. Set the monitoring interval above that if it is used.
--
-- Config: `phases: 1` on a one-phase installation. Otherwise an order is
-- split over three phases unless Core orders one phase and the car draws on
-- exactly one.
--
-- Sign convention: an EVSE is a one-way load, so `w` is positive while the car
-- charges, as the charger reports it.

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "etrel",
  name         = "Etrel INCH",
  manufacturer = "Etrel",
  version      = "1.1.1",
  protocols    = { "modbus" },
  capabilities = { "ev" },
  description  = "Etrel INCH Home, Pro and Duo (connector 1) over Modbus TCP. Reads power, phase currents and charger state, and sets the charging current. Enable Modbus in the charger's web interface.",
  setup_hint   = "Turn on Modbus TCP in the charger web interface.",
  homepage     = "https://etrel.com",
  authors      = { "FTW contributors" },
  tested_models = { "INCH Home", "INCH Pro", "INCH Duo" },
  verification_status = "experimental",
  verification_notes = "Control written from Etrel's INCH SmartHome Modbus TCP register list; not yet confirmed on hardware.",
  connection_defaults = {
    port    = 502,
    unit_id = 1,
  },
}

PROTOCOL = "modbus"

local REG_BLOCK        = 0     -- input 0..31, read in one request
local BLOCK_COUNT      = 32
local REG_SERIAL       = 990   -- input, 10 registers
local REG_MODEL        = 1000  -- input, 10 registers
local REG_SW_VERSION   = 1015  -- input, 5 registers
local REG_CUSTOM_MAX   = 1028  -- input, Float32 A
local REG_SET_CURRENT  = 8     -- holding, Float32 A, function code 16

local MIN_A = 6                -- IEC 61851 minimum; below it the car gets 0 A
local MAX_A = 32               -- the largest INCH model
local STEP_A = 0.1             -- the setpoint is a float; keep tenths

local STATUS = {
    [0] = "unknown",
    [1] = "socket_available",
    [2] = "waiting_for_vehicle",
    [3] = "waiting_for_vehicle_to_start",
    [4] = "charging",
    [5] = "paused_by_vehicle",
    [6] = "paused_by_charger",
    [7] = "charging_ended",
    [8] = "fault",
    [9] = "resuming",
    [10] = "unavailable",
}
-- A car is plugged in for these. 1 and 2 mean no car. 0, 8 and 10 say
-- nothing about the cable, so connected stays unknown for them.
local CONNECTED = { [3] = true, [4] = true, [5] = true, [6] = true, [7] = true, [9] = true }

----------------------------------------------------------------------------
-- Reads
----------------------------------------------------------------------------

-- The host counts every failed modbus_read against the poll whether or not
-- Lua caught it. A register the charger does not answer therefore costs a
-- failed read on every poll, and the site goes offline. Three tries, then
-- leave it alone. Core reloads the driver once nothing is left to read, so an
-- outage does not silence it for good.
local GIVE_UP_AFTER = 3
local read_failures = {}

local function probe_read(addr, count, kind)
    if (read_failures[addr] or 0) >= GIVE_UP_AFTER then return nil end
    local ok, regs = pcall(host.modbus_read, addr, count, kind)
    if ok and type(regs) == "table" and regs[count] ~= nil then
        read_failures[addr] = nil
        return regs
    end
    local failures = (read_failures[addr] or 0) + 1
    read_failures[addr] = failures
    if failures == GIVE_UP_AFTER then
        host.log("info", string.format(
            "Etrel: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

-- IEEE-754 binary32 from two big-endian registers. Works on the 16-bit
-- halves so a build with 32-bit integers cannot flip the sign. NaN and
-- infinity come back nil: a number that is not finite is not a reading.
local function decode_f32_be(hi, lo)
    if type(hi) ~= "number" or type(lo) ~= "number" then return nil end
    local sign = 1
    if hi >= 0x8000 then sign = -1; hi = hi - 0x8000 end
    local exponent = math.floor(hi / 128)
    local mantissa = (hi % 128) * 65536 + lo
    if exponent == 0xFF then return nil end
    if exponent == 0 then
        if mantissa == 0 then return 0 end
        return sign * mantissa * 2^-149
    end
    return sign * (1 + mantissa / 0x800000) * 2^(exponent - 127)
end

-- The two registers of a binary32, for the current setpoint only: 0 or a
-- current between 0.1 and MAX_A.
local function encode_f32_be(value)
    if value <= 0 then return 0, 0 end
    local exponent = 0
    local m = value
    while m >= 2 do m = m / 2; exponent = exponent + 1 end
    while m < 1 do m = m * 2; exponent = exponent - 1 end
    local fraction = math.floor((m - 1) * 0x800000 + 0.5)
    if fraction >= 0x800000 then fraction = 0; exponent = exponent + 1 end
    local hi = (exponent + 127) * 128 + math.floor(fraction / 65536)
    local lo = fraction % 65536
    return hi, lo
end

local function ascii(regs, first, count)
    local ok, text = pcall(host.decode_string, regs, first, count)
    if not ok or type(text) ~= "string" then return "" end
    return (text:gsub("[^%w%-%._/ ]", ""))
end

----------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------

local identity_read = false
local device_limit_a, device_limit_ms = nil, nil
local device_limit_due_ms = nil

-- What the charger last took from this driver. nil means unknown: the next
-- order writes whatever it is.
local written_a = nil
local written_ms = nil
-- The last order: its current (nil for 0 A), when it came, and the lowest
-- per-phase limit Core named with it. Core sends ev_resume and ev_start with
-- no budget, so a resume trusts only a fresh order and that limit.
local order_a, order_ms = nil, nil
local last_cap_a = nil
local resume_wait_logged = false
-- True from a successful command write until the stand-down lands. While it
-- is true the poll checks that the charger still follows the order.
local steering = false
-- True while a current above zero that this driver wrote may still stand.
local order_landed = false
-- True once a command has tried to write in this run. Core runs default mode
-- at every start, so until then the stand-down leaves the charger alone: a
-- charger FTW never steered keeps its own setpoint, and a charge already
-- running goes on. The same rule as heishamon 0.8.1.
local ftw_wrote = false

-- Core treats a default mode that returns true as a charger stood down, so
-- true means confirmed (or nothing of FTW's to take back). A refused
-- stand-down returns false and is tried again at most once a minute, without
-- writing in between.
local STANDDOWN_RETRY_MS = 60000
local standdown_tried_ms = nil

-- Config `phases`: 1 for a one-phase installation, otherwise three.
local installed_phases = 3
-- Phases the car drew on at the latest poll, and the most it drew on since
-- it was plugged in.
local drawing_phases = 0
local seen_phases = 0

-- Fresh readings from the latest poll, for the command path.
local last_status = nil
local last_connected = nil
local stalled_since_ms = nil
local stall_rewrite_ms = nil

local ORDER_SETTLE_MS = 30000
local ORDER_FRESH_MS = 30000
local DEVICE_LIMIT_EVERY_MS = 60000

----------------------------------------------------------------------------
-- Orders
----------------------------------------------------------------------------

local function finite_positive(v)
    return type(v) == "number" and v == v and v > 0 and v < math.huge
end

-- Three phases, unless one phase is certain:
--   * the installation is one-phase (config) and the car has not drawn on
--     more than one phase since it was plugged in, or
--   * Core orders one phase and the car draws on exactly one.
-- An idle or just-started charger counts as three. Core budgets only L1 for a
-- one-phase order, so a three-phase car must never get that sum per phase.
local function phases_for(cmd)
    if installed_phases == 1 and seen_phases <= 1 then return 1 end
    if type(cmd) == "table" and cmd.phase_mode == "1p" and
       seen_phases == 1 and drawing_phases == 1 then
        return 1
    end
    return 3
end

-- The lowest per-phase limit an order names, or nil when it names none.
local function cap_of(cmd)
    local cap = nil
    if type(cmd) == "table" then
        for _, key in ipairs({ "max_amps_per_phase", "cap_amps_per_phase" }) do
            local v = cmd[key]
            if finite_positive(v) and (cap == nil or v < cap) then cap = v end
        end
    end
    return cap
end

-- Core orders total power. The charger takes a current per phase.
--
--   phases  see phases_for
--   amps    power / (voltage * phases), never above Core's max and cap per
--           phase or the charger's own limit, rounded down to 0.1 A
--   below   MIN_A gives 0 A. A current is never rounded up to the minimum.
local function amps_for(power_w, cmd)
    local phases = phases_for(cmd)
    if type(power_w) ~= "number" or power_w ~= power_w or power_w <= 0 then
        return 0, phases
    end
    local voltage = 230
    if type(cmd) == "table" and finite_positive(cmd.voltage) then voltage = cmd.voltage end
    local ceiling = MAX_A
    if device_limit_a and device_limit_a > 0 and device_limit_a < ceiling then
        ceiling = device_limit_a
    end
    if type(cmd) == "table" then
        for _, key in ipairs({ "max_amps_per_phase", "cap_amps_per_phase" }) do
            local v = cmd[key]
            if finite_positive(v) and v < ceiling then ceiling = v end
        end
    end
    local amps = power_w / (voltage * phases)
    if amps > ceiling then amps = ceiling end
    -- The small allowance absorbs float error in a division Core meant to be
    -- exact; it is a ten-thousandth of an ampere, not a rounding up.
    amps = math.floor(amps / STEP_A + 0.001) * STEP_A
    if amps < MIN_A then return 0, phases end
    return amps, phases
end

local function write_current(amps)
    if written_a ~= nil and math.abs(written_a - amps) < 0.05 then return true end
    local hi, lo = encode_f32_be(amps)
    -- Default mode writes only once this is set, so only a command sets it.
    ftw_wrote = true
    local ok, err = pcall(host.modbus_write_multi, REG_SET_CURRENT, { hi, lo })
    if not ok or (err ~= nil and err ~= true and err ~= "") then
        -- The charger may hold the old setpoint or the new one.
        written_a = nil
        host.log("warn", "Etrel: current setpoint " .. tostring(amps) ..
            " A not written: " .. tostring(ok and err or "error"))
        return false
    end
    written_a, written_ms = amps, host.millis()
    order_landed = amps > 0
    return true
end

----------------------------------------------------------------------------
-- Driver interface
----------------------------------------------------------------------------

function driver_init(config)
    host.set_make("Etrel")
    if type(config) == "table" and tonumber(config.phases) == 1 then
        installed_phases = 1
    end
end

local function read_identity()
    if identity_read then return end
    local regs = probe_read(REG_SERIAL, 30, "input")
    if not regs then return end
    identity_read = true
    local serial = ascii(regs, 1, 10)
    local model = ascii(regs, REG_MODEL - REG_SERIAL + 1, 10)
    local software = ascii(regs, REG_SW_VERSION - REG_SERIAL + 1, 5)
    if #serial > 0 then host.set_sn(serial) end
    if #model > 0 then host.set_model(model) end
    if #software > 0 then host.log("info", "Etrel: software " .. software) end
end

local function read_device_limit(now)
    if device_limit_due_ms and now < device_limit_due_ms then return end
    device_limit_due_ms = now + DEVICE_LIMIT_EVERY_MS
    local regs = probe_read(REG_CUSTOM_MAX, 2, "input")
    local limit = regs and decode_f32_be(regs[1], regs[2])
    if limit and limit > 0 and limit <= 80 then
        device_limit_a, device_limit_ms = limit, now
    end
end

function driver_poll()
    local now = host.millis()
    read_identity()
    read_device_limit(now)

    local regs = probe_read(REG_BLOCK, BLOCK_COUNT, "input")
    if not regs then
        last_status, last_connected, drawing_phases = nil, nil, 0
        return 5000
    end

    local status = regs[1]
    if status ~= nil and STATUS[status] == nil then status = nil end
    local target_a = decode_f32_be(regs[5], regs[6])
    local volts, amps = {}, {}
    for i = 1, 3 do
        volts[i] = decode_f32_be(regs[9 + 2 * (i - 1)], regs[10 + 2 * (i - 1)])
        amps[i] = decode_f32_be(regs[15 + 2 * (i - 1)], regs[16 + 2 * (i - 1)])
    end
    local kw = decode_f32_be(regs[27], regs[28])
    local session_kwh = decode_f32_be(regs[31], regs[32])

    local w = kw and kw * 1000 or nil
    local connected = nil
    if status == 1 or status == 2 then connected = false end
    if status and CONNECTED[status] then connected = true end
    local charging = nil
    if status ~= nil and status ~= 0 then charging = status == 4 end

    local measured = 0
    for i = 1, 3 do
        if amps[i] and amps[i] >= 1 then measured = measured + 1 end
    end
    last_status, last_connected = status, connected
    -- A new car starts unseen: a one-phase car after a three-phase one may
    -- use one phase again.
    if connected == false then seen_phases = 0 end
    drawing_phases = measured
    if measured > seen_phases then seen_phases = measured end

    -- A charger that lets the car take more than this driver ordered has lost
    -- the order, after a restart for example. Forget what was written so the
    -- next order writes it again. Only once the order has had time to land.
    if steering and written_a ~= nil and target_a and connected and
       written_ms and now - written_ms >= ORDER_SETTLE_MS and
       target_a > written_a + 0.5 then
        host.log("warn", string.format(
            "Etrel: charger allows %.1f A against an order of %.1f A; writing it again",
            target_a, written_a))
        written_a = nil
    end

    -- The current the charger lets the car take now, when it is below the
    -- order and the order has stood long enough to be followed.
    local current_limit_a = nil
    if charging and target_a and written_a and written_a > 0 and written_ms and
       now - written_ms >= ORDER_SETTLE_MS and target_a + 0.5 < written_a then
        current_limit_a = target_a
    end

    -- Stalled: a current of ours stands, a car is plugged in, and the charger
    -- itself holds the charge paused. Once that has lasted 30 s, forget the
    -- setpoint so the next order writes it again, at most every 30 s.
    local command_stalled = false
    if steering and order_landed and connected and status == 6 then
        stalled_since_ms = stalled_since_ms or now
        command_stalled = now - stalled_since_ms >= ORDER_SETTLE_MS
        if command_stalled and (not stall_rewrite_ms or now - stall_rewrite_ms >= ORDER_SETTLE_MS) then
            stall_rewrite_ms = now
            written_a = nil
        end
    else
        stalled_since_ms, stall_rewrite_ms = nil, nil
    end

    local reason = nil
    if connected and charging == false then reason = STATUS[status] end
    -- Paused by the car or ended: the car does not ask for current.
    local request_active = nil
    if connected then request_active = not (status == 5 or status == 7) end

    host.emit("ev", {
        w                       = w,
        connected               = connected,
        charging                = charging,
        request_active          = request_active,
        session_wh              = (session_kwh and session_kwh > 0) and session_kwh * 1000 or nil,
        l1_v = volts[1], l2_v = volts[2], l3_v = volts[3],
        l1_a = amps[1], l2_a = amps[2], l3_a = amps[3],
        phases                  = measured > 0 and measured or nil,
        max_a                   = target_a,
        current_limit_a         = current_limit_a,
        device_limit_a          = device_limit_a,
        device_limit_age_s      = device_limit_ms and (now - device_limit_ms) / 1000 or nil,
        state_label             = status and STATUS[status] or nil,
        reason_no_current_label = reason,
        command_stalled         = command_stalled,
    })

    return 5000
end

-- Core sends ev_resume and ev_start with no budget. A fresh order is written
-- again. Otherwise only MIN_A, and only when the last limit Core named allows
-- it; with no such limit nothing is written and the next order sets the level.
local function resume()
    local now = host.millis()
    local amps = nil
    if order_a and order_ms and now - order_ms <= ORDER_FRESH_MS then
        amps = order_a
    elseif last_cap_a and last_cap_a >= MIN_A then
        amps = MIN_A
        written_a = nil
    end
    if not amps and last_cap_a == nil then
        -- No limit known, after a reload for example. Nothing was refused and
        -- nothing written; Core's next order sets the level.
        if not resume_wait_logged then
            resume_wait_logged = true
            host.log("info", "Etrel: no fresh order and no known limit; " ..
                "the charger waits for Core's next order")
        end
        return true
    end
    if not amps then
        host.log("info", "Etrel: the last limit Core named leaves no room for 6 A; " ..
            "resume waits for the next order")
        return false
    end
    local ok = write_current(amps)
    if ok then steering = true end
    return ok
end

function driver_command(action, power_w, cmd)
    if action == "init" then return true end
    if action == "deinit" then return driver_default_mode() end

    if action == "ev_set_current" then
        local amps, phases = amps_for(power_w, cmd)
        host.log("debug", string.format("Etrel: %s W on %d phase(s) -> %.1f A",
            tostring(power_w), phases, amps))
        -- Core names cap_amps_per_phase only with a positive order, so a 0 W
        -- order must not replace the cap with the site maximum.
        if type(power_w) == "number" and power_w > 0 then last_cap_a = cap_of(cmd) end
        resume_wait_logged = false
        order_a, order_ms = (amps > 0) and amps or nil, host.millis()
        local ok = write_current(amps)
        if ok then steering = true end
        return ok
    end

    if action == "ev_pause" then
        local ok = write_current(0)
        if ok then steering = true end
        return ok
    end

    if action == "ev_resume" or action == "ev_start" then
        return resume()
    end

    host.log("warn", "Etrel: unknown action " .. tostring(action))
    return false
end

-- Stand the charger down: a 0 A setpoint, once a command wrote in this run.
-- Repeated calls write nothing once that has landed. A refused stand-down
-- returns false and is tried again at most once a minute.
function driver_default_mode()
    if not ftw_wrote then return true end
    if written_a == 0 then
        steering = false
        return true
    end
    local now = host.millis()
    if standdown_tried_ms and now - standdown_tried_ms < STANDDOWN_RETRY_MS then
        return false
    end
    standdown_tried_ms = now
    if write_current(0) then
        standdown_tried_ms = nil
        steering = false
        return true
    end
    host.log("warn", "Etrel: stand-down refused; trying again in a minute")
    return false
end

function driver_cleanup()
end
