-- BLUEPRINT.lua — the reference driver.
--
-- Copy this file, rename it, and replace the register map. Everything else is
-- already the way it should be.
--
-- This is not a device. It is a working driver for an imaginary inverter that
-- exists so every rule in this repository has one place to be demonstrated
-- rather than described. It compiles, it passes every check, and it runs
-- against the test harness. If you change the rules, change them here first.
--
-- Written to be read by people and by agents. For agents: the contract is
-- stated in full below, each rule appears next to the code that follows it,
-- and no rule is left implicit. You should not need any other file to write a
-- correct driver.
--
--
-- ═══ WHAT A DRIVER IS ═══════════════════════════════════════════════════════
--
-- A driver turns one device's registers into telemetry the host understands.
-- That is all. It does not decide policy, schedule, retry across polls, or
-- talk to anything but its own device.
--
-- The valuable part of a driver is not its code. It is the knowledge encoded
-- in it: which register holds what, what scale it uses, which firmware lies,
-- what the vendor documented wrongly. Write that knowledge down in comments
-- as you find it. A future reader cannot re-derive it from the numbers.
--
--
-- ═══ THE FIVE ENTRY POINTS ══════════════════════════════════════════════════
--
--   driver_init(config)      once, before the first poll
--   driver_poll()            repeatedly; returns ms until the next call
--   driver_command(...)      when the host wants the device to do something
--   driver_default_mode()    return the device to autonomous operation
--   driver_cleanup()         once, when the driver is being stopped
--
-- Only driver_poll is required. A read-only driver defines the first two and
-- stops there.
--
--
-- ═══ THE RULE THAT MATTERS MOST ═════════════════════════════════════════════
--
-- The host counts every failed Modbus read against the poll, and one failed
-- read fails the whole poll. A device that goes offline reports nothing at
-- all, which is worse than reporting less.
--
-- So: never read a register you have no reason to believe exists, and never
-- keep retrying one that has proved it does not. A customer's SG12RT lost all
-- telemetry for weeks because a driver read a battery block on an inverter
-- with no battery. See `optional_read` and `detect_model` below.
--
--
-- ═══ SIGN CONVENTION ════════════════════════════════════════════════════════
--
-- Positive watts flow INTO the site. Every driver, every device, no exceptions.
--
--   meter    positive = importing from the grid, negative = exporting
--   pv       always negative — generation reduces import
--   battery  positive = charging, negative = discharging
--   ev       positive = charging the car
--
-- Devices disagree with this constantly. Negate at the boundary, in one place,
-- with a comment saying what the device's own convention was.
--
--
-- ═══ NEVER FABRICATE ════════════════════════════════════════════════════════
--
-- A zero means "the device told me zero". It must never mean "I could not
-- read it". A fabricated zero flows into a site's energy totals and cannot be
-- distinguished from a real one afterwards.
--
-- If a register did not answer, leave the field out. If a whole stream did not
-- answer, do not emit the stream.
--
--
-- ═══ HOST API ═══════════════════════════════════════════════════════════════
--
-- The full list lives in spec/host-api-profile.json and is enforced by
-- tools/host_api_check.py. Two hosts spell some functions differently; both
-- spellings are valid and you should use whichever your target speaks.
--
--   identity    set_make, set_sn
--   telemetry   emit, emit_metric
--   diagnostics log, set_device_fault
--   timing      millis (FTW) / now_ms (Blixt), sleep, set_poll_interval
--   modbus      modbus_read, modbus_write (FTW) / write (Blixt)
--   decode      decode_i16, decode_u32_be, decode_u32_le, decode_i32_be, ...
--   transport   http_get, http_post, mqtt_pub, ws_open, tcp_open, ...
--   data        json_encode, json_decode
--
-- Arithmetic is not a host service. A float decoder or a scale factor belongs
-- in the driver, because it is maths, not I/O. Thirty-five drivers once called
-- decode helpers that existed only in the test mock; they passed every test
-- and would have failed on hardware.
--
-- The sandbox removes require, dofile, load, os, io and debug. A driver is one
-- self-contained file. This is why helpers are copied between drivers rather
-- than shared, and that is the accepted cost.

