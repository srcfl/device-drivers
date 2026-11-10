-- LK Systems LK Arc underfloor heating gateway — Modbus TCP, read-only.
--
-- Emits: metrics only, via host.emit_metric. The gateway switches valve
-- actuators; it measures no power, so there is no power stream and no sign
-- conversion.
-- Control: none. New drivers start read-only. The holding registers LK
-- documents for control are listed at the end of this file.
--
-- SOURCE
--   LK Systems "LK Arc Modbus Registers" (SENOFIEN.33.J.4, 2026-10-09), the
--   manifest's upstream_docs. The list numbers registers from 1 in the
--   classic 3:xxxxx (input) and 4:xxxxx (holding) notation, so the address
--   on the wire is the listed number minus one: "3:00101 Zone 1 actual
--   temperature" is input register 100. That offset was confirmed on a
--   gateway: input 100 held the zone 1 room temperature, 101 its humidity.
--
--   Each zone n (1..12) is a block at 100*n:
--     input   +0  actual temperature    int16, 0.1 °C
--             +1  actual humidity       uint16, 0.1 %
--             +2  battery               uint16, %
--             +3  signal strength       int16, dBm
--             +4..+6  thermostat address (SN/MAC), 6 octets
--             +7  connected actuators   bitfield, bit 0 = actuator 1
--     holding +0  target temperature    int16, 0.1 °C
--             +1  override              0 inactive, 1 active
--             +2  override level        0..255 = 0..100 % actuator opening
--   Gateway-wide: input 60..71 actuator 1..12 status (0 closed, 1 open,
--   2 unallocated); holding 0 operating mode (1 heating, 2 cooling).
--
-- WHAT THE GATEWAY DOES THAT THE LIST DOES NOT SAY
--   Measured on one LK Arc gateway, software 0.53.0, on 2026-11-10:
--   - A zone with no thermostat paired answers all zeros, not an error, so a
--     zone is taken to exist only when its thermostat address is non-zero.
--   - "Gateway number of zones" (3:00051) read 0 on a gateway with three
--     paired zones. It is not used.
--   - The gateway answers any unit id.
--   - It is slow, at least over Wi-Fi: ping answered in 0.6-1.8 s and a
--     single read took up to about 3 s, sometimes past the host's 5 s
--     request timeout. The host withholds a whole poll's telemetry when any
--     read in it fails to reach the device, so the driver keeps the number
--     of requests per poll small:
--       * Two neighbouring zones are one request. Zone n+1's block starts
--         100 registers after zone n's, so 108 input registers from zone
--         n's base cover both, within Modbus' 125. The gateway answers
--         zeros, not an exception, for the undocumented addresses between
--         (checked across 0-5000).
--       * Setpoints, overrides and the operating mode change by hand, not
--         by the minute, and are read every SETTINGS_EVERY polls.
--       * Zones are found once and re-checked every ZONE_RESCAN_POLLS polls.
--     With three zones a poll is three requests (actuators, zones 1-2,
--     zone 3), and six on a settings poll.
--   - It accepts one TCP connection at a time. Another Modbus client on
--     the same gateway makes FTW's reads time out.
--
-- PRIVACY
--   The thermostat addresses are hardware identifiers. They are read only to
--   tell a paired zone from an empty one and are never emitted or logged.
--   The gateway serial becomes the device serial via host.set_sn, as with
--   every other driver.
--
-- Config example (config.yaml):
--   drivers:
--     - name: lk
--       lua: drivers/lk_arc.lua
--       capabilities:
--         modbus:
--           host: <gateway-ip>
--           port: 502
--           unit_id: 1

PROTOCOL = "modbus"

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "lk_arc",
  name         = "LK Systems LK Arc",
  manufacturer = "LK Systems",
  version      = "0.1.0",
  protocols    = { "modbus" },
  capabilities = { "heatpump" },
  read_only    = true,
  description  = "LK Systems LK Arc underfloor heating gateway via Modbus TCP. Read-only: per-zone room temperature, humidity, setpoint, thermostat battery and signal, and actuator state.",
  homepage     = "https://www.lksystems.se",
  authors      = { "hannesb90", "Claude (Anthropic)" },
  tested_models = { "LK Arc gateway (software 0.53.0)" },
  verification_status = "experimental",
  verification_notes  = "Register reads checked against one LK Arc gateway (software 0.53.0) with three zones over Modbus TCP on 2026-11-10.",
  connection_defaults = {
    port    = 502,
    unit_id = 1,
  },
}

local MAX_ZONES     = 12
local ZONE_STRIDE   = 100
local ZONE_IN_COUNT = 8   -- input +0..+7
local ZONE_HR_COUNT = 3   -- holding +0..+2

