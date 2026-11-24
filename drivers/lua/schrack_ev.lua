-- Schrack i-CHARGE CION Home and Semipublic EV charger (Modbus RTU)
-- Emits: ev
-- Controls: charging current per phase, pause and resume.
--
-- Register map: Schrack "Modbus Register Tabelle CION Home und Semipublic"
-- (versions of 13.04.2021, 04.08.2022 and 09.02.2023) and table 15 of the
-- "i-CHARGE CION" operating manual V2.2.
--
-- The CION Home (EMCIONH...) and Semipublic (EMCIONS...) speak Modbus RTU on
-- RS485, 57600 baud, 8N1, with DIP switches 1 and 2 OFF. DIP switches 3 and 4
-- set the bus address (Schrack's 2023 table: OFF/ON = 1, ON/OFF = 2,
-- ON/ON = 3). FTW speaks Modbus TCP, so it reaches the charger through a
-- Modbus TCP to RTU gateway. Set the driver's unit_id to the bus address.
--
-- The CION Pro (EMCIONP...) is a different controller with OCPP 1.5/1.6 and
-- is not covered here. Connect it to FTW's built-in OCPP central system.
--
--   Holding registers (function code 3 to read, 6 to write):
--     100  charging authorisation   0 not allowed, 1 allowed (r/w).
--                                   RFID or input E1 set it to 1; unplugging
--                                   the car sets it back to 0.
--     101  target charging current  A, 6..32 (r/w). Schrack: "can and should
--                                   be set during a charging process".
--     120  authorisation void       1 when 100 cannot take effect (fault, no
--                                   car, no cable). Writing 100 = 0 clears it.
--     121  status bits              bit 0 cable plugged, bit 1 contactor 1 on,
--                                   bit 6 group fault
--     126  current Mode 3 current   A, offered to the car now
--     127  max Mode 3 current       A, configured maximum
--     128  cable current capacity   A: 0, 13, 20, 32, 63
--     139  CP state                 ASCII 'A'..'F', 'U'
--     150  error word               non-zero is a fault
--     816  device name              16 registers ASCII
--     832  firmware version         16 registers ASCII
--
-- The register list has no power or energy, so `w` and `session_wh` stay
-- empty. FTW can order the charger but cannot see what the car draws from it.
--
-- The charger reports no phase currents, so an order is split over the
-- phases set in config (`phases`, default 3) and nothing else. Core's
-- phase_mode cannot be checked against the car here: a one-phase order on a
-- three-phase installation is still divided by three, so a three-phase car
-- never gets the whole order on each phase. On a one-phase installation set
-- `phases: 1`.

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "schrack_ev",
  name         = "Schrack i-CHARGE CION",
  manufacturer = "Schrack",
  version      = "1.1.0",
  protocols    = { "modbus" },
  capabilities = { "ev" },
  description  = "Schrack i-CHARGE CION Home and Semipublic over Modbus RTU, through a Modbus TCP to RTU gateway. Reads charger state and sets the charging current. The charger reports no power, so FTW cannot see what the car draws. The CION Pro is not covered: connect it to FTW's OCPP central system.",
  homepage     = "https://www.schrack.com/services/cion-docu",
  authors      = { "FTW contributors" },
  tested_models = { "i-CHARGE CION Home", "i-CHARGE CION Semipublic" },
  verification_status = "experimental",
  verification_notes = "Control written from Schrack's CION Home and Semipublic Modbus register table; not yet confirmed on hardware.",
  connection_defaults = {
    port    = 502,
    unit_id = 1,
  },
}

PROTOCOL = "modbus"

local REG_AUTH        = 100   -- with 101: two registers
local REG_SET_CURRENT = 101
local REG_VOID        = 120   -- with 121: two registers
local REG_OFFERED     = 126   -- with 127, 128: three registers
local REG_CP_STATE    = 139
local REG_ERROR       = 150
local REG_IDENTITY    = 816   -- device name and firmware: 32 registers

local MIN_A = 6
local MAX_A = 32

local CP = { [65] = "A", [66] = "B", [67] = "C", [68] = "D", [69] = "E", [70] = "F", [85] = "U" }

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
            "Schrack: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

local function ascii(regs, first, count)
    local ok, text = pcall(host.decode_string, regs, first, count)
    if not ok or type(text) ~= "string" then return "" end
    return (text:gsub("[^%w%-%._/ ]", ""))
end

----------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------

local installed_phases = 3
local identity_read = false

-- What the charger last took from this driver. nil means unknown.
local written_a, written_a_ms = nil, nil
local written_auth, written_auth_ms = nil, nil
-- The last order: its current (nil for 0 A), when it came, and the lowest
-- per-phase limit Core named with it. Core sends ev_resume and ev_start with
-- no budget, so a resume trusts only a fresh order and that limit.
local order_a, order_ms = nil, nil
local last_cap_a = nil
local resume_wait_logged = false
local steering = false
-- True once a command has tried to write in this run. Core runs default mode
-- at every start, so until then the stand-down leaves the charger alone: a
-- charger FTW never steered keeps its own state, and a charge already running
-- goes on. The same rule as heishamon 0.8.1.
local ftw_wrote = false

