-- ABB Terra AC wallbox over Modbus TCP
-- Emits: ev
-- Protocol: Modbus TCP (or RTU), holding registers (FC 03/06/16)
--
-- Source: ABB "TAC Modbus Communication, Modbus RTU - RS485 and TCP/IP",
-- v1.7 (July 2022), section 5 "Modbus Map". Values are big-endian; 32-bit
-- values are two registers, high word first.
--
-- Earlier versions of this driver read registers 1000-1037, which are not in
-- ABB's map. Everything below is from the vendor table.
--
-- Registers used (UNSIGNED32 unless noted):
--   0x4000..0x4003  serial number (4 regs, encoded bytes)
--   0x4006          user settable max current (0.001 A): the installer's
--                   ceiling, set in the Terra Config app
--   0x4008          error code (0 = no error)
--   0x400A          socket lock state (0x0101 / 0x0111 = cable in station and EV)
--   0x400C          charging state: byte 1 bits 0-6 = 0 A, 1 B1, 2 B2, 3 C1,
--                   4 C2, 5 other; bit 7 = below the value commanded by 0x4100
--   0x400E          charging current limit (0.001 A): what the charger chose,
--                   including our 0x4100 value
--   0x4010..0x4015  current L1, L2, L3 (0.001 A)
--   0x4016..0x401B  voltage L1, L2, L3 (0.1 V)
--   0x401C          active power (W)
--   0x401E          energy delivered in this session (Wh)
--   0x4100          set charging current limit (0.001 A), write only
--
-- Control. ABB: below 6 A the session pauses; above 6 A it resumes. So 0 A
-- is the pause, and ev_pause, ev_resume and ev_set_current all write 0x4100.
-- 0x4105 (start/stop session) is not used: it acts like an RFID card.
--
-- Communication timeout (0x4106, default 60 s): the charger counts any read
-- as contact, and when none arrives in time it enters an error state and
-- stops the session. This driver reads the main block on every 5 s poll, so
-- no refresh write is needed. When FTW stops, the charger stopping on its
-- own is part of the safe stand-down.
--
-- Phases. This driver does not switch phases, and a 1p order alone proves
-- nothing: a three-phase car would draw the 1p current on every phase. So it
-- divides power by one phase only when config says `phases: 1` and the
-- charger shows no more, or when Core orders 1p and the car is measured
-- drawing on exactly one phase. Otherwise it divides by three.
--
-- Config (all optional):
--   max_a   lower ceiling in A, 6-31
--   phases  1 for a single-phase installation (see "Phases")
--
-- Sign convention: an EVSE is a one-way load. Positive W is charging.

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "abb_terra",
  name         = "ABB Terra AC",
  manufacturer = "ABB",
  version      = "1.1.2",
  protocols    = { "modbus" },
  capabilities = { "ev" },
  description  = "ABB Terra AC wallbox over Modbus TCP. Telemetry and current-limit control through register 0x4100.",
  setup_hint   = "Ask your installer to set up Modbus TCP/IP under Load Balance in the TerraConfig app, on the LAN port.",
  homepage     = "https://new.abb.com/ev-charging",
  authors      = { "FTW contributors" },
  tested_models = { "Terra AC W7", "Terra AC W11", "Terra AC W22" },
  verification_status = "experimental",
  verification_notes = "Control written from ABB's TAC Modbus Communication v1.7; not yet confirmed on hardware.",
  connection_defaults = {
    port    = 502,
    unit_id = 1,
  },
}

PROTOCOL = "modbus"

----------------------------------------------------------------------------
-- Registers
----------------------------------------------------------------------------
local REG_SERIAL   = 0x4000  -- 4 regs
local REG_BLOCK    = 0x4006  -- 0x4006..0x401F in one read
local BLOCK_COUNT  = 26
local REG_SETPOINT = 0x4100  -- 2 regs, mA, write only

