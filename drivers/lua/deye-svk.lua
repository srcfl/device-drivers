-- Deye Hybrid Inverter — FAST FFR poll variant (SvK suite)
-- Version: 0.1.0
--
-- This is a LEAN sibling of deye.lua (registry deye@2.4.4). The control
-- path (V105.3 Remote Mode: regs 108/109/128/130/141/142/145/146 +
-- 1100/1101/1104/1105/1109, the reg-1109 setpoint, the wiggle-to-zero
-- latch unstick, the pct_from_watts |W| clamp, the latch self-heal, and
-- the deinit/default_mode safe-revert) is VERBATIM from that driver —
-- proven on the real Sveavägen 19 Deye HV (admin/nybro). The ONLY change
-- is driver_poll: it has been stripped to the minimum needed to score
-- FFR / FCR-D/N truthfully.
--
-- ── WHY THIS DRIVER EXISTS ───────────────────────────────────────────
-- deye.lua does two large FC03 bundle reads (109 + 82 = 191 regs) per
-- poll → ~70 ms/cycle on the fancy-wood HV, but it also recombines PV,
-- inverter-AC, meter, cell V/T and energy counters — all the schema-rich
-- telemetry. That's fine for FCR-D/N (7.5 s budget) but the battery-power
-- readback is buried in a wide bundle, so the cycle is dominated by the
-- full read + decode. For FFR's sub-second activation we want the
-- battery axis to refresh as fast as possible. This driver reads ONLY the
-- two registers the SvK suite + dashboard need:
--
--   590  Battery output power, S16 (HV ×10 W / LV ×1 W). Deye raw sign is
--        +ve = discharge to inverter → NEGATE for Sourceful (+charge /
--        -discharge). THE critical fast signal.
--   588  Battery SoC, U16 % [0,100] → fraction 0..1.
--
-- Both addresses are read by deye.lua already (inside its 516..624 meta
-- bundle). Here they are read as ONE small FC03 of 3 regs (587..589 →
-- covers 588 SoC + 590 power with one hole), so the whole poll is a
-- single short Modbus transaction → well under 100 ms at 9600 baud, vs
-- ~70 ms+ for the full two-bundle driver but with far less decode and a
-- much tighter bus window for FFR readback freshness. PV/MPPT, inverter-
-- AC, meter, cell V/T and energy counters are all DROPPED — not needed
-- for FFR/FCR scoring.
--
-- driver_init keeps full identification (make/Deye, sn via reg 3, rated_w
-- via reg 20-21, HV/LV detect via reg 0) — those run ONCE at init, so
-- they don't affect cadence.
--
-- ── ADDRESSING / FUNCTION CODES (unchanged from base) ────────────────
--   ALL registers HOLDING. FC03 (read) / FC16+FC06 (write).
--   Multi-register U32 values: Little-Endian word order.
--   LV and HV models supported (detected via reg 0).
--
-- ── POLARITY: SOURCEFUL CONVENTION ──────────────────────────────────
--   -W = OUT of the asset (discharge), +W = INTO the asset (charge).
--   On both emit AND on driver_command("battery", W). Deye's native
--   register conventions differ per register and are translated at the
--   boundary here (reg 590 negated on emit; reg 1109 negated on command).
--
-- ── CONTROL PATH (VERBATIM from deye@2.4.4) ──────────────────────────
--   See initialize_remote_mode(), pct_from_watts(), driver_command() and
--   deinit_to_self_consumption() below — byte-for-byte from deye.lua,
--   including every register, value, comment-relevant ordering, the
--   50 ms inter-write gap, the wiggle-to-zero, and the TOU-slot wipe on
--   deinit. DO NOT change — proven on the live Deye HV.

PROTOCOL = "modbus"

DRIVER = {
    host_api_min = 1,
    host_api_max = 1,
    id = "deye-svk",
    name = "Deye SUN hybrid — lean SvK fast-poll variant",
    manufacturer = "Deye",
    version = "0.2.1",
    protocols = { "modbus" },
    capabilities = { "battery" },
    read_only = false,
    description = "Deye three-phase hybrid via Modbus RTU; lean single-read poll for SvK FFR/FCR with the deye@2.4.4 Remote Mode control path verbatim.",
    authors = { "David and Blixt L1 contributors", "Sourceful contributors" },
    tested_models = { "SUN-12K-SG04LP3", "SUN-50K-SG01HP3" },
    verification_status = "experimental",
    verification_notes = "Migrated from the Blixt L1 driver source; source has run on hardware under Blixt L1 but no HIL record exists in this repository yet.",
    connection_defaults = {
        unit_id = 1, baud_rate = 9600,
    },
}

