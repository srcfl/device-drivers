-- AlphaESS Smile Series Inverter Driver
-- Emits: PV, Battery, Meter
-- Register type: HOLDING (FC 0x03)
-- Port: 502
-- Community tier (untested)
--
-- Register map: AlphaESS "Modbus_RTU/TCP Protocol" and its "Parameter
-- address table" (protocol history up to V1.39, 2024-11-29), as published
-- in ramonvanraaij/ha-alphaess-modbus docs/. The vendor's "Household
-- Register Map" table gives the same meter (0x0010-0x0036), battery
-- (0x0100-0x0148) and inverter (0x0400-0x0452) blocks for SMILE-SP,
-- SMILE-G3 (S3.6, S5, B5, S6, S8, T4-T20), SMILE-S6-HV, SMILE-T10-HV and
-- B3/B3PLUS. evcc's alpha-ess-smile template, dxoverdy/Alpha2MQTT and
-- senalse/ha-alphaess-modbus read the same addresses; they were used for
-- addresses, types and signs only.
--
-- Older firmware: protocol V1.17 (2020) put the grid meter at
-- 0x0000-0x0019 (total power at 0x0006) and the inverter temperature at
-- 0x0429, where V1.39 has PV4. V1.19 (2020-10-20) changed the meter table
-- and V1.20 (2020-10-25) added the System info block, 0x0740-0x074E. The
-- driver uses the current meter and PV strings 4 to 6 only once 0x074E
-- answers (see detect_map below).

-- No control code has been written for this inverter yet: driver_command
-- only refuses. It says read_only so FTW and the catalog tell the owner
-- plainly, instead of offering control that cannot work.
DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "alphaess",
  name         = "AlphaESS inverter",
  manufacturer = "AlphaESS",
  version      = "1.3.0",
  protocols    = { "modbus" },
  capabilities = { "pv", "battery", "meter" },
  read_only    = true,
  description  = "AlphaESS Smile and G2 series inverters via Modbus TCP. Read-only: no control code has been written for it yet, so FTW reads it but cannot charge or discharge the battery.",
}

PROTOCOL = "modbus"

-- A register the inverter never answers costs a failed read on every poll for
-- as long as the driver keeps asking. The host counts those failures against
-- the poll whether or not the pcall caught them, so a driver that keeps
-- reporting telemetry while permanently failing one read gets the whole site
-- marked offline. Give a register three chances, then leave it alone until
-- restart. Three rather than one: a single failure is not proof, the link may
-- just have been slow.
--
-- A short reply counts as a failure: every register asked for must be there,
-- or a decode further down would do arithmetic on nil.
local GIVE_UP_AFTER = 3
local read_failures = {}

