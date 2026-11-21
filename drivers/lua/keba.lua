-- KEBA KeContact P30 EV charger (Modbus TCP)
-- Emits: ev
-- Controls: charging current per phase, pause and resume.
--
-- Register map: KEBA "KeContact P30 Charging Station Modbus TCP Programmers
-- Guide" V1.07 (document 132578, 12.2025).
--
--   Needs a P30 c-series with firmware 3.10.16 or later, or a P30 x-series
--   with software 1.11 or later, and DIP switch DSW1.3 set to ON. Unit ID 255,
--   port 502. Function codes 3 (read) and 6 (write) only. Each read is one
--   UINT32 value of two registers; the guide forbids reading more at once.
--   KEBA asks for at least 5 s between writes.
--
--   Read (function code 3, UINT32 big-endian):
--     1000 charging state     0 start-up, 1 not ready, 2 ready, 3 charging,
--                             4 error, 5 suspended (temperature or disabled)
--     1004 cable state        5 and 7: plugged into the car
--     1008/1010/1012          L1..L3 current, mA
--     1014 serial number
--     1016 product type       e.g. 304111: P30, cable 0, 32 A, c-series,
--                             energy meter 1, RFID 1. Meter digit 0: none.
--     1020 active power, mW
--     1036 total energy, 0.1 Wh
--     1040/1042/1044          L1..L3 voltage, V
--     1100 max charging current, mA: what the charger offers the car now
--     1110 max supported current, mA: DIP switches, cable and temperature
--     1502 charged energy of the session, 0.1 Wh
--     1602 failsafe timeout, s
--
--   Write (function code 6, UINT16):
--     5004 set charging current, mA, 6000..63000. Holds until a reboot.
--     5014 1 enable, 0 disable (suspended). Stops an active charge.
--     5018 failsafe timeout, s. Resets the failsafe timer.
--
-- The guide names no way to set 5004 below 6000, so pause and every order
-- below 6 A disable the charger with 5014 instead.
--
-- The UDP interface (port 7090: `currtime`, `ena`, `report 2/3`) reaches the
-- same charger, but FTW's driver host has no UDP. KEBA forbids using both
-- interfaces together, so this driver uses Modbus TCP only. A c-series still
-- on firmware older than 3.10.16 speaks only UDP: update its firmware.
-- The P40 has its own guide and is not covered.
--
-- Sign convention: an EVSE is a one-way load, so `w` is positive while the car
-- charges, as the charger reports it.

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "keba",
  name         = "KEBA KeContact P30",
  manufacturer = "KEBA",
  version      = "1.1.0",
  protocols    = { "modbus" },
  capabilities = { "ev" },
  description  = "KEBA KeContact P30 c-series (firmware 3.10.16 or later) and x-series (1.11 or later) over Modbus TCP. Reads power, phase currents and charger state, and sets the charging current. Set DIP switch DSW1.3 to ON and the Modbus unit ID to 255; the UDP interface must stay off.",
  homepage     = "https://www.keba.com/emobility",
  authors      = { "FTW contributors" },
  tested_models = { "P30 c-series", "P30 x-series" },
  verification_status = "experimental",
  verification_notes = "Control written from KEBA's P30 Modbus TCP Programmers Guide V1.07; not yet confirmed on hardware.",
  connection_defaults = {
    port    = 502,
    unit_id = 255,
  },
}

PROTOCOL = "modbus"

local REG_STATE        = 1000
local REG_CABLE        = 1004
local REG_CURRENT      = { 1008, 1010, 1012 }
local REG_SERIAL       = 1014
local REG_PRODUCT      = 1016
local REG_POWER        = 1020
local REG_TOTAL_ENERGY = 1036
local REG_VOLTAGE      = { 1040, 1042, 1044 }
local REG_MAX_CURRENT  = 1100
local REG_HW_CURRENT   = 1110
local REG_SESSION      = 1502
local REG_FS_TIMEOUT   = 1602

local REG_SET_CURRENT  = 5004
local REG_ENABLE       = 5014
local REG_SET_FS_TMO   = 5018

local MIN_A = 6        -- 5004 takes nothing below 6000 mA
local MAX_A = 32       -- the largest P30 hardware
local STEP_A = 0.1

local STATE = {
    [0] = "starting",
    [1] = "not_ready",
    [2] = "waiting_for_vehicle",
    [3] = "charging",
    [4] = "error",
    [5] = "suspended",
}

----------------------------------------------------------------------------
-- Reads
----------------------------------------------------------------------------

-- The host counts every failed modbus_read against the poll whether or not
-- Lua caught it. A register the charger does not answer costs a failed read
-- on every poll and takes the site offline. Three tries, then leave it alone.
-- Core reloads the driver once nothing is left to read.
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
            "KEBA: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

-- One UINT32 register pair, high word first.
local function read_u32(addr)
    local regs = probe_read(addr, 2, "holding")
    if not regs then return nil end
    return host.decode_u32_be(regs[1], regs[2])
end