-- Core treats a default mode that returns true as a charger stood down, so
-- true means confirmed (or nothing of FTW's to take back). A refused
-- stand-down returns false and is tried again at most once a minute, without
-- writing in between.
local STANDDOWN_RETRY_MS = 60000
local standdown_tried_ms = nil

-- Fresh readings from the latest poll, for the command path.
local last_connected = nil
local last_void = nil
-- When a void authorisation was last reset. A fault that is still there
-- makes the reset void again at once, and void then stays set after the
-- fault clears, so the reset is repeated at most every VOID_RESET_EVERY_MS
-- while void lasts. Cleared when the charger stops calling it void.
local void_reset_ms = nil
local VOID_RESET_EVERY_MS = 30000
local device_limit_a, device_limit_ms = nil, nil
local stalled_since_ms = nil

local ORDER_SETTLE_MS = 10000
local STALL_MS = 30000
local ORDER_FRESH_MS = 30000

----------------------------------------------------------------------------
-- Writes
----------------------------------------------------------------------------

local function write(addr, value, what)
    -- Default mode writes only once this is set, so only a command sets it.
    ftw_wrote = true
    local ok, err = pcall(host.modbus_write, addr, value)
    if not ok or (err ~= nil and err ~= true and err ~= "") then
        host.log("warn", "Schrack: " .. what .. " not written: " ..
            tostring(ok and err or "error"))
        return false
    end
    return true
end

local function write_current(amps)
    if written_a == amps then return true end
    if not write(REG_SET_CURRENT, amps, "charging current " .. tostring(amps) .. " A") then
        written_a = nil
        return false
    end
    written_a, written_a_ms = amps, host.millis()
    return true
end

local function write_auth(value)
    if written_auth == value then return true end
    if not write(REG_AUTH, value, "charging authorisation " .. tostring(value)) then
        written_auth = nil
        return false
    end
    written_auth, written_auth_ms = value, host.millis()
    return true
end

----------------------------------------------------------------------------
-- Orders
----------------------------------------------------------------------------

local function finite_positive(v)
    return type(v) == "number" and v == v and v > 0 and v < math.huge
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

-- Core orders total power. The charger takes whole amperes per phase.
--
--   phases  the installed phases from config only, since the charger
--           measures none
--   amps    power / (voltage * phases), never above Core's max and cap per
--           phase or the charger's own limit, rounded down to 1 A
--   below   MIN_A gives 0 A. A current is never rounded up to the minimum.
local function amps_for(power_w, cmd)
    local phases = installed_phases
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
    amps = math.floor(amps + 0.0001)
    if amps < MIN_A then return 0, phases end
    return amps, phases
end

-- Set the current first, then allow charging, so the car never starts on an
-- older, higher current. With no car plugged in, authorisation would only
-- turn void, so it waits for the next order after the car arrives.
local function charge_at(amps)
    if not write_current(amps) then return false end
    if last_connected == false then return true end
    local now = host.millis()
    if last_void == 1 and (not void_reset_ms or now - void_reset_ms >= VOID_RESET_EVERY_MS) then
        -- Schrack: a void authorisation is cleared by writing 0 first. At
        -- most every 30 s, so a car that stays unready is not cycled on every
        -- order.
        if not write(REG_AUTH, 0, "authorisation reset") then
            written_auth = nil
            return false
        end
        void_reset_ms = now
        written_auth = 0
    end
    return write_auth(1)
end

----------------------------------------------------------------------------
-- Driver interface
----------------------------------------------------------------------------

function driver_init(config)
    host.set_make("Schrack")
    if type(config) == "table" and tonumber(config.phases) == 1 then
        installed_phases = 1
    end
end

local function read_identity()
    if identity_read then return end
    local regs = probe_read(REG_IDENTITY, 32, "holding")
    if not regs then return end
    identity_read = true
    local name = ascii(regs, 1, 16)
    local firmware = ascii(regs, 17, 16)
    if #name > 0 then host.set_model(name) end
    if #firmware > 0 then host.log("info", "Schrack: firmware " .. firmware) end
end

function driver_poll()
    local now = host.millis()
    read_identity()

    local ctl = probe_read(REG_AUTH, 2, "holding")
    local st = probe_read(REG_VOID, 2, "holding")
    local cur = probe_read(REG_OFFERED, 3, "holding")
    local cp_regs = probe_read(REG_CP_STATE, 1, "holding")
    local err_regs = probe_read(REG_ERROR, 1, "holding")

    local cp = cp_regs and CP[cp_regs[1]] or nil
    if not ctl and not cp then
        -- Neither the order nor the car state answered: nothing fresh to say.
        last_connected, last_void = nil, nil
        return 5000
    end

    local auth = ctl and ctl[1] or nil
    local target_a = ctl and ctl[2] or nil
    local void = st and st[1] or nil
    local bits = st and st[2] or nil
    local offered_a = cur and cur[1] or nil
    local max_a = cur and cur[2] or nil
    local cable_a = cur and cur[3] or nil
    local fault = err_regs and err_regs[1] ~= 0

    local connected = nil
    if cp == "A" then connected = false end
    if cp == "B" or cp == "C" or cp == "D" then connected = true end
    local charging = nil
    if cp then
        charging = (cp == "C" or cp == "D")
        -- Bit 1 of 121 is contactor 1: without it no current flows.
        if charging and bits and math.floor(bits / 2) % 2 == 0 then charging = false end
    end
    last_connected, last_void = connected, void
    if void == 0 then void_reset_ms = nil end

    -- The charger's own ceiling: its configured maximum and the cable.
    local limit = nil
    if max_a and max_a >= MIN_A and max_a <= 63 then limit = max_a end
    if cable_a and cable_a > 0 and (limit == nil or cable_a < limit) then limit = cable_a end
    if limit then device_limit_a, device_limit_ms = limit, now end

    -- A charger that no longer holds this driver's order forgets it: a
    -- current that differs, or an authorisation that was cleared, by the car
    -- leaving for example. The next order writes it again.
    if steering then
        if written_a and target_a and target_a ~= written_a and
           written_a_ms and now - written_a_ms >= ORDER_SETTLE_MS then
            written_a = nil
        end
        if written_auth and auth and auth ~= written_auth and
           written_auth_ms and now - written_auth_ms >= ORDER_SETTLE_MS then
            written_auth = nil
        end
    end

    local current_limit_a = nil
    if charging and offered_a and written_a and written_a > 0 and written_a_ms and
       now - written_a_ms >= STALL_MS and offered_a + 0.5 < written_a then
        current_limit_a = offered_a
    end

    -- Stalled: charging is ordered, a car is plugged in, and the charger has
    -- dropped the authorisation or calls it void.
    local command_stalled = false
    if steering and written_auth == 1 and connected and (auth == 0 or void == 1) then
        stalled_since_ms = stalled_since_ms or now
        command_stalled = now - stalled_since_ms >= STALL_MS
    else
        stalled_since_ms = nil
    end

    local reason = nil
    if connected and charging == false then
        if fault then reason = "fault"
        elseif void == 1 then reason = "authorisation_void"
        elseif auth == 0 then reason = "not_authorised"
        else reason = "waiting_for_vehicle" end
    end

    host.emit("ev", {
        connected               = connected,
        charging                = charging,
        max_a                   = offered_a,
        current_limit_a         = current_limit_a,
        device_limit_a          = device_limit_a,
        device_limit_age_s      = device_limit_ms and (now - device_limit_ms) / 1000 or nil,
        state_label             = cp and ("cp_" .. cp) or nil,
        reason_no_current_label = reason,
        command_stalled         = command_stalled,
    })

    return 5000
end

function driver_command(action, power_w, cmd)
    if action == "init" then return true end
    if action == "deinit" then return driver_default_mode() end

    if action == "ev_set_current" then
        local amps, phases = amps_for(power_w, cmd)
        host.log("debug", string.format("Schrack: %s W on %d phase(s) -> %d A",
            tostring(power_w), phases, amps))
        -- Core names cap_amps_per_phase only with a positive order, so a 0 W
        -- order must not replace the cap with the site maximum.
        if type(power_w) == "number" and power_w > 0 then last_cap_a = cap_of(cmd) end
        resume_wait_logged = false
        order_a, order_ms = (amps > 0) and amps or nil, host.millis()
        local ok
        if amps <= 0 then
            ok = write_auth(0)
        else
            ok = charge_at(amps)
        end
        if ok then steering = true end
        return ok
    end

    if action == "ev_pause" then
        local ok = write_auth(0)
        if ok then steering = true end
        return ok
    end

    if action == "ev_resume" or action == "ev_start" then
        -- No budget comes with these. A fresh order is written again.
        -- Otherwise 101 = 6 A first, and only when the last limit Core named
        -- allows 6 A. With no limit known nothing is written and Core's next
        -- order sets the level.
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
                host.log("info", "Schrack: no fresh order and no known limit; " ..
                    "the charger waits for Core's next order")
            end
            return true
        end
        if not amps then
            host.log("info", "Schrack: the last limit Core named leaves no room for 6 A; " ..
                "resume waits for the next order")
            return false
        end
        local ok = charge_at(amps)
        if ok then steering = true end
        return ok
    end

    host.log("warn", "Schrack: unknown action " .. tostring(action))
    return false
end

-- Stand the charger down: withdraw the charging authorisation, once a command wrote in this run.
-- Repeated calls write nothing once that has landed. A refused stand-down
-- returns false and is tried again at most once a minute.
function driver_default_mode()
    if not ftw_wrote then return true end
    if written_auth == 0 then
        steering = false
        return true
    end
    local now = host.millis()
    if standdown_tried_ms and now - standdown_tried_ms < STANDDOWN_RETRY_MS then
        return false
    end
    standdown_tried_ms = now
    if write_auth(0) then
        standdown_tried_ms = nil
        steering = false
        return true
    end
    host.log("warn", "Schrack: stand-down refused; trying again in a minute")
    return false
end

function driver_cleanup()
end