local REG_IDENTITY      = 0   -- input 0..3 serial (64-bit), 4..6 version
local IDENTITY_COUNT    = 7
local REG_ACTUATORS     = 60  -- input 60..71
local ACTUATOR_COUNT    = 12
local REG_MODE          = 0   -- holding 0

local ACTUATOR_CLOSED = 0
local ACTUATOR_OPEN   = 1

-- Set with host.set_poll_interval: an interval returned from driver_poll is
-- capped at 30 s by the host, and this gateway is better asked less often.
local POLL_MS           = 60000
local ZONE_RESCAN_POLLS = 30  -- about every half hour
local WATCHDOG_S        = 180
local SETTINGS_EVERY    = 5   -- polls, so about every five minutes
local RESCAN_AFTER_GAP  = 5   -- polls until an incomplete scan is repeated

-------------------------------------------------------------------------------
-- Bounded reads. A failed read is nil and nothing is emitted from it. A
-- register that fails three polls in a row is left alone until the next
-- zone scan, about half an hour later: the host counts every failed read
-- against the poll, so paying for a register the gateway lacks every minute
-- would take the whole driver offline for one missing field. The scan gives
-- every register another chance, so a gateway that was briefly unreachable
-- comes back whole.
-------------------------------------------------------------------------------

local GIVE_UP_AFTER = 3
local read_failures = {}

local function read(addr, count, kind)
    local key = kind .. addr
    if (read_failures[key] or 0) >= GIVE_UP_AFTER then return nil end
    local ok, regs = pcall(host.modbus_read, addr, count, kind)
    if ok and type(regs) == "table" then
        for i = 1, count do
            if regs[i] == nil then ok = false break end
        end
    else
        ok = false
    end
    if ok then
        read_failures[key] = nil
        return regs
    end
    local failures = (read_failures[key] or 0) + 1
    read_failures[key] = failures
    if failures == GIVE_UP_AFTER then
        host.log("info", string.format(
            "LK: %s register %d did not answer %d times; leaving it alone",
            kind, addr, GIVE_UP_AFTER))
    end
    return nil
end

local function forget_failures()
    read_failures = {}
end

local function s16(raw)
    if raw == nil then return nil end
    return host.decode_i16(raw)
end

local function emit(name, value, unit)
    if value ~= nil then host.emit_metric(name, value, unit) end
end

-------------------------------------------------------------------------------
-- Zones
-------------------------------------------------------------------------------

local zones = nil        -- sorted list of zone numbers with a thermostat
local polls_since_scan = 0

local function has_thermostat(regs)
    return regs[5] ~= 0 or regs[6] ~= 0 or regs[7] ~= 0
end

local function emit_zone(n, input, holding, actuators)
    local p = "zone_" .. n .. "_"
    -- The documented range is -100.0..100.0 °C; outside it is not a reading.
    local t = s16(input[1])
    if t ~= nil and t >= -1000 and t <= 1000 then emit(p .. "temp_c", t / 10, "°C") end
    local rh = input[2]
    if rh ~= nil and rh <= 1000 then emit(p .. "humidity_pct", rh / 10, "%") end
    local batt = input[3]
    if batt ~= nil and batt <= 100 then emit(p .. "battery_pct", batt, "%") end
    emit(p .. "signal_dbm", s16(input[4]), "dBm")

    local mask = input[8]
    if mask ~= nil and actuators then
        local connected, open = 0, 0
        for a = 1, ACTUATOR_COUNT do
            if math.floor(mask / 2 ^ (a - 1)) % 2 == 1 then
                connected = connected + 1
                if actuators[a] == ACTUATOR_OPEN then open = open + 1 end
            end
        end
        emit(p .. "actuators_connected", connected, "")
        if connected > 0 then
            emit(p .. "heating", open > 0 and 1 or 0, "")
            emit(p .. "actuators_open_pct", 100 * open / connected, "%")
        end
    end

    if holding then
        local sp = s16(holding[1])
        if sp ~= nil and sp >= -1000 and sp <= 1000 then
            emit(p .. "setpoint_c", sp / 10, "°C")
        end
        emit(p .. "override", holding[2] == 1 and 1 or 0, "")
        local level = holding[3]
        if level ~= nil and level <= 255 then
            emit(p .. "override_level_pct", math.floor(level * 1000 / 255 + 0.5) / 10, "%")
        end
    end
end

-------------------------------------------------------------------------------
-- Identity, read once.
-------------------------------------------------------------------------------

local identity_done = false
local identity_tries = 0
local IDENTITY_ATTEMPTS = 3

local function read_identity()
    if identity_done or identity_tries >= IDENTITY_ATTEMPTS then return end
    identity_tries = identity_tries + 1
    local id = read(REG_IDENTITY, IDENTITY_COUNT, "input")
    if not id then return end
    host.set_sn(string.format("%04X%04X%04X%04X", id[1], id[2], id[3], id[4]))
    local v = string.format("%d.%d.%d", id[5], id[6], id[7])
    host.set_model("LK Arc (software " .. v .. ")")
    host.log("info", "LK: gateway software " .. v)
    identity_done = true