----------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------

local identity_read = false
local product = nil          -- product code digits as a string, once read
local is_p30 = nil           -- nil until the product code answers
local has_meter = true       -- false only when the product code says so

-- What the charger last took from this driver. nil means unknown.
local written_ma = nil
local written_ms = nil
local enabled = nil          -- 5014 is write-only, so this is ours to track
local enabled_ms = nil
local order_a = nil          -- the last current above zero an order asked for
local steering = false       -- a command landed and no stand-down since
local order_landed = false   -- an enable of ours may still stand

local STANDDOWN_ATTEMPTS = 3
local standdown_refusals = 0

local failsafe_timeout_s = nil
local failsafe_refreshed_ms = nil
local FAILSAFE_ATTEMPTS = 3
local failsafe_refusals = 0

local last_phases = nil
local device_limit_a, device_limit_ms = nil, nil
local stalled_since_ms = nil

local ORDER_SETTLE_MS = 30000

----------------------------------------------------------------------------
-- Writes
----------------------------------------------------------------------------

local function write(addr, value, what)
    local ok, err = pcall(host.modbus_write, addr, value)
    if not ok or (err ~= nil and err ~= true and err ~= "") then
        host.log("warn", "KEBA: " .. what .. " not written: " ..
            tostring(ok and err or "error"))
        return false
    end
    return true
end

local function write_current_ma(ma)
    if written_ma == ma then return true end
    if not write(REG_SET_CURRENT, ma, "charging current " .. tostring(ma) .. " mA") then
        written_ma = nil
        return false
    end
    written_ma, written_ms = ma, host.millis()
    return true
end

local function set_enabled(on)
    if enabled == on then return true end
    if not write(REG_ENABLE, on and 1 or 0, on and "enable" or "disable") then
        enabled = nil
        return false
    end
    enabled, enabled_ms = on, host.millis()
    order_landed = on
    return true
end

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
    -- The allowance absorbs float error in a division Core meant to be exact.
    amps = math.floor(amps / STEP_A + 0.001) * STEP_A
    if amps < MIN_A then return 0, phases end
    return amps, phases
end

local function to_ma(amps)
    return math.floor(amps * 10 + 0.5) * 100
end

-- Set the current first, then enable, so a charger that was disabled never
-- starts on an older, higher current.
local function charge_at(amps)
    if not write_current_ma(to_ma(amps)) then return false end
    return set_enabled(true)
end

local function control_allowed()
    if is_p30 == false then
        host.log("warn", "KEBA: product code " .. tostring(product) ..
            " is not a P30; this driver does not control it")
        return false
    end
    return true
end

----------------------------------------------------------------------------
-- Driver interface
----------------------------------------------------------------------------

function driver_init(config)
    host.set_make("Keba")
end

local function read_identity()
    if identity_read then return end
    local code = read_u32(REG_PRODUCT)
    if not code then return end
    identity_read = true
    product = string.format("%.0f", code)
    -- P30 product codes have six digits and start with 3.
    is_p30 = #product == 6 and product:sub(1, 1) == "3"
    if is_p30 then
        has_meter = product:sub(5, 5) ~= "0"
        host.set_model("KeContact P30 " ..
            (product:sub(4, 4) == "1" and "c-series" or "x-series"))
    end
    local serial = read_u32(REG_SERIAL)
    if serial then host.set_sn(string.format("%.0f", serial)) end
end

local function milliamps(addr)
    local v = read_u32(addr)
    return v and v / 1000 or nil
end

