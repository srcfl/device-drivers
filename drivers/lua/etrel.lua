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
-- Sign convention: an EVSE is a one-way load, so `w` is positive while the car
-- charges, as the charger reports it.

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "etrel",
  name         = "Etrel INCH",
  manufacturer = "Etrel",
  version      = "1.1.0",
  protocols    = { "modbus" },
  capabilities = { "ev" },
  description  = "Etrel INCH Home, Pro and Duo (connector 1) over Modbus TCP. Reads power, phase currents and charger state, and sets the charging current. Enable Modbus in the charger's web interface.",
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
-- The last current above zero that an order asked for, so a resume after a
-- pause brings it back.
local order_a = nil
-- True from a successful command write until the stand-down lands. While it
-- is true the poll checks that the charger still follows the order.
local steering = false
-- True while a current above zero that this driver wrote may still stand.
local order_landed = false

-- Default mode is reached on a timer. A charger that refuses the stand-down
-- three times running, and never took an order from this driver, is left
-- alone: there is nothing of ours to take back.
local STANDDOWN_ATTEMPTS = 3
local standdown_refusals = 0

-- Fresh readings from the latest poll, for the command path.
local last_status = nil
local last_phases = nil
local last_connected = nil
local stalled_since_ms = nil

local ORDER_SETTLE_MS = 30000
local DEVICE_LIMIT_EVERY_MS = 60000

----------------------------------------------------------------------------
-- Orders
----------------------------------------------------------------------------

local function finite_positive(v)
    return type(v) == "number" and v == v and v > 0 and v < math.huge
end

-- Core orders total power. The charger takes a current per phase.
--
--   phases  the larger of the order's phase_mode (1p is one, anything else
--           three) and the phases the charger measures current on
--   amps    power / (voltage * phases), never above Core's max and cap per
--           phase or the charger's own limit, rounded down to 0.1 A
--   below   MIN_A gives 0 A. A current is never rounded up to the minimum.
local function amps_for(power_w, cmd)
    local phases = 3
    if type(cmd) == "table" and cmd.phase_mode == "1p" then phases = 1 end
    if last_phases and last_phases > phases then phases = last_phases end
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
        last_status, last_connected, last_phases = nil, nil, nil
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
    last_phases = measured > 0 and measured or nil

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

    -- Stalled: an order of at least MIN_A has stood, a car is plugged in, and
    -- the charger itself holds the charge paused.
    local command_stalled = false
    if steering and written_a and written_a >= MIN_A and connected and status == 6 then
        stalled_since_ms = stalled_since_ms or now
        command_stalled = now - stalled_since_ms >= ORDER_SETTLE_MS
    else
        stalled_since_ms = nil
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
        phases                  = last_phases,
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

local function resume()
    local amps = order_a or MIN_A
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
        local ok = write_current(amps)
        if ok then
            steering = true
            if amps > 0 then order_a = amps end
        end
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

-- Stand the charger down: a 0 A setpoint. Repeated calls write nothing once
-- it has landed.
function driver_default_mode()
    if written_a == 0 then
        steering = false
        return true
    end
    if standdown_refusals >= STANDDOWN_ATTEMPTS and not order_landed then
        return true
    end
    if write_current(0) then
        standdown_refusals = 0
        steering = false
        return true
    end
    standdown_refusals = standdown_refusals + 1
    if standdown_refusals == STANDDOWN_ATTEMPTS and not order_landed then
        host.log("info", "Etrel: the charger refused the 0 A stand-down " ..
            STANDDOWN_ATTEMPTS .. " times; no longer writing it unprompted")
    end
    return false
end

function driver_cleanup()
end
