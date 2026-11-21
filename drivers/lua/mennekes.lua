-- Mennekes AMTRON / AMEDIO EV chargers over Modbus TCP
-- Emits: ev
-- Protocol: Modbus TCP, port 502
--
-- Mennekes ships two unrelated Modbus maps. The driver finds out which one
-- the charger speaks on the first polls, or takes `family` from config.
--
-- 1. ECU charge controller: AMTRON Professional, AMTRON Charge Control,
--    AMEDIO Professional (ECU firmware 5.12 or later). Source: Mennekes
--    "ECU-BRx and ECU-BBx Modbus TCP Server Specification", rev 1.07
--    (10 June 2022). Holding registers, 32-bit values high word first,
--    meter values 0xFFFFFFFF when there is no meter. Any unit id 1-255.
--      104        OCPP charge point status (6 = Charging, 4 = Faulted)
--      122        vehicle state (1 A, 2 B, 3 C, 4 D, 5 E)
--      131        SAFE_CURRENT (A): the current after a lost Modbus master
--      132        COMM_TIMEOUT (s): when the charger falls back to it
--      200..217   meter energy, power (W) and current (mA) per phase
--      218..227   total energy (Wh), total power (W), voltage per phase
--                 (V); firmware 5.22 and later only
--      705        charged energy this session (Wh, 16 bit)
--      706        SIGNALED_CURRENT (A): what the car is offered now
--      716..717   charged energy this session (Wh, 32 bit, 5.22 and later)
--      1000       HEMS_CURRENT_LIMIT (A), read/write. 0 pauses the session.
--    The charger falls back to SAFE_CURRENT when its Modbus master goes
--    quiet for COMM_TIMEOUT. The spec does not say whether reads count, so
--    the driver rewrites its limit at least every 15 s (or a third of
--    COMM_TIMEOUT) while Core sends orders.
--
-- 2. HCC3 controller: AMTRON Xtra and AMTRON Premium. Source: Mennekes
--    "AMTRON Modbus description" v1.031 (2018). Mennekes marks that document
--    confidential, so it is named here and not linked; evcc and others use
--    the same addresses. Input registers 0x0302.., holding 0x0400. 32-bit
--    values low word first. The Modbus server is off in the "Energy Manager"
--    and "SCU" operation modes, and takes one TCP connection.
--      0x0302     CP state (1 A1, 2 A2, 3 B1, 4 B2, 5 C1, 6 C2, 7 D1, 8 D2)
--      0x0304     HCC3 error code (0 = no error)
--      0x0308     phases (1 or 3)
--      0x0309     rated current (A)      0x030A  installation current (A)
--      0x030B     serial number (U32)    0x030D  session energy (Wh, U32)
--      0x030F     power (W, U32): derived from energy, so it lags and
--                 overshoots; the vendor calls it for display only
--      0x0400     customer current limitation (A), read/write: 0 or 6..32
--    The HCC3 keeps the last value written, with no timeout. If FTW stops
--    without standing down, the charger holds FTW's last limit.
--
-- Earlier versions of this driver read registers 100-300, which are in
-- neither map. Everything below is from the vendor documents.
--
-- Sign convention: an EVSE is a one-way load. Positive W is charging.

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "mennekes",
  name         = "Mennekes AMTRON",
  manufacturer = "Mennekes",
  version      = "1.1.0",
  protocols    = { "modbus" },
  capabilities = { "ev" },
  description  = "Mennekes AMTRON Professional, Charge Control and AMEDIO (ECU) and AMTRON Xtra/Premium (HCC3) over Modbus TCP. Telemetry and current-limit control.",
  homepage     = "https://www.mennekes.org/emobility",
  authors      = { "FTW contributors" },
  tested_models = { "AMTRON Professional", "AMTRON Charge Control", "AMEDIO Professional", "AMTRON Xtra", "AMTRON Premium" },
  verification_status = "experimental",
  verification_notes = "Control written from Mennekes' ECU Modbus TCP Server Specification rev 1.07 and AMTRON Modbus description v1.031; not yet confirmed on hardware.",
  connection_defaults = {
    port    = 502,
    unit_id = 255,
  },
}

