-- Wallbox Pulsar Plus, Pulsar Max, Commander 2 and Copper SB
-- Emits: ev
-- Reads only. This driver cannot control the charger.
--
-- Why it cannot: we found no documented local Modbus TCP register map for
-- these chargers. The Modbus that Wallbox's installation guides describe is
-- for its own load management (a Power Boost meter, power sharing between
-- chargers), not a server an energy manager can command. The control route
-- Wallbox documents is OCPP 1.6J ("OCPP activation and setup guide",
-- support.wallbox.com), and evcc controls these models over OCPP only. We
-- found no published Wallbox cloud API either.
--
-- Use FTW's built-in OCPP central system instead. It reads and controls these
-- chargers without any driver: set FTW's OCPP address in the myWallbox app
-- under Settings, External management, OCPP. See FTW's docs/ocpp.md.
--
-- What this driver reads: holding registers 4-5 (power), 7-8 (session
-- energy) and 9 (maximum current) on unit 1. They come from an early
-- community sketch, not from any Wallbox document, and are unverified: the
-- power and energy it reports may be wrong or absent. A value is reported only
-- when its register answered, and nothing is reported as 0 W that was not
-- read.

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "wallbox",
  name         = "Wallbox (Modbus, reads only)",
  manufacturer = "Wallbox",
  version      = "1.1.0",
  protocols    = { "modbus" },
  capabilities = { "ev" },
  read_only    = true,
  description  = "Cannot control: we found no documented local Modbus interface for the Pulsar Plus, Pulsar Max, Commander 2 or Copper SB. The power and energy this driver reports come from registers no Wallbox document lists, and are unverified. Connect the charger to FTW's built-in OCPP central system instead; Wallbox supports OCPP 1.6J, and FTW reads and controls it that way without a driver.",
  homepage     = "https://support.wallbox.com/en/knowledge-base/ocpp-activation-and-setup-guide/",
  authors      = { "FTW contributors" },
  tested_models = { "Commander 2", "Pulsar Plus" },
  verification_status = "experimental",
}

PROTOCOL = "modbus"

-- Bounded register probe. The host counts every failed host.modbus_read
-- against the poll, even one pcall caught here. A driver that keeps reading a
-- register that never answers is marked offline by the stale-telemetry
-- watchdog. So: three tries, then leave the register alone.
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
            "Wallbox: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

function driver_init(config)
    host.set_make("Wallbox")
    host.log("info", "Wallbox: reads only, from an unverified register map. " ..
        "Use FTW's OCPP central system to read and control this charger.")
end

function driver_poll()
    -- Unverified: power in W at 4-5 (U32), session energy in Wh at 7-8 (U32),
    -- maximum current in A at 9, state at 0.
    local w_regs = probe_read(4, 2, "holding")
    if not w_regs then
        -- Power is this stream's defining reading. Without it, say nothing.
        return 5000
    end
    local se_regs = probe_read(7, 2, "holding")
    local mc_regs = probe_read(9, 1, "holding")

    host.emit("ev", {
        w          = host.decode_u32_be(w_regs[1], w_regs[2]),
        session_wh = se_regs and host.decode_u32_be(se_regs[1], se_regs[2]) or nil,
        max_a      = mc_regs and mc_regs[1] or nil,
    })

    return 5000
end

function driver_cleanup()
end