DRIVER_MANIFEST = {
    name    = "deye-svk",
    version = "0.2.1",
    role    = "battery",   -- hybrid inverter is treated as a battery asset

    -- Same requires/options as deye@2.4.4 so an existing Deye device
    -- entry (e.g. Sveavägen 19) can be repinned to this driver WITHOUT
    -- re-entering config.
    requires = {
        { name    = "battery_capacity_wh",
          purpose = "control",
          type    = "integer", min = 1000, max = 1000000,
          help    = "Total usable LFP capacity wired to this Deye (Wh). " ..
                    "The Deye doesn't know how much battery is on its DC bus, " ..
                    "so this must be configured per install." },
        { name    = "battery_rated_w",
          purpose = "control",
          type    = "integer", min = 1000, max = 200000,
          help    = "Battery max continuous charge / discharge power (W, " ..
                    "magnitude). Cap on |setpoint| regardless of inverter " ..
                    "rated_w. Use the manufacturer's continuous rating; " ..
                    "the inverter is hardware-limited but the battery may " ..
                    "be the actual bottleneck (e.g. a 30 kWh / 15 kW pack " ..
                    "behind a 30 kW inverter). The driver will silently " ..
                    "clamp setpoints over this magnitude before writing " ..
                    "reg 1109." },
        { name    = "battery_soc_min_pct",
          purpose = "control",
          type    = "integer", min = 0, max = 100,
          help    = "Floor for discharge — arbitrator vetoes setpoints that " ..
                    "would drive SoC below this percentage." },
        { name    = "battery_soc_max_pct",
          purpose = "control",
          type    = "integer", min = 0, max = 100,
          help    = "Ceiling for charge — arbitrator vetoes setpoints that " ..
                    "would drive SoC above this percentage." },
    },

    options = {
        { name    = "battery_max_c_rate",
          purpose = "control",
          type    = "double",  default = 1.0, min = 0.1, max = 5.0,
          help    = "Battery max C-rate. 1.0 means rated power == capacity " ..
                    "per hour. Most LFP packs paired with hybrid inverters " ..
                    "can sustain 1.0 C at moderate temperatures." },
        { name    = "pv_shares_ac_stage",
          purpose = "control",
          type    = "boolean", default = true,
          help    = "Hybrid topology: PV + battery contend for the AC " ..
                    "inverter stage. Carried for config-compatibility with " ..
                    "deye; this fast driver does not emit PV." },
    },

    provides = {
        live   = { "battery.W", "battery.SoC_nom_fract" },
        static = { "rated_W", "make", "model", "sn" },
    },
}

PROTOCOL = "modbus"

local is_hv = false
local rated_w = 0                  -- watts, read once from reg 20-21
local control_initialized = false

-- The two hosts report a failed write differently (spec/host-api.md):
-- Blixt L1 returns true or raises; FTW returns an error string and never
-- raises. Check both, so a refusal is seen on either host — and in the
-- test harness, which follows the FTW convention.
local function host_write_ok(fn, ...)
    local ok, res = pcall(fn, ...)
    if not ok then return false end
    if res ~= nil and res ~= true then return false end
    return true
end

-- Bounded unprompted safe-revert — see driver_default_mode.
local DEFAULT_MODE_REFUSALS_BEFORE_STOP = 3
local default_mode_refusals = 0

-- Poll reads with bounded retry. The host counts every failed read
-- against the poll and takes a driver that fails forever offline, so a
-- block the inverter never answers must not be re-read every poll for
-- the life of the session. After BUNDLE_MISSES_BEFORE_SKIP misses in a
-- row a block is left alone — but only for BUNDLE_RETRY_EVERY polls:
-- these blocks are what the control path measures against, and a bus
-- hiccup must not blind the driver for the rest of the session. A
-- skipped block comes straight back the moment it answers.
local BUNDLE_MISSES_BEFORE_SKIP = 3
local BUNDLE_RETRY_EVERY        = 12   -- ≈ 1 min at the 5 s poll
local bundle_misses = {}
local bundle_skips  = {}

