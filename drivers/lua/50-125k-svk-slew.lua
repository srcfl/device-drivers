-- Solis S6 Hybrid 50~125 kW — SLEW-DEACTIVATION variant (SvK FFR kort uthållighet)
-- Version: 0.1.11
-- 0.1.10 → 0.1.11: deinit_safe_revert now resets the wall-clock slew
--                clock (slew_last_write_ms = now_ms()) instead of
--                writing the undeclared global slew_last_write_poll —
--                leftover from the poll-count → wall-clock refactor.
-- 0.1.0 → 0.1.1: fix deact-budget accumulation bug. Slew clock
--                now resets when deactivation is REGISTERED, not at
--                the last bus write — so the activation hold doesn't
--                bank a giant first-step budget that snaps the
--                inverter on entry to the deact phase.
--
-- Forked VERBATIM from `50-125k-svk@0.2.2` (same lean Modbus map, same
-- Remote Control V1 arm/setpoint/safe-revert path). The ONLY change:
-- deactivation slewing on the battery setpoint.
--
-- ── WHY THIS DRIVER EXISTS ───────────────────────────────────────────
-- Testprogram FFR v1.6 §1.4 Tabell 3 (sid 4) caps the deactivation
-- rate for **kort uthållighet** bids at **20 % of contracted cap per
-- second** (= full → 0 over ≥ 5 s minimum). Solis Remote Mode V1 has
-- NO inbuilt slew rate — when the test runner sends `battery 0` after
-- an FFR activation, the inverter snaps the AC output 10 kW → 0 in
-- ~13 ms, giving |dP/dt| ≈ 800 %/s. That's a 40× spec violation, and
-- it failed every kort-uthållighet test on angry-tea 2026-06-05.
--
-- This driver enforces the spec at the **driver level** so the test
-- runner doesn't have to know about it — the lua decides when to
-- write a stepped intermediate setpoint vs. pass through immediately.
--
-- ── SLEW SEMANTICS ───────────────────────────────────────────────────
-- The driver tracks `slew_target_w` (what the controller asked for)
-- and `slew_committed_w` (what we last wrote to Solis). On each
-- `driver_command("battery", w)`:
--
--   1. If |w| ≥ |committed_w| → ACTIVATION (or hold / direction-up
--      in magnitude). Write immediately. FFR / FCR-D need fast
--      activation; spec gives ≥ 700 ms even at C-tier — no slew here.
--
--   2. If |w| < |committed_w| → DEACTIVATION. Register the new
--      target but DO NOT write yet. `driver_poll()` (which runs
--      every ~100 ms on this lean driver) is responsible for stepping
--      `committed_w` toward `target_w` at the configured slew rate.
--      Each poll-step = (rate %/s × elapsed_seconds × cap_w).
--
-- The actual deact ramp the test scorer sees is the Solis battery
-- power readback — which honestly tracks the stepped setpoints we
-- write. At 20 %/s on a 10 kW cap that's a 5-second ramp, 50 steps
-- @ 10 Hz, each ~200 W lower than the previous.
--
-- **`init` and `deinit` BYPASS the slew entirely.** Safe-revert at
-- container-stop, operator-stop, or after a crash needs to take the
-- inverter to 0 W immediately regardless of slew config. The slew is
-- a control-policy enforcement, not a safety rail; safety paths must
-- not be slewed.
--
-- ── ADDRESSING / FUNCTION CODES (unchanged from base) ────────────────
--   33xxx / 34xxx / 25xxx telemetry → host.modbus_read(a,n,"input")  (FC04)
--   44xxx control                   → host.write(a, v)               (FC16, count=1 on Blixt L1)
--                                    → host.write_registers(a,{hi,lo}) (FC16)
--   RS485 9600 8N1, inter-frame ≥300 ms. Register numbers literal.
--
-- ── CONTROL PATH (VERBATIM from 50-125k-svk@0.2.2) ───────────────────
--   44280  Remote Active Power Control Port Selection. 0x0004 = arm
--          battery port. Re-asserted on every battery write (5 min
--          revert timeout otherwise).
--   44282-44283  Power Control Battery Power Value, signed int32, 1 W.
--          +charge / -discharge. Sourceful sign as-is.
--   44284-44285  AC Power Value, S32, 1 W. Zeroed on safe-revert only.