PROTOCOL = "modbus"

----------------------------------------------------------------------------
-- Registers
----------------------------------------------------------------------------
local ECU_OCPP       = 104
local ECU_VEHICLE    = 122
local ECU_SAFE       = 131    -- 131..132: safe current, comm timeout
local ECU_METER      = 200    -- 200..217
local ECU_METER_NEW  = 218    -- 218..227, firmware 5.22+
local ECU_SESSION    = 705    -- 705..706: energy, signaled current
local ECU_SESSION32  = 716    -- 716..717, firmware 5.22+
local ECU_LIMIT      = 1000

local HCC3_BLOCK     = 0x0302 -- input 0x0302..0x0310
local HCC3_COUNT     = 15
local HCC3_LIMIT     = 0x0400

local ABSENT32       = 4294967295 -- 0xFFFFFFFF: no meter value

----------------------------------------------------------------------------
-- Control limits
----------------------------------------------------------------------------
local MIN_A          = 6       -- IEC 61851 minimum; below it we write 0
local HW_MAX_A       = 32      -- both maps cap at 32 A
local REFRESH_MS     = 15000   -- ECU: rewrite well inside COMM_TIMEOUT
local REFRESH_MIN_MS = 2000
local READBACK_MS    = 30000   -- rewrite a limit the charger lost, at this pace
local PAUSE_HOLD_MS  = 10000   -- keep a pause through Core's 3 s contactor cycle
local STALL_MS       = 30000
local ACTIVE_PHASE_A = 2       -- a phase carrying this much is in use
local WRITE_ATTEMPTS = 3       -- default mode stops after this many refusals

----------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------
local family = nil             -- "ecu" or "hcc3" once known
local max_a_cfg = HW_MAX_A
local device_max_a = nil       -- HCC3: rated and installation current

local ordered_a = nil          -- Core's latest order, after every cap
local paused = false
local paused_at = 0
local written_a = nil          -- last value the charger accepted; nil = unknown
local written_at = 0
local commanded = false        -- FTW has written a limit in this process
local default_failures = 0

local readback_a = nil         -- the limit register from the last poll
local comm_timeout_s = nil     -- ECU register 132
local seen_phases = 0          -- most phases seen carrying current this plug-in
local stall_since = nil
local sn_read = false

----------------------------------------------------------------------------
-- Reads
----------------------------------------------------------------------------

-- The host counts every failed modbus_read against the poll whether or not
-- Lua caught it, so a register this charger does not answer -- the 5.22
-- registers on older ECU firmware, the other family's map -- would cost a
-- failed read on every poll and the stale-telemetry watchdog would take the
-- site offline. Ask three times, since one miss can be a slow link, then
-- leave it alone until restart. No read sits on the command path.
local GIVE_UP_AFTER = 3
local read_failures = {}

local function probe_read(addr, count, kind)
    local key = kind .. addr
    if (read_failures[key] or 0) >= GIVE_UP_AFTER then return nil end
    local ok, regs = pcall(host.modbus_read, addr, count, kind)
    if ok and regs and regs[count] ~= nil then
        read_failures[key] = nil
        return regs
    end
    local failures = (read_failures[key] or 0) + 1
    read_failures[key] = failures
    if failures == GIVE_UP_AFTER then
        host.log("info", string.format(
            "Mennekes: %s register %d did not answer %d times; leaving it " ..
            "alone until restart", kind, addr, GIVE_UP_AFTER))
    end
    return nil
end