local function bundle_read(addr, count, kind, label)
    local misses = bundle_misses[addr] or 0
    if misses >= BUNDLE_MISSES_BEFORE_SKIP then
        local skipped = (bundle_skips[addr] or 0) + 1
        if skipped < BUNDLE_RETRY_EVERY then
            bundle_skips[addr] = skipped
            return false, nil
        end
        bundle_skips[addr] = 0
    end
    local ok, regs = pcall(host.modbus_read, addr, count, kind)
    if ok and regs ~= nil then
        for i = 1, count do
            if regs[i] == nil then ok = false break end
        end
    end
    if ok and regs ~= nil then
        if misses >= BUNDLE_MISSES_BEFORE_SKIP then
            host.log("poll: " .. label .. " block " .. addr .. " is answering again")
        end
        bundle_misses[addr] = 0
        return true, regs
    end
    misses = misses + 1
    bundle_misses[addr] = misses
    if misses == BUNDLE_MISSES_BEFORE_SKIP then
        host.log("poll: " .. label .. " block " .. addr .. " failed " .. misses
            .. " reads in a row; probing every " .. BUNDLE_RETRY_EVERY .. " polls")
    end
    return false, nil
end
local battery_rated_w = 0

local battery_capacity_wh = 0
local soc_min_pct = 0
local soc_max_pct = 100

-- ── Latch self-heal state (VERBATIM from deye@2.4.4) ─────────────────
local last_commanded_pct = 0
local self_heal_disagree_polls = 0
local SELF_HEAL_FLOOR_W       = 500
local SELF_HEAL_RUN_REQUIRED  = 2

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------

-- U16 → signed 16-bit interpretation.
local function i16(u)
    if u >= 0x8000 then return u - 0x10000 end
    return u
end