end

-------------------------------------------------------------------------------
-- Entry points
-------------------------------------------------------------------------------

function driver_init(config)
    host.set_make("LK Systems")
    -- One poll can take half a minute on this gateway (a read takes up to
    -- about three seconds), more than the site-wide 60 s staleness window
    -- leaves room for on top of a one-minute cadence.
    if host.set_watchdog_timeout_s then host.set_watchdog_timeout_s(WATCHDOG_S) end
    host.set_poll_interval(POLL_MS)
end

-- Read the per-zone block of `count` registers for each zone in `wanted`
-- (a sorted list). Two neighbouring wanted zones share one request.
-- Returns zone number -> its `count` registers; a zone whose request failed
-- is missing.
local function read_zones(kind, wanted, count)
    local want = {}
    for _, n in ipairs(wanted) do want[n] = true end
    local out, done = {}, {}
    for _, n in ipairs(wanted) do
        if not done[n] then
            local first = (n % 2 == 1) and n or n - 1
            local pair = want[first] and want[first + 1]
            local base = pair and first or n
            local regs = read(base * ZONE_STRIDE,
                pair and (ZONE_STRIDE + count) or count, kind)
            local members = pair and { first, first + 1 } or { n }
            for i, m in ipairs(members) do
                done[m] = true
                if regs then
                    local off = (i - 1) * ZONE_STRIDE
                    local block = {}
                    for k = 1, count do block[k] = regs[off + k] end
                    out[m] = block
                end
            end
        end
    end
    return out
end

local ALL_ZONES = {}
for n = 1, MAX_ZONES do ALL_ZONES[n] = n end

local poll_count = 0

function driver_poll()
    local scanning = zones == nil or polls_since_scan >= ZONE_RESCAN_POLLS
    if scanning then
        -- A scan gives every register, and the identity, another chance.
        forget_failures()
        if not identity_done then identity_tries = 0 end
    end
    local settings_poll = scanning or poll_count % SETTINGS_EVERY == 0
    poll_count = poll_count + 1

    local actuators = read(REG_ACTUATORS, ACTUATOR_COUNT, "input")
    if actuators then
        for a = 1, ACTUATOR_COUNT do
            -- Unallocated (2) or anything undocumented is left out.
            local st = actuators[a]
            if st == ACTUATOR_CLOSED or st == ACTUATOR_OPEN then
                emit("actuator_" .. a .. "_open", st, "")
            end
        end
    end
    local any = actuators ~= nil

    -- A scan asks every zone; the answer for a paired one is also its
    -- reading for this poll, so nothing is read twice.
    local inputs = read_zones("input", scanning and ALL_ZONES or zones, ZONE_IN_COUNT)
    if scanning and next(inputs) ~= nil then
        -- A zone whose request failed keeps what the last scan said about
        -- it, and an incomplete scan is repeated after RESCAN_AFTER_GAP
        -- polls rather than half an hour later.
        local known, found, complete = {}, {}, true
        for _, n in ipairs(zones or {}) do known[n] = true end
        for n = 1, MAX_ZONES do
            if inputs[n] then
                if has_thermostat(inputs[n]) then found[#found + 1] = n end
            else
                complete = false
                if known[n] then found[#found + 1] = n end
            end
        end
        zones = found
        polls_since_scan = complete and 0 or (ZONE_RESCAN_POLLS - RESCAN_AFTER_GAP)
        host.log("info", string.format("LK: %d zone(s) with a thermostat%s",
            #found, complete and "" or " (scan incomplete)"))
    end
    polls_since_scan = polls_since_scan + 1

    local present = {}
    for _, n in ipairs(zones or {}) do
        if inputs[n] then present[#present + 1] = n; any = true end
    end

    local holdings = {}
    if settings_poll and #present > 0 then
        holdings = read_zones("holding", present, ZONE_HR_COUNT)
        local mode = read(REG_MODE, 1, "holding")
        if mode then emit("lk_operating_mode", mode[1], "") end
    end

    for _, n in ipairs(present) do
        emit_zone(n, inputs[n], holdings[n], actuators)
    end

    read_identity()

    host.emit_metric("lk_poll_ok", any and 1 or 0, "")
    return POLL_MS
end

function driver_cleanup()
end

-- Not used by this read-only driver. Kept as the map for the control step.
--
-- Per zone n, holding registers at 100*n (wire address, listed number - 1):
--   +0  target temperature, int16 0.1 °C
--   +1  override, 0 inactive / 1 active
--   +2  override level, 0..255 = 0..100 % actuator opening while override
-- The list says nothing about the gateway taking control back by itself,
-- so a control step needs its own bounded lease and a default that clears
-- the override. Nothing has been written to a gateway yet.