-- 32-bit unsigned from two registers. Float arithmetic, so a 32-bit integer
-- build cannot overflow. 0xFFFFFFFF is the ECU's "no meter" value.
local function u32(hi, lo)
    if hi == nil or lo == nil then return nil end
    local v = hi * 65536.0 + lo
    if v >= ABSENT32 then return nil end
    return v
end

local function ecu_u32(regs, base, addr)
    local i = addr - base + 1
    return u32(regs[i], regs[i + 1])
end

local function hcc3_u32(regs, addr)
    local i = addr - HCC3_BLOCK + 1
    return u32(regs[i + 1], regs[i])   -- low word first
end

-- Which map does this charger speak? An ECU answers holding register 122
-- with a vehicle state 1-5. Otherwise, an HCC3 answers its input block.
local function detect()
    local r = probe_read(ECU_VEHICLE, 1, "holding")
    if r and r[1] >= 1 and r[1] <= 5 then return "ecu" end
    if probe_read(HCC3_BLOCK, HCC3_COUNT, "input") then return "hcc3" end
    return nil
end

-- ECU vehicle state. B says nothing about PWM, so the offer comes from 706.
local ECU_VEHICLE_STATES = {
    [1] = { connected = false },
    [2] = { connected = true },
    [3] = { connected = true, request = true },
    [4] = { connected = true, request = true },
    [5] = { connected = false, fault = true },
}

-- HCC3 CP state. A digit 1 (B1, C1, D1) means no PWM: no current offered.
local HCC3_CP_STATES = {
    [1] = { connected = false, charging = false },
    [2] = { connected = false, charging = false },
    [3] = { connected = true,  charging = false, offering = false },
    [4] = { connected = true,  charging = false, offering = true,  request = false },
    [5] = { connected = true,  charging = false, offering = false, request = true },
    [6] = { connected = true,  charging = true,  offering = true,  request = true },
    [7] = { connected = true,  charging = false, offering = false, request = true },
    [8] = { connected = true,  charging = true,  offering = true,  request = true },
}

-- One ECU poll. Returns the emit table, or nil when power did not answer.
local function poll_ecu()
    local ocpp = probe_read(ECU_OCPP, 1, "holding")
    local veh = probe_read(ECU_VEHICLE, 1, "holding")
    local safe = probe_read(ECU_SAFE, 2, "holding")
    local meter = probe_read(ECU_METER, 18, "holding")
    local meter2 = probe_read(ECU_METER_NEW, 10, "holding")
    local sess = probe_read(ECU_SESSION, 2, "holding")
    local sess32 = probe_read(ECU_SESSION32, 2, "holding")
    local lim = probe_read(ECU_LIMIT, 1, "holding")

    readback_a = lim and lim[1] or nil
    comm_timeout_s = safe and safe[2] or nil
    if safe then host.emit_metric("ev_safe_current_a", safe[1], "A") end
    if comm_timeout_s then host.emit_metric("ev_comm_timeout_s", comm_timeout_s, "s") end

    local power_w, total_wh
    local a, v = {}, {}
    if meter2 then
        total_wh = ecu_u32(meter2, ECU_METER_NEW, 218)
        power_w = ecu_u32(meter2, ECU_METER_NEW, 220)
        for i = 1, 3 do v[i] = ecu_u32(meter2, ECU_METER_NEW, 220 + 2 * i) end
    end
    if meter then
        local p = {}
        for i = 1, 3 do
            p[i] = ecu_u32(meter, ECU_METER, 204 + 2 * i)          -- 206..210
            local ma = ecu_u32(meter, ECU_METER, 210 + 2 * i)      -- 212..216
            if ma then a[i] = ma / 1000 end
        end
        if power_w == nil and (p[1] or p[2] or p[3]) then
            -- Older firmware and single-phase meters put the total in L1
            -- and 0xFFFFFFFF in L2 and L3, so the sum is right either way.
            power_w = (p[1] or 0) + (p[2] or 0) + (p[3] or 0)
        end
        if total_wh == nil and ecu_u32(meter, ECU_METER, 202) == nil
            and ecu_u32(meter, ECU_METER, 204) == nil then
            total_wh = ecu_u32(meter, ECU_METER, 200)
        end
    end

    local session_wh
    if sess32 then session_wh = ecu_u32(sess32, ECU_SESSION32, 716) end
    if session_wh == nil and sess then session_wh = sess[1] end
    local signaled = sess and sess[2] or nil

    local vs = veh and ECU_VEHICLE_STATES[veh[1]] or nil
    local connected = vs and vs.connected
    local charging
    if ocpp then charging = ocpp[1] == 6 end
    local offering
    if connected and signaled ~= nil then offering = signaled >= MIN_A end
    local request = vs and vs.request
    if connected and request == nil and offering then request = false end

    local reason
    if connected and charging == false then
        if ocpp and ocpp[1] == 4 then
            reason = "charger faulted"
        elseif request == false then
            reason = "vehicle not requesting current"
        elseif written_a == 0 then
            reason = "current limit below minimum"
        elseif offering == false then
            reason = "charger not offering current"
        end
    end

    if power_w == nil then return nil, connected, charging, a, offering end
    return {
        w               = power_w,
        connected       = connected,
        charging        = charging,
        request_active  = request,
        session_wh      = session_wh,
        total_charge_wh = total_wh,
        l1_v = v[1], l2_v = v[2], l3_v = v[3],
        l1_a = a[1], l2_a = a[2], l3_a = a[3],
        max_a           = readback_a,
        current_limit_a = signaled,
        reason_no_current_label = reason,
    }, connected, charging, a, offering