----------------------------------------------------------------------------
-- Control limits
----------------------------------------------------------------------------
local MIN_A          = 6       -- IEC 61851 minimum; below it we write 0
local HW_MAX_A       = 32      -- Terra AC hardware maximum
local STEPS_PER_A    = 10      -- the register takes mA; we step 0.1 A
local READBACK_MS    = 30000   -- rewrite a limit the charger lost, at this pace
local PAUSE_HOLD_MS  = 10000   -- keep a pause through Core's 3 s contactor cycle
local STALL_MS       = 30000
local ACTIVE_PHASE_A = 2       -- a phase carrying this much is in use
local STANDDOWN_RETRY_MS = 60000 -- a refused stand-down is tried again at this pace

----------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------
local max_a_cfg = HW_MAX_A
local config_phases = nil      -- config `phases`
local device_max_a = nil       -- 0x4006 from the last poll

local ordered_a = nil          -- Core's latest order, after every cap
local paused = false
local paused_at = 0
local written_a = nil          -- last value the charger accepted; nil = unknown
local written_at = 0
local commanded = false        -- FTW has written a limit in this process
local standdown_failed_at = nil -- when the last stand-down write failed

local limit_a = nil            -- 0x400E from the last poll
local active_phases = nil      -- phases carrying current in the last poll
local seen_phases = 0          -- most phases seen carrying current this plug-in
local stall_since = nil
local sn_read = false

----------------------------------------------------------------------------
-- Reads
----------------------------------------------------------------------------

-- A failed read costs the poll. A block this charger does not answer is
-- asked three times, since one miss can be a slow link, then once a minute,
-- so a charger that was offline at boot comes back without a restart.
-- The main block is required and is asked every poll: without it the driver
-- reports nothing, the charger's communication timeout counts these reads,
-- and a poll that reads nothing at all makes Core reload the driver, which
-- would forget what FTW wrote.
local GIVE_UP_AFTER = 3
local RETRY_MS = 60000
local read_failures = {}       -- addr -> { n = misses in a row, at = last try }

local function probe_read(addr, count, kind, required)
    local f = read_failures[addr]
    if f and f.n >= GIVE_UP_AFTER and not required
        and (host.millis() - f.at) < RETRY_MS then
        return nil
    end
    local ok, regs = pcall(host.modbus_read, addr, count, kind)
    if ok and regs and regs[count] ~= nil then
        if f and f.n >= GIVE_UP_AFTER then
            host.log("info", string.format("ABB Terra: register %d answers again", addr))
        end
        read_failures[addr] = nil
        return regs
    end
    f = f or { n = 0 }
    f.n, f.at = f.n + 1, host.millis()
    read_failures[addr] = f
    if f.n == GIVE_UP_AFTER then
        host.log("info", string.format(
            "ABB Terra: register %d did not answer %d times; asking once a minute",
            addr, GIVE_UP_AFTER))
    end
    return nil
end

-- UNSIGNED32, high word first. Float arithmetic, so a 32-bit integer build
-- cannot overflow.
local function u32(regs, addr)
    local i = addr - REG_BLOCK + 1
    local hi, lo = regs[i], regs[i + 1]
    if hi == nil or lo == nil then return nil end
    return hi * 65536.0 + lo
end

local function scaled(regs, addr, scale)
    local v = u32(regs, addr)
    if v == nil then return nil end
    return v * scale
end

-- Charging state (byte 1, bits 0-6). B1 and C1 carry no PWM: the charger is
-- not offering current. B2 offers current that the car does not take.
local STATES = {
    [0] = { connected = false, charging = false },
    [1] = { connected = true,  charging = false, offering = false },
    [2] = { connected = true,  charging = false, offering = true,  request = false },
    [3] = { connected = true,  charging = false, offering = false, request = true },
    [4] = { connected = true,  charging = true,  offering = true,  request = true },
}

----------------------------------------------------------------------------
-- Control
----------------------------------------------------------------------------