local function probe_read(addr, count, kind)
    if (read_failures[addr] or 0) >= GIVE_UP_AFTER then return nil end
    local ok, regs = pcall(host.modbus_read, addr, count, kind)
    if ok and regs then
        for i = 1, count do
            if regs[i] == nil then ok = false break end
        end
    end
    if ok and regs then
        read_failures[addr] = nil
        return regs
    end
    local failures = (read_failures[addr] or 0) + 1
    read_failures[addr] = failures
    if failures == GIVE_UP_AFTER then
        host.log("info", string.format(
            "AlphaESS: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

-- A cell temperature outside -40..100 C is a sentinel or a misread.
local function plausible_temp(c)
    if c < -40 or c > 100 then return nil end
    return c
end

-- Which map the firmware speaks. 0x074E "Protocol Version" is in the
-- System info block that V1.20 added; the vendor's model table lists it for
-- every model. Its value is not used: Alpha2MQTT's register dump from a
-- real system shows it as 0. So the gate is whether it answers at all.
-- nil while asking; "current" once it answered; "old" after it failed
-- GIVE_UP_AFTER times. A firmware between V1.20 and V1.22, which changed the
-- inverter block again, cannot be told apart from a later one.
local map_version = nil

local function detect_map()
    if map_version ~= nil then return map_version end
    if probe_read(0x074E, 1, "holding") then
        map_version = "current"
    elseif (read_failures[0x074E] or 0) >= GIVE_UP_AFTER then
        map_version = "old"
        host.log("warn", "AlphaESS: register 0x074E does not answer, so this " ..
            "firmware predates protocol V1.20; grid meter and PV strings 4-6 " ..
            "left out")
    end
    return map_version
end

function driver_init(config)
    host.set_make("AlphaESS")
end

function driver_poll()
    local map = detect_map()

    -- ---- PV ----
    --
    -- 0x041D-0x0434 in one read: per string voltage (U16 x 0.1 V), current
    -- (U16 x 0.1 A) and power (U32, 1 W), strings 1 to 6, four registers
    -- apart. PV power is their sum. Strings 1 to 3 (0x041D-0x0428) sit in
    -- the same place in V1.17; until the current map is confirmed only they
    -- are read. 0x0453 "Pv total power" is newer than the 0x0400-0x0452
    -- block the vendor lists for every model, so it is not used. A PV meter
    -- for an AC-coupled inverter (0x00A1) is not added: that inverter may
    -- have its own driver.
    local pv_count = (map == "current") and 24 or 12
    local pv_regs = probe_read(0x041D, pv_count, "holding")
    if pv_regs then
        local pv_w = 0
        for i = 3, pv_count - 1, 4 do
            pv_w = pv_w + host.decode_u32_be(pv_regs[i], pv_regs[i + 1])
        end
        host.emit("pv", {
            W       = -pv_w,  -- generation is negative (site convention)
            mppt1_v = pv_regs[1] * 0.1,
            mppt1_a = pv_regs[2] * 0.1,
        })
    end

    -- ---- Battery ----
    --
    -- 0x0100-0x0126 in one read (the "Household Battery" block):
    --   0x0100 battery voltage        U16 x 0.1 V
    --   0x0102 battery SOC            U16 x 0.1 %
    --   0x010D min cell temperature   S16 x 0.1 C
    --   0x0110 max cell temperature   S16 x 0.1 C
    --   0x0126 battery power          S16, 1 W, "-: Charge, +: Discharge"
    -- AlphaESS counts discharge as positive, so the power is negated here
    -- (site convention: charging is positive). evcc reads it the same way.
    -- senalse's map describes it as positive when charging; the vendor's
    -- table, evcc and Alpha2MQTT all say the opposite.
    --
    -- The block has no pack temperature, so temperature_C is left out.
    -- 0x0111/0x0112 "Battery max charge/discharge current" (U16 x 0.1 A)
    -- are not used as live limits: the vendor does not say they move with
    -- the BMS, and Alpha2MQTT's author saw the charge value stay at 0 and
    -- the discharge value at 100 A on a 50 A pack. A 0 would tell Core the
    -- battery may not charge.
    --
    -- Voltage and SoC both 0 means no pack is connected, not an empty one
    -- (docs/WRITING-A-DRIVER.md, "A hybrid inverter may have no battery"):
    -- the battery stream and its metrics are left out.
    local bat_regs = probe_read(0x0100, 39, "holding")
    if bat_regs and bat_regs[1] == 0 and bat_regs[3] == 0 then
        bat_regs = nil
    end
    if bat_regs then
        local battery = {
            W = -host.decode_i16(bat_regs[39]),       -- 0x0126
            V = bat_regs[1] * 0.1,                     -- 0x0100
        }
        local soc_raw = bat_regs[3]                    -- 0x0102
        if soc_raw <= 1000 then
            battery.SoC_nom_fract = soc_raw / 1000     -- 0.1 % per bit
        end
        host.emit("battery", battery)

        local low_c  = plausible_temp(host.decode_i16(bat_regs[14]) * 0.1)  -- 0x010D
        local high_c = plausible_temp(host.decode_i16(bat_regs[17]) * 0.1)  -- 0x0110
        if low_c ~= nil then
            host.emit_metric("battery_cell_temp_min_c", low_c)
        end
        if high_c ~= nil then
            host.emit_metric("battery_cell_temp_max_c", high_c)
        end
    end

    -- ---- Meter ----
    --
    -- 0x0017-0x0022 in one read (the grid meter's running data):
    --   0x0017 current of A phase     S16 x 0.1 A
    --   0x001A grid frequency         U16 x 0.01 Hz
    --   0x0021 total active power     S32, 1 W
    -- Total power is positive when drawing from the grid and negative when
    -- feeding it (Alpha2MQTT: "Minus = feeding, Positive = drawing"; evcc
    -- and senalse read it the same way), which is the site convention, so it
    -- is passed through. The vendor's table gives no sign.
    --
    -- Phase voltage (0x0014) is left out: the vendor says 1 V per bit,
    -- Alpha2MQTT's author read 2421 for 242.1 V, and the sources do not
    -- agree on the scale.
    --
    -- The map has no flag that says a meter is fitted. 0x0000 "Grid Meter
    -- CT Enable" read 0 on a working system in Alpha2MQTT's dump, and
    -- 0x0806 "Meter CT Select" only says CT or meter. So with no meter the
    -- driver sends whatever these registers hold, and 0 W cannot be told
    -- from a balanced site. Read only on the current map (see detect_map).
    local m_regs = nil
    if map == "current" then
        m_regs = probe_read(0x0017, 12, "holding")
    end
    if m_regs then
        host.emit("meter", {
            W    = host.decode_i32_be(m_regs[11], m_regs[12]),  -- 0x0021
            L1_A = host.decode_i16(m_regs[1]) * 0.1,             -- 0x0017
            Hz   = m_regs[4] * 0.01,                             -- 0x001A
        })
    end

    return 5000
end

function driver_command(action, power_w, cmd)
    host.log("AlphaESS control not yet implemented: " .. action)
    return false
end

function driver_default_mode()
end

function driver_cleanup()
    -- nothing to clean up
end
