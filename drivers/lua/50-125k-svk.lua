-- Solis S6 Hybrid 50~125 kW — FAST FFR poll variant (SvK suite)
-- Version: 0.1.0
--
-- This is a LEAN sibling of solis_50_125k.lua. The control path
-- (Remote Control V1: arm 44280, setpoint 44282-83, safe-revert) is
-- VERBATIM from that driver — proven on real hardware (Blixt L1 test site,
-- tracks ±10 kW cleanly). The ONLY change is driver_poll: it has been
-- stripped to the minimum needed to score FFR / FCR-D/N truthfully.
--
-- ── WHY THIS DRIVER EXISTS ───────────────────────────────────────────
-- solis_50_125k.lua does 8 Modbus reads (~82 registers) per poll →
-- ~388 ms/cycle at 9600 baud. That's fine for FCR-D/N (7.5 s budget)
-- but too coarse for FFR's sub-second activation: the battery-power
-- readback only refreshes every ~388 ms, so an FFR t100 measurement is
-- dominated by stale readback + poll latency. This driver reads ONLY
-- the fast battery axis the SvK suite + dashboard need:
--
--   34755-34756  Battery Charge/Discharge Power Control Value, S32, 1 W.
--                +charge / -discharge (= Batt1 + Batt2). Sourceful sign
--                is identical → emit as-is. THE critical fast signal.
--   33139        Battery1 SOC U16, 1..100 %, 0 = no battery,
--                101..65535 invalid. (Batt2 34278 is far away — dropped;
--                a single-battery FCR install reports on 33139.)
--   25004-25019  SLOW every 60s: available charge/discharge/import/export
--                power, single + parallel system, U32 1 W. Used by LER/NEM/AEM
--                headroom estimates; not in the fast control loop.
--
-- Two small FC04 reads per poll (2 regs + 1 reg) → well under 100 ms at
-- 9600 baud, vs ~388 ms for the full driver. PV/MPPT (33049×36, 34753),
-- AC/inverter (33xxx), cell V/T, energy counters, and the 25xxx status
-- bundle are all DROPPED — not needed for FFR/FCR scoring.
--
-- driver_init keeps full identification (make/model/sn/rated_w via the
-- 33xxx reads) — those run ONCE at init, so they don't affect cadence.
--
-- ── ADDRESSING / FUNCTION CODES (unchanged from base) ────────────────
--   33xxx / 34xxx / 25xxx telemetry → host.modbus_read(a,n,"input")  (FC04)
--   44xxx control                   → host.write(a, v)               (FC16, count=1 on Blixt L1)
--                                    → host.write_registers(a,{hi,lo}) (FC16)
--   RS485 9600 8N1, inter-frame ≥300 ms. Register numbers literal.
--
-- ── CONTROL PATH (VERBATIM from solis_50_125k.lua) ───────────────────
--   44280  Remote Active Power Control Port Selection. BIT00-03 = 4 →
--          enable Battery Port; BIT04-07 = 0 → no PV shutdown. Value
--          0x0004 = ARM_BATTERY. Reverts to 0 on the 43282 timeout
--          (default 5 min) if no valid command arrives → keepalive is
--          frequent re-arming (every battery command re-asserts 44280).
--   44282-44283  Power Control Battery Power Value, signed int32, 1 W.
--          +charge / -discharge. Sourceful battery is +charge/-discharge
--          too → pass through, no sign flip. Written via FC16 {hi,lo}
--          big-endian, FC06 fallback. |W| clamped to battery_rated_w
--          (or capacity_wh × c_rate) before writing.
--   44284-44285  AC Power Value, S32, 1 W. Zeroed on safe-revert only.
--   SAFE-REVERT (deinit / default_mode): 44282-83 = 0, 44284-85 = 0,
--          then 44280 = 0 (disable all remote control). Inverter then
--          falls back to anti-backflow / self-consumption — will not
--          auto-export/discharge. Safe after a crash mid-init.

PROTOCOL = "modbus"