local function num(v)
    if type(v) == "number" and v == v then return v end
    return nil
end

-- See "Phases" above. The Terra AC reports no phase setting of its own.
local function phases_for(cmd)
    if config_phases == 1 and seen_phases <= 1 then return 1 end
    if cmd.phase_mode == "1p" and active_phases == 1 and seen_phases == 1 then
        return 1
    end
    return 3
end

-- Watts to amps per phase, rounded down to 0.1 A. The 0.001-step slack only
-- absorbs float error (4140 W / 690 V must be 6 A, not 5.9 A).
local function amps_for(power_w, cmd)
    power_w = num(power_w)
    if power_w == nil or power_w <= 0 then return 0 end
    cmd = type(cmd) == "table" and cmd or {}
    local voltage = num(cmd.voltage)
    if voltage == nil or voltage <= 0 then voltage = 230 end
    local amps = power_w / (voltage * phases_for(cmd))
    local cap = max_a_cfg
    if device_max_a ~= nil and device_max_a >= MIN_A and device_max_a < cap then
        cap = device_max_a
    end
    local fuse = num(cmd.max_amps_per_phase)
    if fuse ~= nil and fuse > 0 and fuse < cap then cap = fuse end
    local room = num(cmd.cap_amps_per_phase)
    if room ~= nil and room >= 0 and room < cap then cap = room end
    if amps > cap then amps = cap end
    amps = math.floor(amps * STEPS_PER_A + 0.001) / STEPS_PER_A
    if amps < MIN_A then return 0 end
    return amps
end

local function write_limit(amps)
    local ma = math.floor(amps * 1000 + 0.5)
    local regs = { math.floor(ma / 65536), ma % 65536 }
    local ok, res = pcall(host.modbus_write_multi, REG_SETPOINT, regs)
    if not ok or (res ~= nil and res ~= true) then
        host.log("warn", "ABB Terra: writing current limit " .. tostring(amps) ..
            " A failed: " .. tostring(res))
        written_a = nil
        return false
    end
    written_a, written_at = amps, host.millis()
    limit_a = nil          -- the next poll reads the new value
    standdown_failed_at = nil
    return true
end

-- Write only on change. The one exception: the charger reports a limit
-- above ours, which means it lost our value (a restart, say).
local function apply(amps)
    local due = written_a ~= amps
    if not due and limit_a ~= nil and limit_a > amps + 0.5
        and (host.millis() - written_at) >= READBACK_MS then
        due = true
    end
    if not due then return true end
    local ok = write_limit(amps)
    if ok then commanded = true end
    return ok
end

----------------------------------------------------------------------------
-- Driver interface
----------------------------------------------------------------------------

function driver_init(config)
    host.set_make("ABB")
    if type(config) == "table" then
        local cap = tonumber(config.max_a)
        if cap and cap >= MIN_A and cap < HW_MAX_A then max_a_cfg = cap end
        local phases = tonumber(config.phases)
        if phases == 1 or phases == 3 then config_phases = phases end
    end
end