DRIVER = {
  -- Bumped when this repository releases. Must match manifests/<id>.yaml,
  -- unless the driver came from FTW verbatim, where the two count different
  -- lineages. `make bump-driver ID=<id>` moves both.
  version      = "1.0.0",

  host_api_min = 1,
  host_api_max = 1,

  id           = "blueprint",
  name         = "Blueprint reference inverter",
  manufacturer = "Sourceful",
  description  = "The reference driver. Copy it; do not deploy it.",
  protocols    = { "modbus" },

  -- What this driver emits. Must be DER types the host knows: meter, pv,
  -- battery, ev, v2x_charger, heatpump, vehicle. A driver that emits only
  -- metrics declares none, and says so rather than claiming telemetry.
  capabilities = { "pv", "battery", "meter" },

  -- Say what has actually been tested. "experimental" is honest for a driver
  -- written from a datasheet; "verified" means someone watched it on real
  -- hardware and the numbers were right.
  verification_status = "experimental",
  verification_notes  = "Imaginary device. Never verified and never will be.",

  tested_models = {},
  authors       = { "Sourceful contributors" },

  connection_defaults = {
    port    = 502,
    unit_id = 1,
  },
}

PROTOCOL = "modbus"

----------------------------------------------------------------------------
-- Register map
--
-- Write the map down, with the vendor's documented number beside the address
-- you actually use. Many vendors document register N and mean address N-1,
-- and every driver that gets this wrong reads one register off and produces
-- numbers that look almost right.
----------------------------------------------------------------------------

local REG_DEVICE_TYPE = 4999  -- documented 5000; identifies the model family
local REG_PV_W        = 5016  -- documented 5017; U32 LE, watts
local REG_METER_W     = 5600  -- documented 5601; I32 LE, watts, import positive
local REG_BATTERY_W   = 13020 -- documented 13021; U16 + direction bit
local REG_BATTERY_SOC = 13022 -- documented 13023; U16, 0.1 %

----------------------------------------------------------------------------
-- Decoding
--
-- Kept in the driver because it is arithmetic, not I/O.
----------------------------------------------------------------------------

-- IEEE-754 binary32 from two big-endian registers.
--
-- Work on the 16-bit halves. Combining them into one 32-bit word first
-- overflows on a build where Lua integers are 32 bits -- there 0x80000000 is
-- itself negative, and every value decodes with a flipped sign. Twelve
-- drivers shipped that bug.
local function decode_f32_be(hi, lo)
    local sign = 1
    if hi >= 0x8000 then sign = -1; hi = hi - 0x8000 end
    local exponent = math.floor(hi / 128)
    local mantissa = (hi % 128) * 65536 + lo
    if exponent == 0 then
        if mantissa == 0 then return 0 end
        return sign * mantissa * 2^-149
    end
    -- Infinity and NaN would poison every downstream sum; report nothing.
    if exponent == 0xFF then return 0 end
    return sign * (1 + mantissa / 0x800000) * 2^(exponent - 127)
end

-- Scaling can reintroduce what decode_f32_be just refused: a register holding
-- float32's largest value survives the decode and becomes infinity the moment
-- it is multiplied. Guard every scaled reading.
local function finite(value)
    if value ~= value then return 0 end
    if value == math.huge or value == -math.huge then return 0 end
    return value
end

----------------------------------------------------------------------------
-- Reading registers that may not exist
----------------------------------------------------------------------------

-- Absence has to be proved, not guessed. A single timeout or a busy bus must
-- not silence a register for the rest of the session, so only a run of
-- failures counts. Three is enough to distinguish "this device does not have
-- it" from "the bus hiccuped".
local MISSES_BEFORE_SKIP = 3
local miss_counts = {}