DRIVER = {
    host_api_min = 1,
    host_api_max = 1,
    id = "50-125k-svk",
    name = "Solis S6 50-125 kW C&I hybrid (SvK)",
    manufacturer = "Solis",
    version = "0.2.3",
    protocols = { "modbus" },
    capabilities = { "battery" },
    read_only = false,
    description = "Solis 50-125 kW three-phase C&I hybrid via Modbus RTU; SvK fast-frequency battery control (no slew).",
    authors = { "David and Blixt L1 contributors", "Sourceful contributors" },
    tested_models = { "S6-GC3P50K", "S6-GC3P100K", "S6-GC3P125K" },
    verification_status = "experimental",
    verification_notes = "Migrated from the Blixt L1 driver source; source has run on hardware under Blixt L1 but no HIL record exists in this repository yet.",
    connection_defaults = {
        unit_id = 1, baud_rate = 9600,
    },
}

DRIVER_MANIFEST = {
    name    = "50-125k-svk",
    version = "0.2.3",
    role    = "battery",

    requires = {
        { name    = "battery_capacity_wh",
          purpose = "control",
          type    = "integer", min = 1000, max = 1000000,
          help    = "Total usable LFP capacity wired to this Solis (Wh). " ..
                    "Not on the bus; configured per install. Used to derive " ..
                    "charge / discharge energy headroom (Wh)." },
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
        { name    = "battery_rated_w",
          purpose = "control",
          type    = "integer", min = 1000, max = 200000,
          help    = "Battery max continuous charge / discharge power (W, " ..
                    "magnitude). Cap on |setpoint| regardless of the " ..
                    "inverter's nameplate. The driver clamps |W| to this " ..
                    "before writing the 44282-83 battery power value." },
        { name    = "battery_max_c_rate",
          purpose = "control",
          type    = "double",  default = 1.0, min = 0.1, max = 5.0,
          help    = "Battery max C-rate. Fallback magnitude cap when " ..
                    "battery_rated_w is unset (capacity_wh × c_rate)." },
        { name    = "pv_shares_ac_stage",
          purpose = "control",
          type    = "boolean", default = true,
          help    = "Hybrid topology: PV + battery contend for the AC " ..
                    "inverter stage. Carried for config-compatibility with " ..
                    "solis_50_125k; this fast driver does not emit PV." },
    },

    provides = {
        live   = { "battery.W", "battery.SoC_nom_fract", "battery.available_charge_Wh",
                   "battery.available_discharge_Wh", "battery.available_charge_W",
                   "battery.available_discharge_W", "inverter.W",
                   "inverter.available_import_W", "inverter.available_export_W" },
        static = { "rated_W", "make", "model", "sn" },
    },
}

PROTOCOL = "modbus"

local rated_w = 0
local control_initialized = false

local battery_rated_w     = 0
local battery_capacity_wh = 0
local soc_min_pct = 0
local soc_max_pct = 100
local battery_max_c_rate = 1.0

-- 44280 value for battery-port remote control: BIT00-03 = 4
-- (battery), BIT04-07 = 0 (no PV shutdown), rest 0.
local ARM_BATTERY = 0x0004

local last_commanded_w = 0
local self_heal_disagree_polls = 0
local SELF_HEAL_FLOOR_W      = 500
local SELF_HEAL_RUN_REQUIRED = 2
local poll_count = 0

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
local SLOW_STATUS_EVERY_POLLS = 12 -- driver_poll returns 5s ⇒ ~60s
local avail_charge_w, avail_discharge_w = nil, nil
local avail_import_w, avail_export_w = nil, nil
local par_avail_charge_w, par_avail_discharge_w = nil, nil
local par_avail_import_w, par_avail_export_w = nil, nil

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------

-- S32 from two U16 words, big-endian register order (hi = reg[N]).
local function s32_be(hi, lo)
    if hi == nil or lo == nil then return nil end
    local raw = hi * 65536 + lo
    if raw >= 2147483648 then raw = raw - 4294967296 end
    return raw
end

local function u32_be(hi, lo)
    if hi == nil or lo == nil then return nil end
    return hi * 65536 + lo
end