end

-- One HCC3 poll. Returns the emit table, or nil when the block did not answer.
local function poll_hcc3()
    local b = probe_read(HCC3_BLOCK, HCC3_COUNT, "input")
    local lim = probe_read(HCC3_LIMIT, 1, "holding")
    readback_a = lim and lim[1] or nil
    device_max_a = nil
    if not b then return nil end

    local cp = HCC3_CP_STATES[b[1]]
    local error_code = b[3]
    local phase_setting = b[7]
    local rated, installed = b[8], b[9]
    if rated and installed and rated >= MIN_A and installed >= MIN_A then
        device_max_a = math.min(rated, installed)
    end
    if not sn_read then
        local sn = hcc3_u32(b, 0x030B)
        if sn and sn > 0 then
            host.set_sn(string.format("%d", sn))
            sn_read = true
        end
    end

    local connected = cp and cp.connected
    local charging = cp and cp.charging
    local reason
    if connected and not charging then
        if error_code ~= nil and error_code ~= 0 then
            reason = "charger error " .. string.format("%d", error_code)
        elseif cp.request == false then
            reason = "vehicle not requesting current"
        elseif written_a == 0 then
            reason = "current limit below minimum"
        elseif cp.offering == false then
            reason = "charger not offering current"
        end
    end
    if error_code then host.emit_metric("ev_error_code", error_code) end

    return {
        w               = hcc3_u32(b, 0x030F),
        connected       = connected,
        charging        = charging,
        request_active  = cp and cp.request,
        session_wh      = hcc3_u32(b, 0x030D),
        max_a           = readback_a,
        phases          = (phase_setting == 1 or phase_setting == 3) and phase_setting or nil,
        reason_no_current_label = reason,
    }, connected, charging, {}, cp and cp.offering
end

----------------------------------------------------------------------------
-- Control
----------------------------------------------------------------------------

local function num(v)
    if type(v) == "number" and v == v then return v end
    return nil
end