local function optional_read(address, count, kind)
    if (miss_counts[address] or 0) >= MISSES_BEFORE_SKIP then
        return nil
    end
    local ok, registers = pcall(host.modbus_read, address, count, kind)
    -- Check every register you asked for, not just the first. A short reply
    -- leaves the rest nil, and arithmetic on nil ends the whole poll.
    if ok and registers ~= nil then
        for i = 1, count do
            if registers[i] == nil then ok = false break end
        end
    end
    if ok and registers ~= nil then
        miss_counts[address] = nil
        return registers
    end
    local misses = (miss_counts[address] or 0) + 1
    miss_counts[address] = misses
    if misses >= MISSES_BEFORE_SKIP then
        host.log("info", "Blueprint: register " .. address
            .. " failed " .. misses .. " reads in a row; treating it as absent")
    end
    return nil
end

----------------------------------------------------------------------------
-- Knowing what you are talking to
--
-- Ask the device which model it is rather than discovering it through failed
-- reads. And bound the asking: a device that never answers this register
-- would otherwise cost one failed read on every poll forever, which is the
-- same outage the model detection exists to prevent.
----------------------------------------------------------------------------

local model_family = nil   -- "hybrid", "string", "unknown", or nil while asking
local DETECT_ATTEMPTS = 3
local detect_tries = 0

local function detect_model()
    detect_tries = detect_tries + 1
    local ok, regs = pcall(host.modbus_read, REG_DEVICE_TYPE, 1, "input")
    local code = nil
    if ok and regs ~= nil then code = regs[1] end

    -- 0 and 0xFFFF are the usual "not supported" sentinels. A sentinel is as
    -- inconclusive as no answer, and treating it as data invents a model.
    if code ~= nil and code ~= 0 and code ~= 0xFFFF then
        local family = math.floor(code / 256)
        if family == 0x0D or family == 0x0E then return "hybrid" end
        return "string"
    end

    if detect_tries >= DETECT_ATTEMPTS then
        host.log("info", "Blueprint: device type never readable; probing instead")
        return "unknown"
    end
    return nil
end

-- While detection is still running we hold off rather than probe. Detection
-- normally settles on the first poll, so a hybrid loses nothing, and a device
-- without a battery is spared a burst of failed reads it cannot afford. Only
-- once detection has given up do we probe and let optional_read decide.
local function has_battery()
    return model_family == "hybrid" or model_family == "unknown"
end

----------------------------------------------------------------------------
-- Entry points
----------------------------------------------------------------------------

local sn_read = false
local SN_ATTEMPTS = 3
local sn_tries = 0

function driver_init(config)
    -- Identity the host cannot work out for itself. Do it once, here.
    host.set_make("Sourceful")
end