PROTOCOL = "modbus"

DRIVER = {
    host_api_min = 1,
    host_api_max = 1,
    id = "50-125k-svk-slew",
    name = "Solis S6 50-125 kW C&I hybrid (SvK, slew-limited)",
    manufacturer = "Solis",
    version = "0.1.11",
    protocols = { "modbus" },
    capabilities = { "battery" },
    read_only = false,
    description = "Solis 50-125 kW three-phase C&I hybrid via Modbus RTU; SvK fast-frequency battery control with configurable deactivation slew.",
    authors = { "David and Blixt L1 contributors", "Sourceful contributors" },
    tested_models = { "S6-GC3P50K", "S6-GC3P100K", "S6-GC3P125K" },
    verification_status = "experimental",
    verification_notes = "Migrated from the Blixt L1 device-support registry; source has run on hardware under Blixt L1 but no HIL record exists in this repository yet.",
    connection_defaults = {
        unit_id = 1, baud_rate = 9600,
    },
}

DRIVER_MANIFEST = {
    name    = "50-125k-svk-slew",
    version = "0.1.11",
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
        { name    = "ffr_slew_rate_pct_per_s",
          purpose = "control",
          type    = "double",  default = 100000.0, min = 1.0, max = 100000.0,
          help    = "Max deactivation slew rate as % of |setpoint_cap_w| " ..
                    "per second. Applied ONLY when |new_setpoint| < " ..
                    "|current_setpoint| (deactivation). Activation, hold, " ..
                    "and direction-up-in-magnitude bypass the slew and " ..
                    "write immediately. init() / deinit() also bypass — " ..
                    "safe-revert must reach 0 W instantly. Default is " ..
                    "**no slew enforcement** (100000 %/s, effectively " ..
                    "unbounded) so the driver behaves transparently for " ..
                    "FCR-D/N, aFRR, mFRR, and operator setpoints. SvK FFR " ..
                    "§1.4 Tabell 3 kort uthållighet caps deact at 20 %/s — " ..
                    "the runner constrains via driver_command('set_slew_" ..
                    "rate', 15) only for that specific test profile." },
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

-- Slew configuration. Two layers:
--   • `ffr_slew_rate_pct_per_s_default` — set by device config in
--     `driver_init`. Spec-safe default for unknown context.
--   • `ffr_slew_rate_pct_per_s` — the LIVE rate. Defaults to the
--     config value; overridden at runtime by
--     `driver_command("set_slew_rate", pct_per_s)`. The runner uses
--     this hook to flip between SvK FFR §1.4 kort uthållighet
--     (20 %/s) and lang uthållighet ("stegvis deaktivering tillåten"
--     — effectively unbounded; we use 100 %/s = 1 s full→0 which is
--     fast enough to look like a snap on a 10 kW cap but still
--     bounded) per test entry.
-- Default is **no slew enforcement** — the driver behaves like the
-- non-slew sibling unless the caller explicitly constrains it via
-- `driver_command("set_slew_rate", pct)`. This keeps the driver
-- market-agnostic: SvK FFR §1.4 Tabell 3 needs a cap (operator
-- sends 15 %/s via slew_override.json from the runner for kort
-- uthållighet), while FCR-D/N, aFRR, mFRR and operator manual
-- setpoints need full direct droop tracking. 100000 = effectively
-- unbounded (a 10 kW cap would slew in 0.0001 s = one Modbus
-- write). When the runner clears slew_override the driver returns
-- to this safe default automatically.
local ffr_slew_rate_pct_per_s_default = 100000.0
local ffr_slew_rate_pct_per_s = 100000.0
-- 44280 value for battery-port remote control: BIT00-03 = 4
-- (battery), BIT04-07 = 0 (no PV shutdown), rest 0.
local ARM_BATTERY = 0x0004

-- Slew state: target = what the controller asked for; committed =
-- what we last wrote to 44282; last_write_ms = host.now_ms() at that
-- write. Lets driver_poll step incrementally on each cycle, bounded
-- by REAL elapsed time, not the poll counter (the per-device poll
-- cadence varies with bus load — v0.1.1 used poll_count and saw
-- 139 %/s instead of 20 %/s because the actual cycle was ~14 ms not
-- the 100 ms estimate).
local slew_target_w = 0
local slew_committed_w = 0
-- Last valid SoC (1-100) + how long reads have been invalid — see
-- the hold logic in driver_poll.
local last_good_soc_pct = nil
local soc_invalid_polls = 0
-- Self-heal stability guard: committed at the previous poll.
local self_heal_prev_committed_w = 0
local slew_last_write_ms = 0

local last_commanded_w = 0
local self_heal_disagree_polls = 0
local SELF_HEAL_FLOOR_W      = 500
-- 4 polls (~0.6 s at the 150 ms cycle) — enough for the inverter's
-- own ~0.3 s step-follow latency so a fresh activation never trips.
local SELF_HEAL_RUN_REQUIRED = 4
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
        -- Inter-frame gap. Modbus RTU spec is 3.5 char times
        -- (~3.6 ms @ 9600 baud); the legacy 50 ms here was carry-over
        -- from the original Solis driver and added ~80 ms to every
        -- setpoint dispatch — fatal for FFR §4.2.2 ramp ±50 mHz
        -- (≙ ±250 ms @ 0.2 Hz/s). 10 ms is well above the spec
        -- minimum and proven safe on the angry-tea bench.
        host.sleep(10)
    end
    host.log("[" .. label .. "] OK")
    return true
end

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
        host.sleep(10)  -- inter-frame gap; see write_seq for rationale.
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

-- Per-step budget = rate × cap × elapsed_since_last_commit.
--
-- `elapsed_ms` is clamped at MAX_BUDGET_ELAPSED_MS = 1000 ms (= SvK
-- FFR 1.6 §1.4 Tabell 3 measurement window). This is the only knob
-- that matters: the maximum single-step jump is rate × cap × 1 s,
-- which IS the configured rate measured over the SvK window. So the
-- 1-s sliding metric (`_ffr_deact_rate_max_pct_per_s`) can never read
-- a peak above the configured rate, regardless of poll-cycle jitter
-- or driver_poll stalls.
--
-- This replaces an earlier hard-coded MAX_FINAL_STEP_FRAC_OF_CAP =
-- 1.5 % cap that ran independently of `ffr_slew_rate_pct_per_s` —
-- which silently overrode the no-slew default (100 000 %/s) and
-- forced every FCR-D / FCR-N deactivation through a ~2.5 kW/s tail,
-- failing FCR-D 8.0 §3.1.2 Req 4 (deact energy ≤ 2.5 s × ΔP_ss_theo).
-- See angry-tea 2026-06-09 capture
-- `sourceful_solis_fcrd_..._20260609T061544Z`.
local MAX_BUDGET_ELAPSED_MS = 1000

-- Returns math.huge when cap is unknown (no slew enforcement —
-- fail-open so a meterless rig isn't jammed by the slew block).
local function slew_step_budget_w(elapsed_ms)
    local cap = setpoint_cap_w()
    if cap <= 0 then return math.huge end
    if elapsed_ms < 0 then elapsed_ms = 0 end
    if elapsed_ms > MAX_BUDGET_ELAPSED_MS then
        elapsed_ms = MAX_BUDGET_ELAPSED_MS
    end
    local elapsed_s = elapsed_ms / 1000.0
    return cap * (ffr_slew_rate_pct_per_s / 100.0) * elapsed_s
end

-- Safe wall-clock read. host.now_ms is provided by recent l1 hosts.
-- If absent (older host), returns 0 — caller falls back to a fixed
-- single-step write per cycle (which is still bounded but coarser).
local function now_ms()
    if type(host.now_ms) == "function" then
        local ok, v = pcall(host.now_ms)
        if ok and type(v) == "number" then return v end
    end
    return 0
end

-- Step `committed_w` toward `target_w` by at most `max_step_w`.
-- Returns the next committed value. When the elapsed budget covers
-- the full remaining delta, jump straight to target — `max_step_w`
-- is already bounded by rate × cap × 1 s (the SvK measurement
-- window), so a snap inside that bound is below the configured rate
-- by construction.
local function slew_next_w(committed_w, target_w, max_step_w)
    local delta = target_w - committed_w
    if math.abs(delta) <= max_step_w then return target_w end
    if delta > 0 then return math.floor(committed_w + max_step_w + 0.5) end
    return math.floor(committed_w - max_step_w + 0.5)
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
    if type(config.ffr_slew_rate_pct_per_s) == "number"
       and config.ffr_slew_rate_pct_per_s > 0 then
        ffr_slew_rate_pct_per_s_default = config.ffr_slew_rate_pct_per_s
        ffr_slew_rate_pct_per_s         = config.ffr_slew_rate_pct_per_s
        host.log("config: ffr_slew_rate_pct_per_s = " ..
                 string.format("%.2f", ffr_slew_rate_pct_per_s) .. " %/s (default)")
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
-- Control init — arm battery Remote Mode (44280 = 0x0004).
-- BYPASSES slew: init MUST take inverter to 0 W immediately.
-- ---------------------------------------------------------------------
local function arm_remote_mode()
    if rated_w == 0 then rated_w = read_rated_w() end

    local ok = write_seq("init", { { 44280, ARM_BATTERY } })
    if ok then
        ok = write_batt_s32("init", 44282, 0)
    end

    control_initialized = ok
    if ok then
        last_commanded_w = 0
        slew_target_w = 0
        slew_committed_w = 0
        slew_last_write_ms = now_ms()
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
-- driver_poll — FAST telemetry + deferred slew step.
-- ---------------------------------------------------------------------
function driver_poll()
    poll_count = poll_count + 1
    local ok_b, bb = bundle_read(34755, 2, "input", "battery-power")
    local ok_a, aa = bundle_read(34765, 2, "input", "ac-power")
    local ok_s, s1 = bundle_read(33139, 1, "input", "soc")

    -- nil, not 0, when the read failed: a fabricated 0 W reads as "idle"
    -- to every consumer (the same trap the SoC hold below exists for).
    local bat_w = nil
    if ok_b and bb then
        bat_w = s32_be(bb[1], bb[2])
    end
    local ac_w = nil
    if ok_a and aa and aa[1] and aa[2] then
        ac_w = s32_be(aa[1], aa[2])
    end

    local soc1 = ok_s and s1 and s1[1] or nil
    local soc_pct = (soc1 ~= nil and soc1 >= 1 and soc1 <= 100) and soc1 or nil
    -- Hold the last GOOD SoC through invalid reads (Modbus miss, or
    -- the register reading 0 during load transients). Emitting 0 on a
    -- bad read told every consumer "battery empty": on 2026-06-11 the
    -- SvK runner's SoC guard aborted the Req 12 endurance suite at a
    -- claimed 0 % while the real SoC was ~60 %, skipping 18 tests.
    if soc_pct ~= nil then
        last_good_soc_pct = soc_pct
    elseif last_good_soc_pct ~= nil then
        soc_pct = last_good_soc_pct
        soc_invalid_polls = soc_invalid_polls + 1
        if soc_invalid_polls % 100 == 1 then
            host.log(string.format(
                "WARN: SoC read invalid for %d polls — holding last good %d%%",
                soc_invalid_polls, soc_pct))
        end
    end
    if soc_pct ~= nil and soc_pct == last_good_soc_pct then
        soc_invalid_polls = (soc1 ~= nil and soc1 >= 1 and soc1 <= 100)
            and 0 or soc_invalid_polls
    end
    local bat_soc = soc_pct and (soc_pct / 100) or 0

    if poll_count == 1 or (poll_count % SLOW_STATUS_EVERY_POLLS) == 0 then
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

    -- ── Slew step ──────────────────────────────────────────────────
    -- If `committed_w` hasn't reached `target_w` yet (a pending
    -- deactivation, registered by driver_command but not yet fully
    -- written down), step it now. One step per poll cycle, bounded
    -- by `slew_step_budget_w(elapsed_ms)`. Real wall-clock time —
    -- poll cadence varies with bus load, so poll_count is unreliable
    -- for rate enforcement.
    if control_initialized and slew_committed_w ~= slew_target_w then
        local now = now_ms()
        local elapsed_ms = (now > 0 and slew_last_write_ms > 0)
            and (now - slew_last_write_ms) or 0
        local max_step = slew_step_budget_w(elapsed_ms)
        local next_w = slew_next_w(slew_committed_w, slew_target_w, max_step)
        if next_w ~= slew_committed_w then
            host.log(string.format(
                "slew: %dW → %dW (target=%dW, step≤%dW, elapsed=%dms)",
                slew_committed_w, next_w, slew_target_w,
                math.floor(max_step + 0.5), elapsed_ms))
            if write_seq("slew", { { 44280, ARM_BATTERY } }) then
                if write_batt_s32("slew", 44282, next_w) then
                    slew_committed_w = next_w
                    slew_last_write_ms = now > 0 and now or slew_last_write_ms
                    last_commanded_w = next_w
                end
            end
        end
    end

    -- ── Self-heal latch (generalised) ──────────────────────────────
    -- Original form only covered "commanded 0 but battery still
    -- running". The Req 12 endurance test exposed the inverse:
    -- Solis Remote Mode silently REVERTS after ~5 min without a
    -- register write, dropping a commanded ±10 kW hold to 0 W
    -- (2026-06-11, 15-min ramp-3 hold released at t≈392 s = hold
    -- start + 300 s). Now ANY sustained disagreement between the
    -- measured power and a STABLE committed setpoint re-arms Remote
    -- Mode and rewrites the setpoint. Guarded on committed being
    -- unchanged between polls so an in-flight slew/ramp (where
    -- disagreement is expected) never trips it.
    if control_initialized then
        local err_w = math.abs(bat_w - slew_committed_w)
        local tol_w = math.max(SELF_HEAL_FLOOR_W,
                               math.abs(slew_committed_w) * 0.15)
        if err_w > tol_w
           and slew_committed_w == self_heal_prev_committed_w
           and slew_committed_w == slew_target_w then
            self_heal_disagree_polls = self_heal_disagree_polls + 1
            if self_heal_disagree_polls >= SELF_HEAL_RUN_REQUIRED then
                host.log(string.format(
                    "self-heal: committed=%dW but bat_w=%dW for %d polls — re-arm + rewrite",
                    slew_committed_w, bat_w, self_heal_disagree_polls))
                if write_seq("self-heal", { { 44280, ARM_BATTERY } }) then
                    write_batt_s32("self-heal", 44282, slew_committed_w)
                    slew_last_write_ms = now_ms()
                end
                self_heal_disagree_polls = 0
            end
        else
            self_heal_disagree_polls = 0
        end
        self_heal_prev_committed_w = slew_committed_w
    end

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

    -- Nothing answered ⇒ nothing to report. The slew/self-heal above
    -- keeps running; telemetry stays silent until the bus is back.
    if not ((ok_b and bb) or (ok_a and aa) or (ok_s and s1)) then
        return 5000
    end

    host.emit("battery", {
        W                      = bat_w,
        SoC_nom_fract          = bat_soc,
        available_charge_Wh    = chg_eh_wh,
        available_discharge_Wh = dis_eh_wh,
        available_charge_W     = par_avail_charge_w or avail_charge_w,
        available_discharge_W  = par_avail_discharge_w or avail_discharge_w,
    })
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
-- Control — battery power setpoint via V1.
-- Slew on deactivation; immediate on activation. init/deinit bypass.
-- ---------------------------------------------------------------------
local function deinit_safe_revert()
    host.log("CMD: deinit → safe revert (slew BYPASSED)")
    control_initialized = false
    last_commanded_w = 0
    slew_target_w = 0
    slew_committed_w = 0
    slew_last_write_ms = now_ms()
    self_heal_disagree_polls = 0
    local ok1 = write_batt_s32("deinit", 44282, 0)
    local ok2 = write_batt_s32("deinit", 44284, 0)
    local ok3 = write_seq("deinit", { { 44280, 0 } })
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

    if action == "set_slew_rate" then
        -- Runtime slew-rate override. `power_w` is reused as the
        -- numeric carrier (driver_command signature has no extra
        -- scalar slot). Test runner sends this before each FFR test:
        --   kort uthållighet (§1.4 Tabell 3 max 20 %/s) → 20
        --   lang uthållighet (§1.4 "stegvis deaktivering tillåten")
        --     → e.g. 100 (effectively unbounded for a 10 kW cap)
        -- Reset to config default when 0 / negative is sent.
        local pct = power_w or 0
        if pct <= 0 then
            ffr_slew_rate_pct_per_s = ffr_slew_rate_pct_per_s_default
            host.log(string.format(
                "set_slew_rate: reset to default %.2f %%/s",
                ffr_slew_rate_pct_per_s))
        else
            ffr_slew_rate_pct_per_s = pct
            host.log(string.format(
                "set_slew_rate: %.2f %%/s (was default %.2f %%/s)",
                ffr_slew_rate_pct_per_s, ffr_slew_rate_pct_per_s_default))
        end
        return true
    end

    if action == "battery" then
        if not control_initialized then
            host.log("CMD: auto-arming Remote Mode (first battery call)")
            if not arm_remote_mode() then
                host.log("CMD FAIL: Remote Mode arm failed")
                return false
            end
        end

        local target_w = power_w or 0
        local cap = setpoint_cap_w()
        if cap > 0 then
            if target_w >  cap then target_w =  cap end
            if target_w < -cap then target_w = -cap end
        end

        slew_target_w = target_w

        local mag_target    = math.abs(target_w)
        local mag_committed = math.abs(slew_committed_w)

        if mag_target >= mag_committed then
            -- Activation, hold, or direction-up-in-magnitude: pass
            -- through. FFR §1.2 Tabell 2 caps full activation at
            -- 0.70 s (C-tier) — slew would break that. Note: this
            -- ALSO covers sign changes where the new magnitude grows
            -- (e.g. committed=-3 kW → target=+5 kW), which is the
            -- right semantic — the operator wants new power flowing.
            local dir = (target_w > 0 and "charge")
                or (target_w < 0 and "discharge") or "stop"
            host.log(string.format(
                "CMD: %s %dW (activation/hold, slew bypassed) → 44282-83=%d",
                dir, target_w, target_w))
            if not write_seq("battery", { { 44280, ARM_BATTERY } }) then
                host.log("CMD FAIL: could not re-assert arm 44280")
                return false
            end
            local ok = write_batt_s32("battery", 44282, target_w)
            if ok then
                slew_committed_w = target_w
                slew_last_write_ms = now_ms()
                last_commanded_w = target_w
                self_heal_disagree_polls = 0
            end
            return ok
        else
            -- Deactivation: register the target, let driver_poll
            -- step `committed_w` toward it at the configured rate.
            -- Return true so the controller sees the command as
            -- accepted — the slew is a control policy, not a fault.
            --
            -- Do NOT touch `slew_last_write_ms` here. The budget
            -- clock measures time since the last BUS WRITE; an
            -- earlier version reset it to now() on every deact
            -- command "so the budget doesn't accumulate over the
            -- activation hold" — but that's already bounded by
            -- MAX_BUDGET_ELAPSED_MS (1 s = the SvK measurement
            -- window), and the reset starved the slew entirely
            -- under a continuously-falling setpoint: mid-sine-flank
            -- the arbitrator dispatches every ~16 ms, each reset
            -- pinned elapsed≈0 → budget≈0 → no write, until the
            -- flank levelled off and the whole accumulated delta
            -- snapped in one cliff (found live 2026-06-10, FCR-D
            -- down sine 10 s: 6875→3775 W in one write after 2.15 s
            -- of silence — even at the no-slew 100000 %/s default,
            -- because rate × 0 elapsed = 0 budget).
            host.log(string.format(
                "CMD: deactivate registered, target=%dW (committed=%dW, " ..
                "slew %.1f%%/s, ~%.1fs to reach target)",
                target_w, slew_committed_w, ffr_slew_rate_pct_per_s,
                math.abs(target_w - slew_committed_w) /
                math.max(1, cap * ffr_slew_rate_pct_per_s / 100.0)))
            return true
        end
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