-- Perform a sequence of single-reg FC16 writes with a short inter-
-- write gap so the inverter's internal EEPROM commit doesn't drop
-- later writes. 50 ms matches deye.lua and the live HV unit.
local function write_seq(label, writes)
    host.log("[" .. label .. "] writing " .. #writes .. " registers")
    for _, w in ipairs(writes) do
        local addr = w[1]
        local val = w[2]
        local u = val
        if u < 0 then u = u + 0x10000 end
        u = u % 0x10000
        local ok = host_write_ok(host.write, addr, u)
        if not ok then
            host.log("[" .. label .. "] FAIL reg " .. addr .. " = " .. val)
            return false
        end
        host.log("[" .. label .. "] reg " .. addr .. " = " .. val)
        host.sleep(50)
    end
    host.log("[" .. label .. "] OK")
    return true
end

-- Device-type detection (reg 0). 0x0600 / 0x06xx = HV three-phase
-- storage per V105.3 page 5.
local function detect_hv()
    local ok, regs = pcall(host.modbus_read, 0, 1, "holding")
    if ok then
        local v = regs[1]
        is_hv = (v == 6) or (math.floor(v / 256) == 6)
    end
end

-- Rated inverter power from regs 20-21 (U32 LE × 0.1 W → W).
local function read_rated_w()
    local ok, regs = pcall(host.modbus_read, 20, 2, "holding")
    if not ok then return 0 end
    return host.decode_u32_le(regs[1], regs[2]) * 0.1
end

-- ---------------------------------------------------------------------
-- driver_init — READ-ONLY identification + capture config.
-- ---------------------------------------------------------------------

function driver_init(config)
    host.set_make("Deye")

    config = config or {}
    if type(config.battery_rated_w) == "number" and config.battery_rated_w > 0 then
        battery_rated_w = math.floor(config.battery_rated_w)
        host.log("config: battery_rated_w = " .. battery_rated_w .. " W")
    end
    if type(config.battery_capacity_wh) == "number" and config.battery_capacity_wh > 0 then
        battery_capacity_wh = math.floor(config.battery_capacity_wh)
        host.log("config: battery_capacity_wh = " .. battery_capacity_wh .. " Wh")
    end
    if type(config.battery_soc_min_pct) == "number" then
        soc_min_pct = math.floor(config.battery_soc_min_pct)
    end
    if type(config.battery_soc_max_pct) == "number" then
        soc_max_pct = math.floor(config.battery_soc_max_pct)
    end
    if battery_capacity_wh > 0 then
        host.log("config: SoC band = " .. soc_min_pct .. "%-" .. soc_max_pct .. "%")
    end

    -- Serial number from reg 3, 8 regs ASCII. Retry 3× because the
    -- serial link may need to stabilise after inverter boot.
    local sn = nil
    for attempt = 1, 3 do
        local ok_sn, sn_regs = pcall(host.modbus_read, 3, 8, "holding")
        if ok_sn then
            sn = host.decode_string(sn_regs, 1, 8)
            if sn and #sn > 0 then break end
        end
        host.log("SN read attempt " .. attempt .. " failed, retrying...")
        host.sleep(500)
        sn = nil
    end
    if not sn or #sn == 0 then
        host.log("INIT FAIL: cannot read serial number after 3 attempts")
        return false
    end
    host.set_sn(sn)
    host.log("SN: " .. sn)

    detect_hv()
    rated_w = read_rated_w()
    host.set_rated_w(math.floor(rated_w))
    host.set_model(is_hv and "Deye-HV" or "Deye-LV")
    host.log("rated=" .. rated_w .. "W  hv=" .. tostring(is_hv))
end

-- ---------------------------------------------------------------------
-- Control init — put the inverter into Remote Mode. VERBATIM (deye@2.4.4)
-- ---------------------------------------------------------------------
--
-- Registers (per V105.3):
--   108  Max battery charge current (A)
--   109  Max battery discharge current (A)
--   128  Grid charge current to battery (A)
--   130  Utility Charge Enable (0 = disabled — stops autonomous grid-charge)
--   141  Energy management. 1 = PV → load → battery (no TOU race)
--   142  Limit control. 0 = sell electricity enabled
--   145  Solar sell on
--   146  TOU control bits. 0 = TOU selling disabled (Remote Mode owns sp)
--   1100 Remote mode enable
--   1101 Remote mode watchdog (s). 3600 = 1 h
--   1104 Inverter output power control mode (1 = battery side)
--   1105 Battery side control (2 = power mode)
--   1109 Remote setpoint (0.1 % of rated, [-1200, +1200])

local function initialize_remote_mode()
    if rated_w == 0 then rated_w = read_rated_w() end
    if rated_w <= 0 then
        host.log("INIT FAIL: rated power unknown (reg 20-21)")
        return false
    end

    local ok = write_seq("init", {
        {108,  100},   -- Max battery charge current (A)
        {109,  100},   -- Max battery discharge current (A)
        {128,  100},   -- Grid charge current to battery (A)
        {130,  0},     -- Utility Charge Enable off
        {141,  1},     -- Energy mgmt: PV → load → battery
        {142,  0},     -- Limit control: sell enabled
        {145,  1},     -- Solar sell on
        {146,  0},     -- TOU selling disabled — Remote Mode owns setpoint
        {1100, 1},     -- Remote mode enable
        {1101, 3600},  -- Remote mode watchdog, 1 h
        {1104, 1},     -- Battery-side control mode
        {1105, 2},     -- Power mode
        {1109, 0},     -- Start with zero power
    })
    control_initialized = ok
    if ok then
        last_commanded_pct = 0
        self_heal_disagree_polls = 0
        host.log("Sleeping 1000ms for Remote Mode to settle")
        host.sleep(1000)
    end
    return ok
end

-- ---------------------------------------------------------------------
-- driver_poll — FAST: battery power (590) + SoC (588) only.
-- ---------------------------------------------------------------------

function driver_poll()
    if rated_w == 0 then rated_w = read_rated_w() end

    -- One small FC03 read: 587..590 (4 regs) covers SoC (588) and
    -- battery output power (590) with the V/hole regs in between. A
    -- single short Modbus transaction → minimal bus window for fast
    -- FFR readback freshness.
    local ok_b, b = bundle_read(587, 4, "holding", "battery")
    local function r(addr)
        if not ok_b then return nil end
        return b[addr - 587 + 1]
    end

    -- Reg 588 = SoC (U16 %, [0,100] → fraction). nil, not 0, when the
    -- read failed: a fabricated 0 % / 0 W tells every consumer "empty
    -- and idle".
    local soc_raw = r(588)
    local bat_soc = soc_raw and (soc_raw / 100) or nil

    -- Reg 590 = battery output power (S16, HV ×10 W / LV ×1 W).
    -- Deye raw +ve = discharge → NEGATE for Sourceful (+charge/-discharge).
    local bat_w_raw = r(590)
    local bat_w = bat_w_raw and -(i16(bat_w_raw) * (is_hv and 10 or 1)) or nil

    -- ── Latch self-heal (VERBATIM from deye@2.4.4) ───────────────────
    -- Only acts when commanded sp == 0 and we observe non-trivial
    -- battery flow for two consecutive polls. The wiggle write here is
    -- the one bus write driver_poll is allowed to do — it recovers from
    -- a known firmware quirk that l1 cannot see.
    if control_initialized and bat_w_raw then
        if last_commanded_pct == 0 and math.abs(bat_w) > SELF_HEAL_FLOOR_W then
            self_heal_disagree_polls = self_heal_disagree_polls + 1
            if self_heal_disagree_polls >= SELF_HEAL_RUN_REQUIRED then
                host.log(string.format(
                    "self-heal: sp=0 but bat_w=%dW for %d polls — wiggling reg 1109",
                    bat_w, self_heal_disagree_polls))
                write_seq("self-heal", { {1109, 1}, {1109, 0} })
                self_heal_disagree_polls = 0
            end
        else
            self_heal_disagree_polls = 0
        end
    end

    -- Energy headroom (Wh) — operator SoC band + capacity, dispatchable.
    local chg_eh_wh, dis_eh_wh = 0, 0
    if battery_capacity_wh > 0 then
        local soc_pct_int = math.floor(bat_soc * 100 + 0.5)
        local span = soc_max_pct - soc_min_pct
        if span > 0 then
            local hi = math.min(soc_pct_int, soc_max_pct)
            local lo = math.max(soc_pct_int, soc_min_pct)
            chg_eh_wh = math.max(0, math.floor(battery_capacity_wh * (soc_max_pct - hi) / 100))
            dis_eh_wh = math.max(0, math.floor(battery_capacity_wh * (lo - soc_min_pct) / 100))
        end
    end

    -- Nothing answered ⇒ nothing to report; the latch self-heal above
    -- has already run on whatever it could see.
    if not ok_b then
        return 5000
    end

    host.emit("battery", {
        W                      = bat_w,        -- DC battery, + charge / - discharge
        SoC_nom_fract          = bat_soc,
        available_charge_Wh    = chg_eh_wh,
        available_discharge_Wh = dis_eh_wh,
    })
    -- AC inverter-port power deliberately NOT emitted here: Deye's grid
    -- total active power is a split i32 whose register differs by
    -- firmware (proven deye.lua uses 619+708; doc V105.3 lists 625) and
    -- the words are too far apart to add cheaply to this lean FFR poll.
    -- FFR/FCR scoring is on the DC battery axis (reg 590) regardless.
    -- Add `inverter { ac_W }` once the AC register is verified on the
    -- target unit.

    return 5000   -- next-poll hint (ms), ignored by the l1 runtime
end

-- ---------------------------------------------------------------------
-- Command — battery power setpoint via Remote Mode. VERBATIM (deye@2.4.4)
-- ---------------------------------------------------------------------
--
-- Deye reg 1109 sign is opposite to Sourceful (+ve = discharge), unit is
-- 0.1 % of rated inverter power, range [-1200, +1200] (-120 % to +120 %):
--   reg_1109 = round(-power_w × 1000 / rated_w), clamped to ±1200.

local function pct_from_watts(power_w)
    if battery_rated_w > 0 then
        if power_w >  battery_rated_w then power_w =  battery_rated_w end
        if power_w < -battery_rated_w then power_w = -battery_rated_w end
    end
    local pct = math.floor(-power_w * 1000 / rated_w + 0.5)
    if pct >  1200 then pct =  1200 end
    if pct < -1200 then pct = -1200 end
    return pct
end

-- Deinit → zero power + disable Remote Mode + clear TOU + fall back to
-- self-consumption. VERBATIM from deye@2.4.4 (incident 2026-04-23: stale
-- TOU slots auto-dumped the battery at full rated power when Remote Mode
-- went off; we fully clear the TOU slots AND charge-enable bits before
-- unlatching Remote Mode so the fallback path can't self-trigger).
local function deinit_to_self_consumption()
    host.log("CMD: deinit → self-consumption")
    control_initialized = false
    last_commanded_pct = 0
    self_heal_disagree_polls = 0
    return write_seq("deinit", {
        {1109, 0},   -- Zero remote setpoint before disabling remote
        {1100, 0},   -- Remote mode off → fall back to LCD/internal
        {141,  2},   -- Energy mgmt: battery first (bits 0-1 = 10)
        {142,  2},   -- Limit control: extraposition (zero export)
        {145,  0},   -- Solar sell disabled
        {146,  0},   -- TOU SELLING DISABLED (bit 0 = 0 per V105.3)
        {130,  0},   -- No grid charging
        {154,  0}, {155, 0}, {156, 0}, {157, 0}, {158, 0}, {159, 0},
        {172,  0}, {173, 0}, {174, 0}, {175, 0}, {176, 0}, {177, 0},
    })
end

function driver_command(action, power_w, cmd)
    host.log("CMD: action=" .. tostring(action) .. " power_w=" .. tostring(power_w))

    if action == "init" then
        return initialize_remote_mode()
    end

    if action == "deinit" then
        local ok = deinit_to_self_consumption()
        if ok then default_mode_refusals = 0 end
        return ok
    end

    if not control_initialized then
        host.log("CMD: auto-initialising Remote Mode")
        if not initialize_remote_mode() then
            host.log("CMD FAIL: Remote Mode init failed")
            return false
        end
    end

    if action == "battery" then
        if rated_w <= 0 then
            host.log("CMD FAIL: rated power unknown")
            return false
        end
        local pct = pct_from_watts(power_w)
        local dir
        if power_w > 0 then dir = "charge"
        elseif power_w < 0 then dir = "discharge"
        else dir = "stop" end
        host.log(string.format(
            "CMD: %s %dW → reg 1109 = %d  (rated=%dW, %d.%d%% of rated)",
            dir, math.abs(power_w), pct, rated_w,
            math.floor(math.abs(pct) / 10),
            math.abs(pct) % 10
        ))
        if pct == 0 then
            -- Deye Remote-Mode latch: writing reg 1109 = 0 directly
            -- often doesn't release a previously-latched non-zero
            -- setpoint. Wiggle through reg 1109 = 1 first, then 0.
            local ok = write_seq("battery", { {1109, 1}, {1109, 0} })
            if ok then
                last_commanded_pct = 0
                self_heal_disagree_polls = 0
            end
            return ok
        end
        local ok = write_seq("battery", { {1109, pct} })
        if ok then
            last_commanded_pct = pct
            self_heal_disagree_polls = 0
        end
        return ok
    end

    host.log("CMD FAIL: unknown action '" .. tostring(action) .. "'")
    return false
end

-- driver_default_mode is the one control path a host may call on a
-- timer (watchdog, lease expiry, shutdown) rather than on a command. If
-- the inverter refuses the self-consumption revert there, keep asking a
-- bounded number of times and then stop reissuing it unprompted — a
-- write refused three times in a row will not land on the fourth. An
-- explicit "deinit" command always attempts the revert regardless, and
-- the counter resets on any successful write.
function driver_default_mode()
    if default_mode_refusals >= DEFAULT_MODE_REFUSALS_BEFORE_STOP then
        return false
    end
    host.log("CMD: default_mode → self-consumption")
    local ok = deinit_to_self_consumption()
    if ok then
        default_mode_refusals = 0
    else
        default_mode_refusals = default_mode_refusals + 1
        if default_mode_refusals == DEFAULT_MODE_REFUSALS_BEFORE_STOP then
            host.log("default_mode: inverter refused the self-consumption revert "
                .. default_mode_refusals .. " times in a row; not reissuing it unprompted")
        end
    end
    return ok
end

function driver_cleanup()
end