function driver_poll()
    local now = host.millis()
    read_identity()

    local state = read_u32(REG_STATE)
    if state ~= nil and STATE[state] == nil then state = nil end
    local cable = read_u32(REG_CABLE)

    local amps, volts = {}, {}
    local w, session_wh, lifetime_wh = nil, nil, nil
    if has_meter then
        for i = 1, 3 do amps[i] = milliamps(REG_CURRENT[i]) end
        local mw = read_u32(REG_POWER)
        w = mw and mw / 1000 or nil
        local total = read_u32(REG_TOTAL_ENERGY)
        lifetime_wh = total and total / 10 or nil
        local session = read_u32(REG_SESSION)
        session_wh = session and session / 10 or nil
        for i = 1, 3 do volts[i] = read_u32(REG_VOLTAGE[i]) end
    end
    local offered_a = milliamps(REG_MAX_CURRENT)
    local hw_a = milliamps(REG_HW_CURRENT)
    if hw_a and hw_a > 0 and hw_a <= 63 then device_limit_a, device_limit_ms = hw_a, now end
    failsafe_timeout_s = read_u32(REG_FS_TIMEOUT)

    if state == nil and cable == nil and w == nil then
        -- Nothing answered: there is no fresh reading to report.
        last_phases = nil
        return 5000
    end

    local connected = nil
    if cable ~= nil then connected = cable == 5 or cable == 7 end
    local charging = nil
    if state ~= nil and state ~= 0 then charging = state == 3 end

    local measured = 0
    for i = 1, 3 do
        if amps[i] and amps[i] >= 1 then measured = measured + 1 end
    end
    last_phases = measured > 0 and measured or nil

    -- A charger that offers more than this driver ordered, or charges while
    -- this driver disabled it, has lost the order: a reboot clears 5004.
    -- Forget what was written so the next order writes it again, once the
    -- write has had time to land (KEBA takes 6-7 s to apply a current).
    if steering and connected then
        if written_ma and offered_a and written_ms and now - written_ms >= ORDER_SETTLE_MS and
           offered_a > written_ma / 1000 + 0.5 then
            host.log("warn", string.format(
                "KEBA: charger offers %.1f A against an order of %.1f A; writing it again",
                offered_a, written_ma / 1000))
            written_ma = nil
        end
        if enabled == false and charging and enabled_ms and now - enabled_ms >= ORDER_SETTLE_MS then
            host.log("warn", "KEBA: charging although disabled; disabling again")
            enabled = nil
        end
    end

    -- The failsafe stops or limits charging when Modbus commands stop for its
    -- timeout. While this driver holds an order, refresh it at half the
    -- timeout, never faster than KEBA's 5 s between writes.
    if steering and enabled and failsafe_timeout_s and failsafe_timeout_s >= 5 and
       failsafe_timeout_s <= 600 and failsafe_refusals < FAILSAFE_ATTEMPTS then
        local every_ms = math.max(5, failsafe_timeout_s / 2) * 1000
        if not failsafe_refreshed_ms or now - failsafe_refreshed_ms >= every_ms then
            failsafe_refreshed_ms = now
            if write(REG_SET_FS_TMO, failsafe_timeout_s, "failsafe refresh") then
                failsafe_refusals = 0
            else
                failsafe_refusals = failsafe_refusals + 1
            end
        end
    end

    local current_limit_a = nil
    if charging and offered_a and written_ma and enabled and written_ms and
       now - written_ms >= ORDER_SETTLE_MS and offered_a + 0.5 < written_ma / 1000 then
        current_limit_a = offered_a
    end

    -- Stalled: an enable of ours has stood, a car is plugged in, and the
    -- charger stays suspended.
    local command_stalled = false
    if steering and enabled and connected and state == 5 then
        stalled_since_ms = stalled_since_ms or now
        command_stalled = now - stalled_since_ms >= ORDER_SETTLE_MS
    else
        stalled_since_ms = nil
    end

    local reason = nil
    if connected and charging == false then reason = STATE[state] end

    host.emit("ev", {
        w                       = w,
        connected               = connected,
        charging                = charging,
        session_wh              = session_wh,
        lifetime_wh             = lifetime_wh,
        l1_v = volts[1], l2_v = volts[2], l3_v = volts[3],
        l1_a = amps[1], l2_a = amps[2], l3_a = amps[3],
        phases                  = last_phases,
        max_a                   = offered_a,
        current_limit_a         = current_limit_a,
        device_limit_a          = device_limit_a,
        device_limit_age_s      = device_limit_ms and (now - device_limit_ms) / 1000 or nil,
        state_label             = state and STATE[state] or nil,
        reason_no_current_label = reason,
        command_stalled         = command_stalled,
    })

    return 5000
end

function driver_command(action, power_w, cmd)
    if action == "init" then return true end
    if action == "deinit" then return driver_default_mode() end
    if not control_allowed() then return false end

    if action == "ev_set_current" then
        local amps, phases = amps_for(power_w, cmd)
        host.log("debug", string.format("KEBA: %s W on %d phase(s) -> %.1f A",
            tostring(power_w), phases, amps))
        local ok
        if amps <= 0 then
            ok = set_enabled(false)
        else
            ok = charge_at(amps)
            if ok then order_a = amps end
        end
        if ok then steering = true end
        return ok
    end

    if action == "ev_pause" then
        local ok = set_enabled(false)
        if ok then steering = true end
        return ok
    end

    if action == "ev_resume" or action == "ev_start" then
        local ok = charge_at(order_a or MIN_A)
        if ok then steering = true end
        return ok
    end

    host.log("warn", "KEBA: unknown action " .. tostring(action))
    return false
end

-- Stand the charger down: disable it. Repeated calls write nothing once that
-- has landed. A charger that refuses three times, and never took an enable
-- from this driver, is left alone.
function driver_default_mode()
    if enabled == false then
        steering = false
        return true
    end
    if is_p30 == false then return true end
    if standdown_refusals >= STANDDOWN_ATTEMPTS and not order_landed then
        return true
    end
    if set_enabled(false) then
        standdown_refusals = 0
        steering = false
        return true
    end
    standdown_refusals = standdown_refusals + 1
    if standdown_refusals == STANDDOWN_ATTEMPTS and not order_landed then
        host.log("info", "KEBA: the charger refused the stand-down " ..
            STANDDOWN_ATTEMPTS .. " times; no longer writing it unprompted")
    end
    return false
end

function driver_cleanup()
end