function driver_poll()
    local now = host.millis()

    -- Serial: eight bytes as ABB encodes them (connector, rating, plant,
    -- week, year, number). Reported as hex: stable, and nothing invented.
    if not sn_read then
        local sn = probe_read(REG_SERIAL, 4, "holding")
        if sn then
            host.set_sn(string.format("%04X%04X%04X%04X", sn[1], sn[2], sn[3], sn[4]))
            sn_read = true
        end
    end

    local b = probe_read(REG_BLOCK, BLOCK_COUNT, "holding", true)
    limit_a, device_max_a, active_phases = nil, nil, nil
    if not b then
        stall_since = nil
        return 5000  -- nothing read, nothing to report
    end

    device_max_a = scaled(b, 0x4006, 0.001)
    local error_code = u32(b, 0x4008)
    local lock = u32(b, 0x400A)
    local state_byte = math.floor((b[8] or 0) / 256)
    local code = state_byte % 128
    limit_a = scaled(b, 0x400E, 0.001)
    local a = {
        scaled(b, 0x4010, 0.001), scaled(b, 0x4012, 0.001), scaled(b, 0x4014, 0.001),
    }
    local v = {
        scaled(b, 0x4016, 0.1), scaled(b, 0x4018, 0.1), scaled(b, 0x401A, 0.1),
    }
    local power_w = u32(b, 0x401C)
    local session_wh = u32(b, 0x401E)

    local state = STATES[code]
    if state == nil and code == 5 and lock ~= nil then
        -- "Other": the socket lock state still says whether a car is there.
        state = { connected = (lock == 0x0101 or lock == 0x0111), charging = false }
    end
    local connected = state and state.connected
    local charging = state and state.charging

    -- Phases in use now, and the most this plug-in, so a pause does not
    -- make a three-phase car look single-phase again.
    if connected == false then
        seen_phases, active_phases = 0, 0
    elseif connected and not charging then
        active_phases = 0
    elseif charging then
        local active = 0
        for i = 1, 3 do
            if a[i] and a[i] >= ACTIVE_PHASE_A then active = active + 1 end
        end
        active_phases = active
        if active > seen_phases then seen_phases = active end
    end

    local stalled = false
    if connected and (written_a or 0) >= MIN_A and state.offering == false then
        stall_since = stall_since or now
        stalled = (now - stall_since) >= STALL_MS
    else
        stall_since = nil
    end

    local reason
    if connected and not charging then
        if error_code ~= nil and error_code ~= 0 then
            reason = "charger error " .. string.format("%d", error_code)
        elseif code == 1 then
            reason = "pending authorization"
        elseif state.request == false then
            reason = "vehicle not requesting current"
        elseif written_a == 0 then
            reason = "current limit below minimum"
        elseif state.offering == false then
            reason = "charger not offering current"
        end
    end

    host.emit("ev", {
        w               = power_w,
        connected       = connected,
        charging        = charging,
        request_active  = state and state.request,
        session_wh      = session_wh,
        l1_v = v[1], l2_v = v[2], l3_v = v[3],
        l1_a = a[1], l2_a = a[2], l3_a = a[3],
        -- 0x4100 cannot be read back. 0x400E is the limit the charger
        -- actually offers, so it stands for both the offer and the limit.
        max_a           = limit_a,
        current_limit_a = limit_a,
        phases          = seen_phases > 0 and seen_phases or nil,
        reason_no_current_label = reason,
        command_stalled = stalled,
    })

    if device_max_a then host.emit_metric("ev_device_max_a", device_max_a, "A") end
    if error_code then host.emit_metric("ev_error_code", error_code) end
    host.emit_metric("ev_below_commanded", state_byte >= 128 and 1 or 0)

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
        -- No order yet: nothing to resume to. Core's next ev_set_current
        -- sets the current; say so rather than claim a start.
        if ordered_a == nil then return false end
        return apply(ordered_a)
    end

    host.log("warn", "ABB Terra: unknown action " .. tostring(action))
    return false
end

-- Stand down: write 0 A once, which pauses the session. Nothing is written
-- if FTW never wrote a limit in this process, so a telemetry-only site keeps
-- charging as its installer set it up.
function driver_default_mode()
    ordered_a, paused = 0, false
    -- true tells Core the charger is stood down: FTW wrote nothing in this
    -- process, or the charger took 0 A.
    if not commanded or written_a == 0 then return true end
    -- FTW wrote a current and the charger has not taken 0 A, so a car may
    -- still be charging: say so. Retry once a minute, not on every watchdog
    -- tick, and say false in between.
    local now = host.millis()
    if standdown_failed_at ~= nil and now - standdown_failed_at < STANDDOWN_RETRY_MS then
        return false
    end
    if write_limit(0) then return true end
    standdown_failed_at = now
    return false
end

function driver_cleanup()
end