-- Watts to whole amps per phase, rounded down: both maps take whole amps.
-- Phases is the larger of Core's phase mode (1p is 1, anything else 3) and
-- the phases seen carrying current this plug-in. The 0.001 slack only
-- absorbs float error (4140 W / 690 V must be 6 A, not 5 A).
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
    if device_max_a ~= nil and device_max_a < cap then cap = device_max_a end
    local fuse = num(cmd.max_amps_per_phase)
    if fuse ~= nil and fuse > 0 and fuse < cap then cap = fuse end
    local room = num(cmd.cap_amps_per_phase)
    if room ~= nil and room >= 0 and room < cap then cap = room end
    if amps > cap then amps = cap end
    amps = math.floor(amps + 0.001)
    if amps < MIN_A then return 0 end
    return amps
end

local function write_limit(amps)
    local reg = family == "hcc3" and HCC3_LIMIT or ECU_LIMIT
    local ok, res = pcall(host.modbus_write, reg, amps)
    if not ok or (res ~= nil and res ~= true) then
        host.log("warn", "Mennekes: writing current limit " .. tostring(amps) ..
            " A failed: " .. tostring(res))
        written_a = nil
        return false
    end
    written_a, written_at = amps, host.millis()
    readback_a = nil       -- the next poll reads the new value
    default_failures = 0   -- one success proves the register takes writes
    return true
end

-- Write only on change, except the ECU's refresh and a limit the charger
-- lost or someone changed in the app.
local function apply(amps)
    if family == nil then
        host.log("warn", "Mennekes: no command before the charger type is known")
        return false
    end
    local age = host.millis() - written_at
    local due = written_a ~= amps
    if not due and family == "ecu" then
        local every = REFRESH_MS
        if comm_timeout_s and comm_timeout_s > 0 then
            every = math.max(REFRESH_MIN_MS, math.min(REFRESH_MS, comm_timeout_s * 1000 / 3))
        end
        due = age >= every
    end
    if not due and readback_a ~= nil and readback_a ~= amps and age >= READBACK_MS then
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
    host.set_make("Mennekes")
    if type(config) == "table" then
        if config.family == "ecu" or config.family == "hcc3" then
            family = config.family
        end
        local cap = tonumber(config.max_a)
        if cap and cap >= MIN_A and cap < HW_MAX_A then max_a_cfg = cap end
    end
end

function driver_poll()
    local now = host.millis()
    if family == nil then
        family = detect()
        if family == nil then return 5000 end
        host.log("info", "Mennekes: charger speaks the " .. family .. " map")
    end

    local data, connected, charging, a, offering
    if family == "ecu" then
        data, connected, charging, a, offering = poll_ecu()
    else
        data, connected, charging, a, offering = poll_hcc3()
    end

    if connected == false then
        seen_phases = 0
    elseif charging then
        local active = 0
        for i = 1, 3 do
            if a[i] and a[i] >= ACTIVE_PHASE_A then active = active + 1 end
        end
        if active > seen_phases then seen_phases = active end
    end

    local stalled = false
    if connected and (written_a or 0) >= MIN_A and offering == false then
        stall_since = stall_since or now
        stalled = (now - stall_since) >= STALL_MS
    else
        stall_since = nil
    end

    -- Power is the defining reading: without it there is nothing to report.
    if data and data.w ~= nil then
        data.command_stalled = stalled
        if seen_phases > 0 then data.phases = seen_phases end
        host.emit("ev", data)
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

    host.log("warn", "Mennekes: unknown action " .. tostring(action))
    return false
end

-- Stand down: write 0 A once. An ECU then falls back to SAFE_CURRENT when
-- FTW goes quiet; an HCC3 holds 0 A until FTW or the app sets a new limit.
-- Nothing is written if FTW never wrote a limit in this process, so a
-- telemetry-only site keeps charging as its installer set it up.
function driver_default_mode()
    ordered_a, paused = 0, false
    if not commanded or written_a == 0 then return true end
    -- A charger that refuses the write would otherwise be asked again on
    -- every watchdog tick for the life of the session.
    if default_failures >= WRITE_ATTEMPTS then return true end
    if write_limit(0) then return true end
    default_failures = default_failures + 1
    return false
end

function driver_cleanup()
end
