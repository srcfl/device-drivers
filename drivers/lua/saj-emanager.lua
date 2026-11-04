-- SAJ eManager C1 Pro site controller.
-- Emits: PV, Battery (only when the aggregate says a pack is there), Meter
-- Protocol: Modbus TCP only, HOLDING registers (FC 0x03), port 502, unit 1
--
-- The interface sheet marks Modbus RTU as "Not supported". This driver has
-- no serial settings and does not speak RTU. The catalog protocol field is
-- still "modbus" because that is the only Modbus value the manifest allows.
--
-- Register map (community, not an official SAJ publication):
--   Modbus_registers_eManager.xlsx, posted by remkoteselle on
--   github.com/stanus74/home-assistant-saj-h2-modbus discussion #182.
--   Sheets: Interface spec, EMS Mapping table, Real-time Data Table,
--   EMS Energy Dispatch Control, sec-c Anti-Backflow Control.
--   A text dump of that workbook is what this file was decoded from.
--   SAJ's own portal copies are not linked here; a document behind a login
--   cannot be watched.
--
-- Cross-checks, not the map this driver reads:
--   * Eniris SmartgridOne, "SAJ eManager-C1 Pro" (still marked in testing):
--     docs.eniris.com — TCP 502, unit 1, and the voltage/frequency note below.
--   * OpenEMS io.openems.edge.saj (xeno27/openems pull 2), the CH2 PCS
--     map from SAJ "Protocol for CH2 remote EMS control". Same 0x8400-0x8405
--     control block. Direct CH2 realtime is 0x7B04-0x7C88, which this
--     controller map does not use. Not hardware-validated there either.
--   * The H2 holding map in drivers/lua/saj.lua, for sign and word order.
--
-- This build is read-only and has not been run on hardware. The first site
-- to check is Castellum Örebro (3x CHS2 50 kW behind one eManager).
--
-- ═══ Addresses (holding, hex is the sheet's number) ═══════════════════════
--
--   0x4A00  DeviceNum            U16   connected devices, 0..21
--   0x4A01  per device, stride 12 words, up to 21:
--             SN  10 words, ASCII, high byte first
--             ID  U16  Modbus unit id of that inverter
--             reserved U16
--           The ID15 reserved row prints decimal 19234 next to hex 4AB4.
--           0x4AB4 is 19124. The stride above follows the hex and the other
--           twenty rows, not that one decimal.
--   0x848A  system realtime, see the block layout below
--   0x849E  grid phase R, then S, then T. 8 words each.
--   0x8500  energy counters, U32, magnification -2, unit kWh
--   0x8550  parallInvPower is length 2 and the next row says reserve at
--           0x8551. Those overlap. This driver stops at 0x854F.
--
-- There is no eManager serial in this sheet. Identity is the first connected
-- inverter SN, plus DeviceNum. A blank first SN falls through to the next.
--
-- ═══ Scaling (sheet "Magnification" column) ═══════════════════════════════
--
--   -1  × 0.1     grid voltage (V), grid current (A)
--   -2  × 0.01    frequency (Hz), SoC (%), energy (kWh)
--   -3  × 0.001   power factor (not emitted; no DER field)
--   blank on a watt register means the word is already watts
--
-- int32 / uint32 are two words. The sheet does not state the word order.
-- ASSUMPTION: high word first, same as the H2 driver in this repository and
-- the SAJ Modbus PDFs. UNVERIFIED on an eManager. A swapped pair of a
-- negative power would be a huge value, not a sign flip of the real watts.
--
-- ═══ Signs — UNVERIFIED on this map ═══════════════════════════════════════
--
-- The realtime sheet never says which direction is positive. Two neighbouring
-- sources disagree about how much to trust a SAJ power word:
--
--   H2 (drivers/lua/saj.lua, evcc saj-h2):
--     PV magnitude, battery discharge-positive, grid import-positive.
--   eManager setpoints 0x8402 / 0x8405 (this sheet, not a measurement):
--     positive discharges to the grid, negative charges / imports.
--   CH2 direct map (OpenEMS): the power word is NOT trusted. Direction
--     registers 0x7BEF / 0x7BF0 decide. This sheet has no such registers.
--
-- What this driver does, in one place each, until Castellum says otherwise:
--   pv.W       TotalPVPower is uint32. Treated as a magnitude and negated.
--   battery.W  assumed discharge-positive, negated to site charge-positive.
--   meter.W    assumed import-positive, matching H2 and the site rule, so
--              the value is not negated. Phase watts follow the same rule.
--   phase amps assumed the same way (positive into the site). Not negated.
--
-- Load (0x8493) and inverter (0x848D) power are int32 with no stated sign.
-- They are metrics under the vendor's own sign, not DER fields.
--
-- ═══ Voltage and frequency may be summed — the sheet does not say so ═════
--
-- Eniris, for this exact product, says the eManager returns phase voltage
-- and frequency as the SUM across connected inverters (4 inverters can read
-- 200 Hz) and that the controller divides by the inverter count. Power is
-- the combined total and must not be divided. Current is not mentioned.
--
-- The register sheet describes those cells as ordinary phase quantities
-- (magnification -1 V, -2 Hz). It does not mention a sum. Dividing every
-- site by DeviceNum would turn a true 230 V into 77 V on a 3-inverter plant.
--
-- So this driver divides voltage or frequency only when both are true:
--   the sheet's own scale is implausible for one phase, and
--   DeviceNum was read (2..21) and the quotient lands in a normal band
--   (about 180..280 V, 45..65 Hz).
-- A 230 V / 50 Hz reading is left alone, even when three inverters are
-- connected. A 690 V / 150 Hz reading with DeviceNum = 3 becomes 230 V /
-- 50 Hz. Power, current, energy and rated power are never divided.
-- Confirm at Castellum which of the two a 3x CHS2 plant actually returns.
--
-- ═══ Battery presence ═════════════════════════════════════════════════════
--
-- A hybrid plant and a PV-only plant (the home manual also lists R5/R6)
-- share this map. paralltotalcap / parallUsercap at 0, SoC at 0 and battery
-- power at 0 do not mean an empty pack: nothing on the map has said a pack
-- exists. Emitting SoC 0 in that case is an empty battery the planner can
-- charge. The battery DER is emitted only when capacity is non-zero, SoC is
-- in 0.01%..100.00%, or battery power is non-zero. A real 0% pack that still
-- reports capacity is emitted, SoC and all.
--
-- The capacity unit on the sheet is "K", not kWh and not Wh. The raw word
-- is a presence signal and a metric. It is not converted.
--
-- ═══ Energy direction ═════════════════════════════════════════════════════
--
-- PV generation, battery charge and battery discharge totals are named on
-- the sheet and are copied onto the DER. FeedIn (0x852E) and Sell (0x8536)
-- are not: SAJ uses both words for both directions in different PDFs. They
-- are metrics under the vendor names, not meter import/export.
--
-- ═══ Control 0x8400-0x8405 — NOT IMPLEMENTED ══════════════════════════════
--
-- EMS sheet (eManager), R/W:
--   0x8400 EMSEnable   U16
--            0 invalid / inverter's own mode
--            1 inverter-power dispatch, follows 0x8402
--            2 battery-power dispatch, follows 0x8405
--              (the sheet says SEC-C does not support 2)
--   0x8401 EMSKeepTime U16 seconds, default 10, range 0..60000.
--            Heartbeat. On timeout the machine outputs 0.
--   0x8402 EMSINVPRef  I16  magnification -4  unit %  range -11000..11000
--            Positive: discharge / export toward the target.
--            Negative: import and charge toward the target.
--   0x8403 EMSBATChargCurrentLimit    U16  magnification -1  A
--   0x8404 EMSBATDisChargCurrentLimit U16  magnification -1  A
--            Both marked "Temporarily Closed" on the sheet.
--   0x8405 EMSBATPRef  I16  same scaling and sign as 0x8402, battery target.
--
-- Scaling is unverified. Magnification -4 means ×10^-4, so raw 10000 = 1.00
-- and raw 11000 = 1.10. Read as a fraction of rated power, that is 100% and
-- 110%, i.e. 0.01 percentage points per step. The unit column says "%"
-- which would be the same limit if the step were 0.01% (magnification -2).
-- Both readings of the sheet put the documented stop at ±110% of rated.
-- OpenEMS CH2 states the same numbers from the unpublished CH2 EMS protocol
-- (10000 = 100%, ±110%, positive discharges) and was not run on hardware.
--
-- SEC-C anti-backflow reuses 0x8400-0x8404 with different meanings (0 off,
-- 1 phase power limit, 2 phase current limit, 3 total power limit; 0x8402
-- is then a ±110% grid limit at magnification -2). Writing the EMS encoding
-- to a SEC-C, or the reverse, would select the wrong mode. This driver
-- targets the eManager EMS sheet and writes neither block.
--
-- A future control path has to prove, on a named eManager and firmware:
-- held zero, charge, discharge, heartbeat refresh, and a release back to
-- EMSEnable 0. Until then driver_command refuses and driver_default_mode
-- does not write.

DRIVER = {
  id           = "saj-emanager",
  name         = "SAJ eManager C1 Pro",
  manufacturer = "SAJ",
  version      = "0.1.0",
  host_api_min = 1,
  host_api_max = 1,
  protocols    = { "modbus" },
  capabilities = { "pv", "battery", "meter" },
  read_only    = true,
  description  = "SAJ eManager C1 Pro site controller (Modbus TCP only, port 502; RTU is not supported) in front of CHS2/CH2 hybrids. Aggregate PV, battery and grid telemetry. Read-only. Not tested on hardware.",
  homepage     = "https://www.saj-electric.com",
  authors      = { "Sourceful Labs AB" },
  tested_models = { "eManager C1 Pro" },
  verification_status = "experimental",
  verification_notes = "Decoded from the community eManager/SEC-C register workbook on home-assistant-saj-h2-modbus discussion 182, cross-checked against Eniris and the OpenEMS CH2 module. Not tested on hardware. Control registers 0x8400-0x8405 are documented and not written. First site to check: Castellum Örebro.",
  connection_defaults = {
    port    = 502,
    unit_id = 1,
  },
}

PROTOCOL = "modbus"

----------------------------------------------------------------------------
-- Register map
----------------------------------------------------------------------------

local REG_DEVICE_NUM = 0x4A00
local REG_SLOT0      = 0x4A01
local SLOT_STRIDE    = 12
local SN_WORDS       = 10
local MAX_DEVICES    = 21
-- Stay under the usual 125-word Modbus ceiling. 10 slots = 120 words.
local SLOTS_PER_READ = 10

-- 0x848A .. 0x849D. One read, 20 words. Layout is 1-based in the block.
local REG_SUMMARY   = 0x848A
local SUMMARY_WORDS = 20
local IDX_MODE    = 1
local IDX_RATED   = 2  -- uint32
local IDX_INV     = 4  -- int32  TotalInvPowerWatt
local IDX_PV      = 6  -- uint32 TotalPVPower
local IDX_BAT     = 8  -- int32  TotalBatteryPower
local IDX_LOAD    = 10 -- int32
local IDX_SOC     = 12 -- uint16 × 0.01 %
local IDX_GRID    = 13 -- int32  TotalGridPowerWatt
local IDX_GEN     = 15 -- int32
local IDX_CAP     = 17 -- uint32 paralltotalcap, unit "K"
local IDX_USERCAP = 19 -- uint32 parallUsercap, unit "K"

-- 0x849E .. 0x84B5. R, S, T. 8 words: V, I, f, P, S, PF.
local REG_PHASES   = 0x849E
local PHASES_WORDS = 24
local PHASE_WORDS  = 8

-- 0x8500 .. 0x854F. Pairs of uint32 × 0.01 kWh. Pair 0 is 0x8500.
local REG_ENERGY    = 0x8500
local ENERGY_WORDS  = 80
local PAIR_TOTAL_PV      = 3  -- 0x8506
local PAIR_TOTAL_BAT_CHG = 7  -- 0x850E
local PAIR_TOTAL_BAT_DIS = 11 -- 0x8516
local PAIR_TOTAL_FEED_IN = 23 -- 0x852E
local PAIR_TOTAL_SELL    = 27 -- 0x8536

-- MPVMode 5 is "Fault" on the sheet.
local MODE_FAULT = 5

-- One-phase bands for the Eniris sum heuristic. See the header.
local VOLT_SUSPECT = 320
local VOLT_OK_LO   = 180
local VOLT_OK_HI   = 280
local HZ_SUSPECT   = 70
local HZ_OK_LO     = 45
local HZ_OK_HI     = 65

local PHASE_NAMES = { "L1", "L2", "L3" }

----------------------------------------------------------------------------
-- Decoding
----------------------------------------------------------------------------

local function finite(value)
    if value ~= value then return nil end
    if value == math.huge or value == -math.huge then return nil end
    return value
end

local function scaled(raw, factor)
    if raw == nil then return nil end
    return finite(raw * factor)
end

-- 0xFFFFFFFF is not a capacity or an energy total. Leave it out.
local function u32_at(regs, index)
    local hi, lo = regs[index], regs[index + 1]
    if hi == nil or lo == nil then return nil end
    if hi == 0xFFFF and lo == 0xFFFF then return nil end
    return host.decode_u32_be(hi, lo)
end

-- 0x7FFFFFFF and 0x80000000 are not a site power. The sheet does not name
-- them as sentinels; they are rejected because they are not a measurement.
local function i32_at(regs, index)
    local hi, lo = regs[index], regs[index + 1]
    if hi == nil or lo == nil then return nil end
    local raw = host.decode_i32_be(hi, lo)
    if raw == 2147483647 or raw == -2147483648 then return nil end
    return raw
end

-- 0.01 kWh → Wh. A decoded 0 stays 0: the device said zero.
local function u32_wh(regs, index)
    local raw = u32_at(regs, index)
    if raw == nil then return nil end
    return finite(raw * 10)
end

local function pair_wh(regs, pair)
    return u32_wh(regs, pair * 2 + 1)
end

-- SoC: uint16 × 0.01 percent → fraction 0..1. 0xFFFF and anything above
-- 100.00% are not a state of charge.
local function soc_fraction(raw)
    if raw == nil or raw == 0xFFFF or raw > 10000 then return nil end
    return raw / 10000
end

-- ASSUMPTION, unverified: grid import is already positive.
local function grid_watts(vendor)
    return vendor
end

-- ASSUMPTION, unverified: battery discharge is positive on the wire.
local function battery_watts(vendor)
    if vendor == nil then return nil end
    return -vendor
end

-- Divide only when the sheet scale is implausible AND DeviceNum explains it.
-- Returns the value to publish, and whether a divide was applied.
local function unsum_if_indicated(value, device_count, suspect_above, ok_lo, ok_hi)
    if value == nil then return nil, false end
    if value == 0 then return 0, false end
    if device_count ~= nil and device_count >= 2 and device_count <= MAX_DEVICES
        and value > suspect_above then
        local corrected = finite(value / device_count)
        if corrected ~= nil and corrected >= ok_lo and corrected <= ok_hi then
            return corrected, true
        end
    end
    return value, false
end

----------------------------------------------------------------------------
-- Reading registers that may not exist
--
-- The host counts every failed host.modbus_read against the poll whether or
-- not this driver caught the error. Three misses, then stop until restart.
-- A short reply is a miss: the missing words are nil, never a filled-in 0.
--
-- The summary block does not go through here. When it fails the driver
-- emits no DER at all, so a blip cannot silence the plant for the session
-- and a permanent failure does not claim the device is fine.
----------------------------------------------------------------------------

local GIVE_UP_AFTER = 3
local read_failures = {}
local announced = false

local function complete(regs, count)
    if regs == nil then return false end
    for i = 1, count do
        if regs[i] == nil then return false end
    end
    return true
end

local function probe_read(addr, count, kind)
    if (read_failures[addr] or 0) >= GIVE_UP_AFTER then return nil end
    local ok, regs = pcall(host.modbus_read, addr, count, kind)
    if ok and complete(regs, count) then
        read_failures[addr] = nil
        return regs
    end
    local failures = (read_failures[addr] or 0) + 1
    read_failures[addr] = failures
    if failures == GIVE_UP_AFTER then
        host.log("info", string.format(
            "SAJ eManager: register %d did not answer %d times; leaving it " ..
            "alone until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

local function required_read(addr, count, kind)
    local ok, regs = pcall(host.modbus_read, addr, count, kind)
    if ok and complete(regs, count) then return regs end
    return nil
end

----------------------------------------------------------------------------
-- Identity. DeviceNum decides how many slots exist; we do not scan 21.
----------------------------------------------------------------------------

local function read_device_count()
    local regs = probe_read(REG_DEVICE_NUM, 1, "holding")
    if not regs then return nil end
    local n = regs[1]
    if n == nil or n == 0xFFFF or n > MAX_DEVICES then return nil end
    return n
end

local function decode_slots(regs, n)
    local devices = {}
    for i = 0, n - 1 do
        local base = i * SLOT_STRIDE
        local sn = host.decode_string(regs, base + 1, SN_WORDS)
        if sn == "" then sn = nil end
        devices[#devices + 1] = {
            sn = sn,
            id = regs[base + SN_WORDS + 1],
        }
    end
    return devices
end

local function read_slots(count)
    if count == nil or count < 1 then return nil end
    local devices = {}
    local done = 0
    while done < count do
        local n = math.min(count - done, SLOTS_PER_READ)
        local addr = REG_SLOT0 + done * SLOT_STRIDE
        local regs = probe_read(addr, n * SLOT_STRIDE, "holding")
        if not regs then return nil end
        local part = decode_slots(regs, n)
        for _, device in ipairs(part) do
            devices[#devices + 1] = device
        end
        done = done + n
    end
    return devices
end

local function first_sn(devices)
    if not devices then return nil end
    for _, device in ipairs(devices) do
        if device.sn then return device.sn end
    end
    return nil
end

local function note_identity(device_count, devices)
    local sn = first_sn(devices)
    if sn then host.set_sn(sn) end
    if device_count ~= nil then
        host.emit_metric("saj_emanager_device_count", device_count)
    end
    if announced or device_count == nil then return end
    announced = true
    host.log("info", string.format(
        "SAJ eManager: DeviceNum=%d first SN=%s",
        device_count, sn or "(none)"))
end

----------------------------------------------------------------------------
-- Summary block → DER fields. Nil means the word did not decode.
----------------------------------------------------------------------------

local function battery_indicated(cap, user, soc_raw, bat_w)
    if cap ~= nil and cap > 0 then return true end
    if user ~= nil and user > 0 then return true end
    if soc_raw ~= nil and soc_raw > 0 and soc_raw <= 10000 then return true end
    if bat_w ~= nil and bat_w ~= 0 then return true end
    return false
end

local function decode_summary(regs)
    local mode = regs[IDX_MODE]
    if mode ~= nil and mode ~= 0xFFFF then
        host.emit_metric("saj_emanager_mpv_mode", mode)
        if mode == MODE_FAULT then
            host.set_device_fault(true, "MPVMode 5 fault")
        else
            host.set_device_fault(false, "")
        end
    end

    local rated = u32_at(regs, IDX_RATED)
    if rated ~= nil and rated > 0 then host.set_rated_w(rated) end

    local pv_w = u32_at(regs, IDX_PV)
    local bat_w = i32_at(regs, IDX_BAT)
    local grid_w = i32_at(regs, IDX_GRID)
    local cap = u32_at(regs, IDX_CAP)
    local user = u32_at(regs, IDX_USERCAP)
    local soc_raw = regs[IDX_SOC]

    local inv_w = i32_at(regs, IDX_INV)
    if inv_w ~= nil then host.emit_metric("saj_emanager_inv_w", inv_w) end
    local load_w = i32_at(regs, IDX_LOAD)
    if load_w ~= nil then host.emit_metric("saj_emanager_load_w", load_w) end
    local gen_w = i32_at(regs, IDX_GEN)
    if gen_w ~= nil and gen_w ~= 0 then
        host.emit_metric("saj_emanager_gen_w", gen_w)
    end

    local pv = {}
    if pv_w ~= nil then pv.W = -pv_w end

    local meter = {}
    if grid_w ~= nil then meter.W = grid_watts(grid_w) end

    local battery = nil
    if battery_indicated(cap, user, soc_raw, bat_w) then
        battery = {}
        local site_bat = battery_watts(bat_w)
        if site_bat ~= nil then battery.W = site_bat end
        local soc = soc_fraction(soc_raw)
        if soc ~= nil then battery.SoC_nom_fract = soc end
        if cap ~= nil then
            host.emit_metric("saj_emanager_battery_capacity_raw", cap)
        end
        if user ~= nil then
            host.emit_metric("saj_emanager_battery_available_raw", user)
        end
    end

    return pv, meter, battery
end

local function apply_phases(meter, regs, device_count)
    local divided = false
    local hz
    for i, name in ipairs(PHASE_NAMES) do
        local b = (i - 1) * PHASE_WORDS
        local volts = scaled(regs[b + 1], 0.1)
        local amps = nil
        if regs[b + 2] ~= nil then
            amps = scaled(host.decode_i16(regs[b + 2]), 0.1)
        end
        local freq = scaled(regs[b + 3], 0.01)
        local watts = i32_at(regs, b + 4)
        local v_out, v_div = unsum_if_indicated(
            volts, device_count, VOLT_SUSPECT, VOLT_OK_LO, VOLT_OK_HI)
        local f_out, f_div = unsum_if_indicated(
            freq, device_count, HZ_SUSPECT, HZ_OK_LO, HZ_OK_HI)
        if v_div or f_div then divided = true end
        if v_out ~= nil then meter[name .. "_V"] = v_out end
        if amps ~= nil then meter[name .. "_A"] = amps end
        local site_w = grid_watts(watts)
        if site_w ~= nil then meter[name .. "_W"] = site_w end
        if i == 1 then hz = f_out end
    end
    if hz ~= nil then meter.Hz = hz end
    return divided
end

local function apply_energy(pv, battery, regs)
    local pv_wh = pair_wh(regs, PAIR_TOTAL_PV)
    if pv_wh ~= nil then pv.lifetime_wh = pv_wh end
    if battery then
        local chg = pair_wh(regs, PAIR_TOTAL_BAT_CHG)
        local dis = pair_wh(regs, PAIR_TOTAL_BAT_DIS)
        if chg ~= nil then battery.total_charge_Wh = chg end
        if dis ~= nil then battery.total_discharge_Wh = dis end
    end
    -- Vendor names, deliberately not import_wh / export_wh.
    local feed = pair_wh(regs, PAIR_TOTAL_FEED_IN)
    local sell = pair_wh(regs, PAIR_TOTAL_SELL)
    if feed ~= nil then host.emit_metric("saj_emanager_vendor_feed_in_wh", feed) end
    if sell ~= nil then host.emit_metric("saj_emanager_vendor_sell_wh", sell) end
end

local function emit_der(kind, fields)
    if next(fields) ~= nil then host.emit(kind, fields) end
end

----------------------------------------------------------------------------
-- Entry points
----------------------------------------------------------------------------

function driver_init(config)
    host.set_make("SAJ")
    host.set_model("eManager C1 Pro")
end

function driver_poll()
    local device_count = read_device_count()
    local devices = read_slots(device_count)
    note_identity(device_count, devices)

    local summary = required_read(REG_SUMMARY, SUMMARY_WORDS, "holding")
    if not summary then return 5000 end

    local pv, meter, battery = decode_summary(summary)

    local phases = probe_read(REG_PHASES, PHASES_WORDS, "holding")
    local divided = false
    if phases then
        divided = apply_phases(meter, phases, device_count)
    end
    if divided and device_count ~= nil then
        host.emit_metric("saj_emanager_phase_scale_divisor", device_count)
    elseif phases and device_count ~= nil and device_count >= 1 then
        host.emit_metric("saj_emanager_phase_scale_divisor", 1)
    end

    local energy = probe_read(REG_ENERGY, ENERGY_WORDS, "holding")
    if energy then
        apply_energy(pv, battery, energy)
    end

    emit_der("pv", pv)
    emit_der("meter", meter)
    if battery then emit_der("battery", battery) end

    return 5000
end

function driver_command(action, power_w, cmd)
    if action == "init" or action == "deinit" then
        return true
    end
    host.log("warn", "SAJ eManager: control is not enabled (action=" ..
        tostring(action) .. ")")
    return false
end

function driver_default_mode()
    -- Read-only: nothing was taken, so there is nothing to release.
    -- 0x8400 is not written back to 0 from here.
end

function driver_cleanup()
    announced = false
    read_failures = {}
end