function driver_poll()
    -- Serial number, once, bounded for the same reason detection is bounded.
    if not sn_read and sn_tries < SN_ATTEMPTS then
        sn_tries = sn_tries + 1
        local regs = optional_read(4989, 10, "input")
        if regs then
            local sn = ""
            for i = 1, 10 do
                local hi = math.floor(regs[i] / 256)
                local lo = regs[i] % 256
                if hi > 32 and hi < 127 then sn = sn .. string.char(hi) end
                if lo > 32 and lo < 127 then sn = sn .. string.char(lo) end
            end
            if string.len(sn) > 0 then
                host.set_sn(sn)
                sn_read = true
            end
        end
    end

    if model_family == nil then
        model_family = detect_model()
        if model_family then
            host.log("info", "Blueprint: detected a " .. model_family .. " device")
        end
    end

    ---------------------------------------------------------------------
    -- PV. Emitted negative: generation reduces what the site imports.
    ---------------------------------------------------------------------
    local pv_regs = optional_read(REG_PV_W, 2, "input")
    if pv_regs then
        host.emit("pv", {
            w = finite(host.decode_u32_le(pv_regs[1], pv_regs[2])) * -1,
        })
    end
    -- No else. A PV reading we could not take is not zero generation.

    ---------------------------------------------------------------------
    -- Meter.
    ---------------------------------------------------------------------
    local meter_regs = optional_read(REG_METER_W, 2, "input")
    if meter_regs then
        -- This device already reports import as positive, so it passes
        -- through. Say so, so the next reader does not wonder.
        host.emit("meter", {
            w = finite(host.decode_i32_le(meter_regs[1], meter_regs[2])),
        })
    end

    ---------------------------------------------------------------------
    -- Battery, only if this model has one.
    ---------------------------------------------------------------------
    if has_battery() then
        local power_regs = optional_read(REG_BATTERY_W, 1, "input")
        local soc_regs   = optional_read(REG_BATTERY_SOC, 1, "input")

        -- Emit the stream only if its defining reading answered. A battery
        -- stream carrying only a SoC is more confusing than none.
        if power_regs then
            local battery = {}

            -- The device reports magnitude plus a direction bit, and calls
            -- discharge positive. Our convention is the opposite, so negate.
            local magnitude = power_regs[1]
            local discharging = magnitude >= 0x8000
            if discharging then magnitude = magnitude - 0x8000 end
            battery.w = discharging and -magnitude or magnitude

            -- Add the optional field only when it answered. Absent beats zero.
            if soc_regs then
                battery.soc = soc_regs[1] * 0.001  -- 0.1 % -> 0..1 fraction
            end

            host.emit("battery", battery)
        end
    end

    ---------------------------------------------------------------------
    -- Diagnostics. Metrics are free and are what an operator has to work
    -- with at 2am. Emit what you decided and why, not just the result.
    ---------------------------------------------------------------------
    host.emit_metric("blueprint_model_known", model_family and 1 or 0)

    -- Milliseconds until the next poll. Five seconds suits most inverters;
    -- a meter that changes fast can go quicker, a cloud API must go slower.
    return 5000
end

----------------------------------------------------------------------------
-- Control
--
-- Everything below is optional. A read-only driver stops above, and most
-- drivers should: a driver that cannot write cannot break a customer's site.
----------------------------------------------------------------------------

-- The range float32 can hold. A setpoint arrives from the control plane, so a
-- unit slip or a NaN from a division upstream reaches this code directly.
-- Outside this range the encoder below has no honest answer: infinity spins
-- its normalising loop forever, and a value past the maximum comes back with
-- the sign bit set, turning a large charge into a small discharge.
local F32_MAX = 3.4028234663852886e38

function driver_command(action, power_w, cmd)
    if action == "init" then
        return true

    elseif action == "battery" then
        -- Refuse what this model cannot do, rather than writing registers it
        -- does not implement and hoping.
        if model_family == "string" then
            return false
        end
        -- Refuse what is not a number. Returning false is a failed command;
        -- writing an arbitrary value is a moved battery.
        if power_w ~= power_w or power_w > F32_MAX or power_w < -F32_MAX then
            host.log("warn", "Blueprint: refusing a setpoint of " .. tostring(power_w))
            return false
        end

        -- Divide before negating. On a 32-bit integer build, negating the
        -- smallest integer wraps to itself, so `-power_w` silently keeps its
        -- sign and the device charges when told to discharge.
        local target = -(power_w / 1000)

        -- Write order is part of the register map. Many devices ignore a
        -- setpoint written while still in autonomous mode, so mode goes
        -- first. Where order matters, say why and cite where you learned it.
        local mode_ok  = host.modbus_write(13049, 2)
        local power_ok = host.modbus_write(13051, math.floor(math.abs(target)))
        if not mode_ok or not power_ok then
            host.log("warn", "Blueprint: setpoint write failed")
            return false
        end
        return true

    elseif action == "deinit" then
        return driver_default_mode()
    end

    -- An action this driver does not implement is false, not silence.
    return false
end

-- Hand the device back to itself. The host calls this when it stops owning
-- the device, and on a watchdog timeout. A device left in forced mode with no
-- one commanding it is the worst state to leave a site in.
function driver_default_mode()
    return host.modbus_write(13049, 0) and true or false
end

function driver_cleanup()
    -- Release anything held open: sockets, subscriptions, sessions. A Modbus
    -- driver usually has nothing to do here, but say so rather than leaving
    -- the reader wondering whether it was forgotten.
end
