-- SAJ H2 / HS2 hybrid (and AS2 string) inverter driver.
-- Emits: PV, Battery (when a pack is present), Meter
-- Protocol: Modbus TCP, HOLDING registers (FC 0x03), port 502, unit 1
--
-- Register map: SAJ H2-Protocol as implemented by the community sources
-- this driver was decoded from, not the untested input-0x10xx map the
-- previous stub used:
--   * stanus74/home-assistant-saj-h2-modbus (modbus_readers.py, register_overview.md)
--   * evcc template saj-h2 (templates/definition/meter/saj-h2.yaml)
-- Ampere.StoragePro / EKD-Solar is a rebadged HS2 and speaks the same map.
-- AS2 is the string (no-storage) sibling: same inverter registers, no pack.
--
-- A document behind SAJ's own portal cannot be watched; the public maps
-- above are what a weekly fetch can still check.
--
-- Sign convention (site: positive watts flow INTO the site):
--   pv.W        always negative (generation)
--   battery.W   positive = charging, negative = discharging
--   meter.W     positive = import, negative = export
--
-- Vendor signs, recorded because they are the whole reason this file exists:
--   0x40A5 TotalPVPower        I16 W, generation as a magnitude (evcc uses it
--                              as PV production with no sign flip)
--   0x40A6 TotalBatteryPower   I16 W, discharge-positive (evcc battery is
--                              discharge-positive and does not flip this
--                              register, so we negate at the boundary)
--   0x40AD SysGridPowerWall    I16 W, import-positive (evcc grid, no flip)
--   0xA00C Bat1SOC             U16, 0.01 % (raw 8500 = 85.00 %)
--   0xA00B BatOnline           U16, 0 = no pack
--   0xA000 BatNum              U16, 0 = no pack
--
-- A hybrid is sold with and without storage. Emitting battery.W = 0 /
-- battery.SoC_nom_fract = 0 when the BMS block is missing or reports no
-- pack does not mean "no battery": it means an empty pack the planner can
-- dispatch into. AS2 and a PV-only H2 commissioning must stay silent on
-- the battery stream.
--
-- CONTROL is off. The H2 protocol has a real lever — AppMode 0x3647
-- (0=self-use, 1=time-of-use, 2=backup, 3=passive) and the passive
-- charge/discharge setpoints in the 0x3636 block, which is how evcc and
-- the HA integration force charge. A 0 W hold must not fall back to
-- self-use: that lets the inverter charge from PV on its own, which is
-- why Huawei's unverified stop command was stripped. Until a named H2/HS2
-- and firmware prove held zero, charge, discharge and a safe release,
-- this driver does not write.

DRIVER = {
  id           = "saj",
  name         = "SAJ H2/HS2 hybrid inverter",
  manufacturer = "SAJ",
  version      = "1.2.0",
  host_api_min = 1,
  host_api_max = 1,
  protocols    = { "modbus" },
  capabilities = { "pv", "battery", "meter" },
  read_only    = true,
  description  = "SAJ H2/HS2 three- and single-phase hybrids (and AS2 string) via Modbus TCP. Battery telemetry only when the BMS block reports a pack. Read-only until a held-zero command is verified on hardware.",
  homepage     = "https://www.saj-electric.com",
  authors      = { "Sourceful Labs AB" },
  tested_models = { "H2", "HS2", "AS2" },
  verification_status = "experimental",
  verification_notes = "Decoded from the SAJ H2-Protocol as implemented by evcc saj-h2 and stanus74/home-assistant-saj-h2-modbus. Not yet verified against live hardware on an FTW site. Control stays disabled until a named H2/HS2 proves held zero.",
  connection_defaults = {
    port    = 502,
    unit_id = 1,
  },
}

PROTOCOL = "modbus"

----------------------------------------------------------------------------
-- Register map (holding, documented hex next to the address we actually use)
----------------------------------------------------------------------------

-- Identity at 0x8F00: devtype, subtype, commver, SN (10), PC (10), versions.
local REG_INVERTER_INFO = 36608  -- 0x8F00, 29 registers
local INFO_COUNT        = 29
local SN_OFFSET         = 4      -- 1-based index of the first SN register
local SN_REGS           = 10