local function write_seq(label, writes)
    host.log("[" .. label .. "] writing " .. #writes .. " registers")
    for _, w in ipairs(writes) do
        local addr, val = w[1], w[2]
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

-- Write a signed int32 to a register PAIR. Primary path: FC16
-- write_registers with big-endian word order (hi, lo) to match the
-- read order. Falls back to two FC06 writes if FC16 is unavailable.
local function write_batt_s32(label, base_addr, value)
    local v = value
    if v < 0 then v = v + 4294967296 end
    v = v % 4294967296
    local hi = math.floor(v / 65536)
    local lo = v % 65536
    local ok = host_write_ok(host.write_registers, base_addr, { hi, lo })
    if ok then
        host.log(string.format("[%s] FC16 reg %d..%d = %d (hi=%d lo=%d)",
            label, base_addr, base_addr + 1, value, hi, lo))
        host.sleep(50)
        return true
    end
    host.log("[" .. label .. "] FC16 failed, falling back to 2× FC06")
    return write_seq(label, { { base_addr, hi }, { base_addr + 1, lo } })
end

local function setpoint_cap_w()
    if battery_rated_w > 0 then return battery_rated_w end
    if battery_capacity_wh > 0 then
        return math.floor(battery_capacity_wh * battery_max_c_rate)
    end
    return 0
end

local function read_rated_w()
    local ok, regs = pcall(host.modbus_read, 33067, 1, "input")
    if not ok or not regs or not regs[1] then return 0 end
    return regs[1] * 10
end

-- ---------------------------------------------------------------------
-- driver_init — READ-ONLY identification + capture config.
-- ---------------------------------------------------------------------
function driver_init(config)
    host.set_make("Solis")

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
    if type(config.battery_max_c_rate) == "number" and config.battery_max_c_rate > 0 then
        battery_max_c_rate = config.battery_max_c_rate
    end
    if battery_capacity_wh > 0 then
        host.log("config: SoC band = " .. soc_min_pct .. "%-" .. soc_max_pct .. "%")
    end

    -- SN: reg 33004-33019, 16 regs, 32-byte ASCII direct. Retry 3×.
    local sn = nil
    for attempt = 1, 3 do
        local ok_sn, sn_regs = pcall(host.modbus_read, 33004, 16, "input")
        if ok_sn and sn_regs then
            sn = host.decode_string(sn_regs, 1, 16)
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

    local ok_m, mr = pcall(host.modbus_read, 33000, 4, "input")
    if ok_m and mr then
        host.set_model(string.format("S6-3PH-HV(0x%04X)", mr[1] or 0))
        host.log(string.format("model=0x%04X dsp=0x%04X hmi=0x%04X proto=0x%04X",
            mr[1] or 0, mr[2] or 0, mr[3] or 0, mr[4] or 0))
    else
        host.set_model("S6-3PH-HV")
    end

    -- Remote Control Protocol Version (reg 34799). High byte 0x01 ⇒
    -- V1 supported. Read-only, log only — do not hard-gate.
    local ok_pv, pvr = pcall(host.modbus_read, 34799, 1, "input")
    if ok_pv and pvr and pvr[1] then
        local v = pvr[1]
        local major = math.floor(v / 256)
        host.log(string.format("Remote Control Protocol Version = 0x%04X (V%d)",
            v, major))
        if major ~= 1 then
            host.log("WARN: protocol major != 1 — V1 control path may not apply")
        end
    else
        host.log("WARN: reg 34799 (protocol version) unreadable")
    end

    rated_w = read_rated_w()
    host.set_rated_w(math.floor(rated_w))
    host.log("rated=" .. rated_w .. "W (reg 33067 apparent ×10)")

    host.set_warmup_s(2)
    return true
end

-- ---------------------------------------------------------------------
-- Control init — arm battery Remote Mode (44280 = 0x0004). VERBATIM.
-- ---------------------------------------------------------------------
local function arm_remote_mode()
    if rated_w == 0 then rated_w = read_rated_w() end

    -- Battery port enabled, PV shutdown OFF; push 0 W so the timeout
    -- window opens cleanly.
    local ok = write_seq("init", { { 44280, ARM_BATTERY } })
    if ok then
        ok = write_batt_s32("init", 44282, 0)
    end

    control_initialized = ok
    if ok then
        last_commanded_w = 0
        self_heal_disagree_polls = 0
        host.log("Sleeping 1000ms for Remote Mode to settle")
        host.sleep(1000)
        local ok_rs, rs = pcall(host.modbus_read, 25003, 1, "input")
        if ok_rs and rs and rs[1] then
            local ready = (math.floor(rs[1] / 1) % 2) == 1
            host.log(string.format("post-arm 25003=0x%04X ready=%s",
                rs[1], tostring(ready)))
        end
    end
    return ok
end

-- ---------------------------------------------------------------------
-- driver_poll — FAST: battery power (34755-56) + SoC (33139) every poll.
-- Slow 25xxx available-power block is read ~once/minute for LER estimates.
-- ---------------------------------------------------------------------
function driver_poll()
    poll_count = poll_count + 1
    -- SEPARATE 2-reg reads — NOT one 12-reg bundle. 34757..34764 are
    -- unmapped/reserved in the Solis map and the inverter NAKs a read
    -- spanning them (every poll then times out). Two short contiguous
    -- reads each succeed; the battery read stays the fast FFR axis.
    --   34755-56  Battery Charge/Discharge Power, S32  → DC battery axis
    --   34765-66  AC Grid Port Active Power, S32       → AC inverter port
    local ok_b, bb = bundle_read(34755, 2, "input", "battery-power")
    local ok_a, aa = bundle_read(34765, 2, "input", "ac-power")
    local ok_s, s1 = bundle_read(33139, 1, "input", "soc")

    -- DC battery power S32, +charge / -discharge → Sourceful sign as-is.
    -- nil, not 0, when the read failed: a fabricated 0 W reads as "idle"
    -- to every consumer (the same trap the SoC hold below exists for).
    local bat_w = nil
    if ok_b and bb then
        bat_w = s32_be(bb[1], bb[2])
    end
    -- AC grid-port power S32, Solis "+from inverter" = export to grid.
    local ac_w = nil
    if ok_a and aa and aa[1] and aa[2] then
        ac_w = s32_be(aa[1], aa[2])
    end

    -- SOC: Batt1 33139, valid 1..100 %.
    local soc1 = ok_s and s1 and s1[1] or nil
    local soc_pct = (soc1 ~= nil and soc1 >= 1 and soc1 <= 100) and soc1 or nil
    local bat_soc = soc_pct and (soc_pct / 100) or 0

    if poll_count == 1 or (poll_count % SLOW_STATUS_EVERY_POLLS) == 0 then
        -- 25004-25019 are contiguous in the 50-125K FCR map:
        -- single battery/grid available powers + parallel mirrors. One
        -- sparse 16-reg read is cheaper than 8 separate pair reads.
        local ok_av, av = pcall(host.modbus_read, 25004, 16, "input")
        if ok_av and av then
            avail_charge_w      = u32_be(av[1],  av[2])
            avail_discharge_w   = u32_be(av[3],  av[4])
            avail_import_w      = u32_be(av[5],  av[6])
            avail_export_w      = u32_be(av[7],  av[8])
            par_avail_charge_w    = u32_be(av[9],  av[10])
            par_avail_discharge_w = u32_be(av[11], av[12])
            par_avail_import_w    = u32_be(av[13], av[14])
            par_avail_export_w    = u32_be(av[15], av[16])
        else
            host.log("WARN: 25004-25019 available-power block unreadable")
        end
    end

    -- Latch / timeout-race self-heal: commanded 0 but battery active
    -- for ≥2 polls → re-arm + re-zero. (Kept from base — cheap, uses
    -- only the bat_w we already read.)
    if control_initialized then
        if last_commanded_w == 0 and math.abs(bat_w) > SELF_HEAL_FLOOR_W then
            self_heal_disagree_polls = self_heal_disagree_polls + 1
            if self_heal_disagree_polls >= SELF_HEAL_RUN_REQUIRED then
                host.log(string.format(
                    "self-heal: sp=0 but bat_w=%dW for %d polls — re-arm + zero",
                    bat_w, self_heal_disagree_polls))
                if write_seq("self-heal", { { 44280, ARM_BATTERY } }) then
                    write_batt_s32("self-heal", 44282, 0)
                end
                self_heal_disagree_polls = 0
            end
        else
            self_heal_disagree_polls = 0
        end
    end

    -- Energy headroom (Wh) — operator SoC band + capacity, dispatchable.
    local chg_eh_wh, dis_eh_wh = 0, 0
    if battery_capacity_wh > 0 and soc_pct then
        local span = soc_max_pct - soc_min_pct
        if span > 0 then
            local hi = math.min(soc_pct, soc_max_pct)
            local lo = math.max(soc_pct, soc_min_pct)
            chg_eh_wh = math.max(0, math.floor(battery_capacity_wh * (soc_max_pct - hi) / 100))
            dis_eh_wh = math.max(0, math.floor(battery_capacity_wh * (lo - soc_min_pct) / 100))
        end
    end

    -- Nothing answered ⇒ nothing to report. The control path above
    -- keeps running; telemetry stays silent until the bus is back.
    if not ((ok_b and bb) or (ok_a and aa) or (ok_s and s1)) then
        return 5000
    end

    host.emit("battery", {
        W                      = bat_w,        -- DC battery, + charge / - discharge
        SoC_nom_fract          = bat_soc,
        available_charge_Wh    = chg_eh_wh,
        available_discharge_Wh = dis_eh_wh,
        available_charge_W     = par_avail_charge_w or avail_charge_w,
        available_discharge_W  = par_avail_discharge_w or avail_discharge_w,
    })
    -- AC grid-port power as the inverter role (separate measurement from
    -- the DC battery). Only when the read produced a value.
    if ac_w ~= nil then
        host.emit("inverter", {
            W = ac_w,
            available_import_W = par_avail_import_w or avail_import_w,
            available_export_W = par_avail_export_w or avail_export_w,
        })
    end

    return 5000
end

-- ---------------------------------------------------------------------
-- Control — battery power setpoint via V1 (44280 arm + 44282-83). VERBATIM.
-- ---------------------------------------------------------------------
local function deinit_safe_revert()
    host.log("CMD: deinit → safe revert")
    control_initialized = false
    last_commanded_w = 0
    self_heal_disagree_polls = 0
    local ok1 = write_batt_s32("deinit", 44282, 0)   -- battery power 0
    local ok2 = write_batt_s32("deinit", 44284, 0)   -- AC power 0
    local ok3 = write_seq("deinit", { { 44280, 0 } }) -- remote control OFF
    return ok1 and ok2 and ok3
end

function driver_command(action, power_w, ctx)
    host.log("CMD: action=" .. tostring(action) .. " power_w=" .. tostring(power_w or 0))

    if action == "init" then
        return arm_remote_mode()
    end

    if action == "deinit" then
        local ok = deinit_safe_revert()
        if ok then default_mode_refusals = 0 end
        return ok
    end

    if action == "battery" then
        if not control_initialized then
            host.log("CMD: auto-arming Remote Mode (first battery call)")
            if not arm_remote_mode() then
                host.log("CMD FAIL: Remote Mode arm failed")
                return false
            end
        end

        local w = power_w or 0
        local cap = setpoint_cap_w()
        if cap > 0 then
            if w >  cap then w =  cap end
            if w < -cap then w = -cap end
        end

        local dir = (w > 0 and "charge") or (w < 0 and "discharge") or "stop"
        host.log(string.format("CMD: %s %dW → 44280=0x%04X 44282-83=%d",
            dir, w, ARM_BATTERY, w))
        if not write_seq("battery", { { 44280, ARM_BATTERY } }) then
            host.log("CMD FAIL: could not re-assert arm 44280")
            return false
        end
        local ok = write_batt_s32("battery", 44282, w)
        if ok then
            last_commanded_w = w
            self_heal_disagree_polls = 0
        end
        return ok
    end

    host.log("CMD FAIL: unknown action '" .. tostring(action) .. "'")
    return false
end

-- driver_default_mode is the one control path a host may call on a
-- timer (watchdog, lease expiry, shutdown) rather than on a command. If
-- the inverter refuses the 0 W revert there, keep asking a bounded
-- number of times and then stop reissuing it unprompted — a write the
-- device has refused three times in a row will not land on the fourth,
-- and the 44280 arm has its own 5-minute vendor revert. An explicit
-- "deinit" command always attempts the revert regardless (that path is
-- prompted), and the counter resets on any successful write.
function driver_default_mode()
    if default_mode_refusals >= DEFAULT_MODE_REFUSALS_BEFORE_STOP then
        return false
    end
    host.log("CMD: default_mode → safe revert (slew BYPASSED)")
    local ok = deinit_safe_revert()
    if ok then
        default_mode_refusals = 0
    else
        default_mode_refusals = default_mode_refusals + 1
        if default_mode_refusals == DEFAULT_MODE_REFUSALS_BEFORE_STOP then
            host.log("default_mode: inverter refused the 0 W revert "
                .. default_mode_refusals .. " times in a row; not reissuing it "
                .. "unprompted (44280 arm reverts on its own 5 min timeout)")
        end
    end
    return ok
end

function driver_cleanup()
end