-- Live power at 0x40A5..0x40AD (additional_data_1_part_2, evcc's live keys).
local REG_POWER = 16549  -- 0x40A5 TotalPVPower
local POWER_COUNT = 9    -- through 0x40AD SysGridPowerWall
local IDX_PV_W    = 1
local IDX_BAT_W   = 2
local IDX_GRID_W  = 9

-- PV strings and battery temperature at 0x406E (additional_data_1_part_1).
local REG_STRINGS = 16494  -- 0x406E
local STRINGS_COUNT = 15

-- Per-phase grid at 0x4031 (additional_data_4): 7 registers per phase × 3.
local REG_PHASES = 16433  -- 0x4031 RGridVolt
local PHASES_COUNT = 21
local PHASE_STRIDE = 7

-- BMS / pack at 0xA000. Presence lives here, not in the live power word.
local REG_BMS = 40960  -- 0xA000 BatNum
local BMS_COUNT = 18
local IDX_BAT_NUM     = 1   -- 0xA000
local IDX_BAT_CAP     = 2   -- 0xA001
local IDX_BAT_ONLINE  = 12  -- 0xA00B
local IDX_BAT1_SOC    = 13  -- 0xA00C
local IDX_BAT1_SOH    = 14  -- 0xA00D
local IDX_BAT1_V      = 15  -- 0xA00E
local IDX_BAT1_A      = 16  -- 0xA00F
local IDX_BAT1_TEMP   = 17  -- 0xA010
local IDX_BAT1_CYCLES = 18  -- 0xA011

-- Lifetime energy, U32 BE × 0.01 kWh.
local REG_PV_ENERGY        = 16581  -- 0x40C5 Total_PVEnergy
local REG_BAT_CHARGE_WH    = 16589  -- 0x40CD bat_total_charge
local REG_BAT_DISCHARGE_WH = 16597  -- 0x40D5 bat_total_discharge

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

local function finite(value)
    if value ~= value then return nil end
    if value == math.huge or value == -math.huge then return nil end
    return value
end

-- 0 and 0xFFFF are the usual "not present" sentinels on this map. A
-- sentinel is as inconclusive as no answer.
local function present_u16(value)
    return value ~= nil and value ~= 0xFFFF
end

local function decode_ascii(regs, start, count)
    local s = ""
    local last = start + count - 1
    for i = start, last do
        local word = regs[i]
        if word == nil then break end
        local hi = math.floor(word / 256)
        local lo = word % 256
        if hi > 32 and hi < 127 then s = s .. string.char(hi) end
        if lo > 32 and lo < 127 then s = s .. string.char(lo) end
    end
    return s
end

-- 0.01 kWh → Wh. Work on the 16-bit halves; combining them first overflows
-- on a 32-bit Lua integer build.
local function u32_to_wh(hi, lo)
    local raw = host.decode_u32_be(hi, lo)
    return finite(raw * 10)
end

----------------------------------------------------------------------------
-- Reading registers that may not exist
--
-- The host counts every failed host.modbus_read against the poll whether or
-- not this driver caught the error. A register retried on every poll costs a
-- failed poll on every poll, and the stale-telemetry watchdog takes the
-- driver offline. The site then reports nothing at all, which is worse than
-- reporting one field less.
--
-- Three attempts absorb a transient blip; after that we stop asking. A
-- restart re-probes, so firmware that gains the register is picked up.
--
-- The live power block (0x40A5) deliberately does NOT go through here: when
-- it fails the driver emits nothing at all, so it never claims the device is
-- fine while paying for a failed read, and a blip cannot silence PV and the
-- meter for the rest of the session.
----------------------------------------------------------------------------

local GIVE_UP_AFTER = 3
local read_failures = {}

local function probe_read(addr, count, kind)
    if (read_failures[addr] or 0) >= GIVE_UP_AFTER then return nil end
    local ok, regs = pcall(host.modbus_read, addr, count, kind)
    if ok and regs ~= nil then
        for i = 1, count do
            if regs[i] == nil then
                ok = false
                break
            end
        end
    end
    if ok and regs ~= nil then
        read_failures[addr] = nil
        return regs
    end
    local failures = (read_failures[addr] or 0) + 1
    read_failures[addr] = failures
    if failures == GIVE_UP_AFTER then
        host.log("info", string.format(
            "SAJ: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

local function required_read(addr, count, kind)
    local ok, regs = pcall(host.modbus_read, addr, count, kind)
    if not ok or regs == nil then return nil end
    for i = 1, count do
        if regs[i] == nil then return nil end
    end
    return regs
end

----------------------------------------------------------------------------
-- Identity, once, bounded
----------------------------------------------------------------------------

local sn_read = false
local SN_ATTEMPTS = 3
local sn_tries = 0

local function read_identity()
    if sn_read or sn_tries >= SN_ATTEMPTS then return end
    sn_tries = sn_tries + 1
    local regs = probe_read(REG_INVERTER_INFO, INFO_COUNT, "holding")
    if not regs then return end
    local sn = decode_ascii(regs, SN_OFFSET, SN_REGS)
    if string.len(sn) > 0 then
        host.set_sn(sn)
        sn_read = true
    end
    -- devtype/subtype are numeric family codes, not a model string the
    -- operator would recognise. Surface them as metrics; do not invent a
    -- model name from a code we have not been taught.
    if present_u16(regs[1]) then
        host.emit_metric("saj_devtype", regs[1])
    end
    if present_u16(regs[2]) then
        host.emit_metric("saj_subtype", regs[2])
    end
end

----------------------------------------------------------------------------
-- Entry points
----------------------------------------------------------------------------

function driver_init(config)
    host.set_make("SAJ")
end

function driver_poll()
    read_identity()

    ---------------------------------------------------------------------
    -- Live power. One 9-register read covers PV, battery power and the
    -- site-meter word evcc uses as the grid reading.
    ---------------------------------------------------------------------
    local power = required_read(REG_POWER, POWER_COUNT, "holding")

    ---------------------------------------------------------------------
    -- PV
    ---------------------------------------------------------------------
    if power then
        local pv_mag = math.abs(host.decode_i16(power[IDX_PV_W]))
        local pv = {}
        pv.W = -pv_mag

        local strings = probe_read(REG_STRINGS, STRINGS_COUNT, "holding")
        if strings then
            local function add_mppt(slot, v_i, a_i, w_i)
                local v = finite(strings[v_i] * 0.1)
                local a = finite(strings[a_i] * 0.01)
                local w = strings[w_i]
                -- A tracker that is not fitted answers zero volts. Leave it
                -- out rather than reporting a dead string as a live one.
                if v ~= nil and v > 0 then
                    pv["mppt" .. slot .. "_v"] = v
                    if a ~= nil then pv["mppt" .. slot .. "_a"] = a end
                    if w ~= nil then pv["mppt" .. slot .. "_w"] = w end
                end
            end
            add_mppt(1, 4, 5, 6)
            add_mppt(2, 7, 8, 9)
            add_mppt(3, 10, 11, 12)
            add_mppt(4, 13, 14, 15)
            local bat_temp = finite(host.decode_i16(strings[1]) * 0.1)
            if bat_temp ~= nil then
                host.emit_metric("saj_bat_temp_c", bat_temp)
            end
        end

        local pv_e = probe_read(REG_PV_ENERGY, 2, "holding")
        if pv_e then
            local wh = u32_to_wh(pv_e[1], pv_e[2])
            if wh ~= nil then pv.lifetime_wh = wh end
        end

        host.emit("pv", pv)
    end

    ---------------------------------------------------------------------
    -- Meter
    ---------------------------------------------------------------------
    if power then
        -- Vendor import-positive, matches the site convention.
        local meter = { W = host.decode_i16(power[IDX_GRID_W]) }
        local phases = probe_read(REG_PHASES, PHASES_COUNT, "holding")
        if phases then
            local function phase(name, base)
                local v = finite(phases[base] * 0.1)
                local a = finite(host.decode_i16(phases[base + 1]) * 0.01)
                local hz = finite(phases[base + 2] * 0.01)
                local w = host.decode_i16(phases[base + 4])
                if v ~= nil then meter[name .. "_V"] = v end
                if a ~= nil then meter[name .. "_A"] = a end
                if w ~= nil then meter[name .. "_W"] = w end
                return hz
            end
            local hz1 = phase("L1", 1)
            phase("L2", 1 + PHASE_STRIDE)
            phase("L3", 1 + PHASE_STRIDE * 2)
            if hz1 ~= nil then meter.Hz = hz1 end
        end
        host.emit("meter", meter)
    end

    ---------------------------------------------------------------------
    -- Battery, only when the BMS block says a pack is there.
    --
    -- Live battery power (0x40A6) answers on a string inverter too, usually
    -- as zero. That is not presence. BatNum / BatOnline are.
    ---------------------------------------------------------------------
    local bms = probe_read(REG_BMS, BMS_COUNT, "holding")
    local bat_num = bms and bms[IDX_BAT_NUM] or nil
    local bat_online = bms and bms[IDX_BAT_ONLINE] or nil
    local pack_present = bms
        and present_u16(bat_num)
        and present_u16(bat_online)
        and bat_num > 0
        and bat_online > 0

    if pack_present and power then
        local battery = {}
        -- Vendor discharge-positive → site charge-positive.
        battery.W = -host.decode_i16(power[IDX_BAT_W])

        local soc_raw = bms[IDX_BAT1_SOC]
        if present_u16(soc_raw) then
            -- 0.01 % → 0..1 fraction. / 10000, not / 100: raw 8500 is 85 %.
            battery.SoC_nom_fract = soc_raw / 10000
        end

        local v = bms[IDX_BAT1_V]
        if present_u16(v) then
            local volts = finite(v * 0.1)
            if volts ~= nil then battery.V = volts end
        end

        -- Current follows the same vendor sign as power (discharge-positive),
        -- so it is negated to match battery.W.
        local a = finite(host.decode_i16(bms[IDX_BAT1_A]) * 0.01)
        if a ~= nil then battery.A = -a end

        local t = finite(host.decode_i16(bms[IDX_BAT1_TEMP]) * 0.1)
        if t ~= nil then battery.temperature_C = t end

        local chg = probe_read(REG_BAT_CHARGE_WH, 2, "holding")
        if chg then
            local wh = u32_to_wh(chg[1], chg[2])
            if wh ~= nil then battery.total_charge_Wh = wh end
        end
        local dis = probe_read(REG_BAT_DISCHARGE_WH, 2, "holding")
        if dis then
            local wh = u32_to_wh(dis[1], dis[2])
            if wh ~= nil then battery.total_discharge_Wh = wh end
        end

        host.emit("battery", battery)
        host.emit_metric("saj_battery_count", bat_num)
        host.emit_metric("saj_battery_online", bat_online)
        if present_u16(bms[IDX_BAT_CAP]) then
            host.emit_metric("saj_battery_capacity", bms[IDX_BAT_CAP])
        end
        if present_u16(bms[IDX_BAT1_SOH]) then
            host.emit_metric("saj_bat1_soh_pct", bms[IDX_BAT1_SOH] * 0.01)
        end
        if present_u16(bms[IDX_BAT1_CYCLES]) then
            host.emit_metric("saj_bat1_cycles", bms[IDX_BAT1_CYCLES])
        end
    elseif bms and not pack_present then
        host.emit_metric("saj_battery_count", 0)
        host.emit_metric("saj_battery_online", 0)
    end

    return 5000
end

function driver_command(action, power_w, cmd)
    if action == "init" or action == "deinit" then
        return true
    end
    host.log("warn", "SAJ: control is not enabled (action=" .. tostring(action) .. ")")
    return false
end

function driver_default_mode()
    -- Read-only: the driver never took control, so there is nothing to release.
end

function driver_cleanup()
    sn_read = false
    sn_tries = 0
    read_failures = {}
end
