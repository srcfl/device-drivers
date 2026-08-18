-- Konja Power 261 kWh / 125 kW C&I BESS — SvK test driver
-- Version: 0.3.0
--
-- Target: Konja "MG series" liquid-cooled 261 kWh cabinet with the
-- **MG500 EMS** as the Modbus master-of-record and an **Enjoy Power
-- 125 kW PCS** behind it. Protocol source: `261_EMS_Protocol_V116 -
-- PCS - EN.xlsx` (V1.16, 2026-06-26, received from Konja 2026-08-11).
--
-- Forked in SHAPE (not registers) from `50-125k-svk-slew@0.1.11` —
-- same 5-function form, same arm / setpoint / safe-revert / slew /
-- self-heal structure, same Sourceful sign convention. Only the
-- register map and the encoding differ.
--
-- ── TRANSPORT ────────────────────────────────────────────────────────
--   Modbus **TCP**, the EMS listens on **port 1502** (NOT 502).
--   Default unit id 1. RS-485 alternative is 9600 8N1 (unused here).
--   Site config:
--     "transport": { "type": "tcp", "host": "<ems-ip>", "port": 1502 }
--
-- ── FUNCTION CODES ───────────────────────────────────────────────────
--   The spreadsheet's "Function Code" legend on the Instruction sheet
--   is mistranslated (it labels 03H "read input" and 04H "write
--   coil"). The per-sheet block headers are authoritative and are
--   plain Modbus:
--     "Remote Measurement (YC) Function Code 04"  → FC04 input regs
--            → host.modbus_read(addr, n, "input")
--     "Remote Control (YT) Function Code 03"      → FC03 holding regs
--            → host.modbus_read(addr, n, "holding")
--            → host.write_registers(addr, {...})  (FC16)
--
-- ── CONTROL PATH — EMS, NOT PCS ──────────────────────────────────────
-- Instruction sheet, Special Notes: *"Currently, only the write
-- function of MG500 (EMS) is enabled. Prior notification is required
-- when using the write function of other devices."*
--
-- So the whole control path goes through the EMS holding block, per
-- the "EMS External Control Steps" note (EMS sheet, r69):
--
--   337  Local/Remote Setting        write 100  (= 1, Remote)
--   343  External Control Config     write 100  (= 1, Activated)
--   300  Mode Setting                write 100  (= 1, Operating)
--   344  Slave Power Setting         IEEE-754 float32, hi word first
--                                    unit 0.01 kW, **+ = DISCHARGE**
--
-- The note's worked example: *"write +5000 to Registers 344 and 345,
-- which means discharging at 50 kW"* — i.e. the float carries the
-- already-scaled value (kW × 100), it is not a raw float in kW.
--
-- SIGN: Konja is +discharge / −charge. Sourceful is −discharge /
-- +charge. Every power value crossing this driver is negated once,
-- in `k2s()` / `s2k()`. Nowhere else.
--
-- ── WATCHDOG ─────────────────────────────────────────────────────────
-- Instruction sheet: *"When external control mode is enabled, EMS
-- will automatically set the output power to 0 if no communication
-- data is received within 3 minutes"* — and the TCP socket is dropped
-- after 3 min idle. Our poll cadence (≥ 5 Hz) keeps both alive with a
-- ~1800× margin, so no synthetic heartbeat write is needed. The V1.14
-- changelog mentions an "external control heartbeat ... applicable to
-- software version V4.2.1 and above" but the workbook contains no
-- such register — folded into OPEN QUESTION Q1.
--
-- ── CABINET METER (new in 0.3.0) ─────────────────────────────────────
-- The cabinet carries its own 3-phase power meter — an **Acrel ADL400**
-- (Version sheet, V100: *"Add point information for … ADL400 Electric
-- Meter …"*) — proxied by the EMS at 4000-4109, read with FC04
-- ("Remote Measurement (YC) Function Code 04", Meter sheet r2).
--
-- Registers used, all literal rows of the Meter sheet:
--   4060/4061/4062  Phase A/B/C Voltage        uint16  0.1 V
--   4063/4064/4065  Phase A/B/C Current        uint16  0.01 A (UNSIGNED)
--   4066            Frequency                  uint16  0.01 Hz
--   4082/4084/4086  Phase A/B/C Active Power   int32   0.001 kW = 1 W
--   4088            Total Active Power         int32   0.001 kW = 1 W
--   4010            Forward Total Active Energy uint32 0.01 kWh = 10 Wh
--   4020            Reverse Total Active Energy uint32 0.01 kWh = 10 Wh
--
-- Word order for the int32/uint32 pairs is the workbook's documented
-- rule — Instruction sheet r4 and r6, *"32-bit word, transmitted using
-- two consecutive Modbus addresses. **The high word is located at the
-- lower Modbus address**"* — so 4088 = bits 31..16, 4089 = bits 15..0.
-- Unlike the float setpoint at 344/345, this IS stated for int32, so it
-- needs no probe.
--
-- SIGN — READ THIS BEFORE TRUSTING THE NUMBER.
-- The Meter sheet's Description column is **empty for 4088**. The
-- vendor never states which direction is positive. The driver emits
-- reg 4088 **as-is, with NO negation**, i.e. positive = import. The
-- evidence for that choice, in order of strength:
--   1. The workbook splits active energy into "Forward" (4010) and
--      "Reverse" (4020) accumulators. A meter that names one direction
--      "forward" measures signed power with forward positive.
--   2. EMS 328/329 are "Anti-reverse Current Setting / Value" — an
--      anti-backflow function, which only means anything if the CT sits
--      at the **grid connection point** and "reverse" means export to
--      the grid. Forward is therefore import.
--   3. Sourceful's meter convention is + = into the asset = import.
--      So (1)+(2) line up with Sourceful and the value passes through
--      unchanged. This is the OPPOSITE handling to the PCS/BMS power
--      registers, which are + = discharge and ARE negated via k2s().
-- That chain is an inference, not a vendor statement. It is verified
-- LIVE by `check_meter_placement` on the first decisive commanded
-- setpoint: it baselines the meter while the cabinet is at 0 W, then
-- compares the delta against what the PCS actually delivered. It
-- reports one of three verdicts (confirmed / inverted / CT not at the
-- grid connection) and NEVER auto-corrects — silently flipping a sign
-- because a reading disagreed is how a wiring question becomes an
-- uncommanded charge.
--
-- WHY THIS MATTERS MORE THAN A NORMAL TELEMETRY FIELD.
-- In l1 (`main.rs`, meter-source chain) a controllable device's own
-- `meter` emit becomes the **site grid meter** whenever `site.meter`
-- and `site.grid_meter_device` are both unset — it then feeds the fuse
-- clamp and export protection, not just the dashboard. 0.1.0/0.2.0
-- withheld the emit for exactly that reason. 0.3.0 emits it by
-- operator decision (2026-08-12): the finer signal is worth having and
-- the operator selects the site grid meter explicitly in the dashboard
-- when the CT turns out to be somewhere other than the grid
-- connection. `driver_init` logs this consequence loudly so it can
-- never be a surprise.
--
-- The emit is SUPPRESSED entirely when all three phase voltages read 0
-- — a dead or unconfigured ADL400 must look like "no meter", never
-- like "grid balanced at 0 W". EMS reg 13 (Electricity Meter
-- Communication Fault) already surfaces in the slow status sweep as
-- `meter_comm`.
--
-- Resolution note: 4088 is 1 W per LSB against the PCS power registers'
-- 100 W (8047/8056 are int16 at 0.1 kW), so on a de-rated SvK run the
-- meter is the finer scoring signal by two orders of magnitude.
--
-- ── SLEW (ported verbatim in behaviour from the Solis driver) ────────
-- Testprogram FFR v1.6 §1.4 Tabell 3 caps deactivation for **kort
-- uthållighet** at 20 % of contracted capacity per second. The PCS
-- has no inbuilt deactivation ramp, so the driver enforces it:
-- activation / hold / direction-up-in-magnitude write immediately;
-- deactivation is registered and stepped down by `driver_poll` at
-- `ffr_slew_rate_pct_per_s`. `init` and `deinit` BYPASS the slew —
-- safe-revert must reach 0 W instantly. Default is effectively
-- unbounded (100000 %/s); the SvK runner constrains it per test via
-- `driver_command("set_slew_rate", pct)`.

PROTOCOL = "modbus"

DRIVER = {
    host_api_min = 1,
    host_api_max = 1,
    id = "konja-261-svk",
    name = "Konja MG 261 kWh / 125 kW C&I BESS (SvK)",
    manufacturer = "Konja Power",
    version = "0.3.0",
    protocols = { "modbus" },
    capabilities = { "battery", "meter" },
    read_only = false,
    description = "Konja Power MG-series 261 kWh liquid-cooled cabinet with MG500 EMS + Enjoy Power 125 kW PCS, Modbus TCP; SvK fast-frequency battery control.",
    authors = { "David and Blixt L1 contributors", "Sourceful contributors" },
    tested_models = { "MG-261" },
    verification_status = "experimental",
    verification_notes = "Migrated from the Blixt L1 device-support registry; source has run on hardware under Blixt L1 but no HIL record exists in this repository yet.",
    connection_defaults = {
        port = 1502, unit_id = 1,
    },
}

DRIVER_MANIFEST = {
    name    = "konja-261-svk",
    version = "0.3.0",
    role    = "battery",

    -- 20 Hz. SvK FFR §2 Tabell 5 wants 0.1 s logging resolution and
    -- the l1 snapshot feeds the SOC / UtsignalStyrenhet_W columns of
    -- the session CSV — at exactly 100 ms any jitter drops 0.1 s bins,
    -- so leave headroom. Each poll is 3 × FC04 over TCP (PCS, BMS,
    -- meter — the meter block was added in 0.3.0). Command
    -- latency does NOT depend on this: l1's mid-poll preempt
    -- dispatches a pending SetpointWrite between register bundles.
    -- Raise it per-device if the EMS objects to the rate
    -- (see OPEN QUESTION 1).
    poll_interval_ms = 50,

    requires = {
        { name    = "battery_capacity_wh",
          purpose = "control",
          type    = "integer", min = 1000, max = 1000000,
          help    = "Total usable LFP capacity of the cabinet (Wh). " ..
                    "Nameplate for the 261 kWh unit is 261000. Not " ..
                    "reliably on the bus; configured per install. Used " ..
                    "to derive charge / discharge energy headroom (Wh)." },
        { name    = "battery_soc_min_pct",
          purpose = "control",
          type    = "integer", min = 0, max = 100,
          help    = "Floor for discharge — arbitrator vetoes setpoints " ..
                    "that would drive SoC below this percentage." },
        { name    = "battery_soc_max_pct",
          purpose = "control",
          type    = "integer", min = 0, max = 100,
          help    = "Ceiling for charge — arbitrator vetoes setpoints " ..
                    "that would drive SoC above this percentage." },
    },

    options = {
        { name    = "battery_rated_w",
          purpose = "control",
          type    = "integer", min = 1000, max = 200000,
          help    = "Max continuous charge / discharge power (W, " ..
                    "magnitude). Nameplate for this cabinet is 125000. " ..
                    "Cap on |setpoint| regardless of what the PCS " ..
                    "reports. When unset the driver falls back to PCS " ..
                    "reg 8256 (Maximum Discharging Power), then to " ..
                    "capacity_wh × battery_max_c_rate." },
        { name    = "battery_max_c_rate",
          purpose = "control",
          type    = "double",  default = 1.0, min = 0.1, max = 5.0,
          help    = "Battery max C-rate. Fallback magnitude cap when " ..
                    "battery_rated_w is unset and the PCS rating is " ..
                    "unreadable (capacity_wh × c_rate)." },
        { name    = "pv_shares_ac_stage",
          purpose = "control",
          type    = "boolean", default = false,
          help    = "Hybrid topology flag. FALSE for this cabinet — " ..
                    "the 261 kWh unit has no PV on the PCS AC stage, " ..
                    "so battery power never contends with PV." },
        { name    = "ffr_slew_rate_pct_per_s",
          purpose = "control",
          type    = "double",  default = 100000.0, min = 1.0, max = 100000.0,
          help    = "Max DEACTIVATION slew rate as % of " ..
                    "|setpoint_cap_w| per second. Applied only when " ..
                    "|new_setpoint| < |current_setpoint|. Activation, " ..
                    "hold and direction-up-in-magnitude bypass it and " ..
                    "write immediately; init() / deinit() also bypass " ..
                    "— safe-revert must reach 0 W instantly. Default " ..
                    "is no enforcement (100000 %/s) so the driver is " ..
                    "market-agnostic; SvK FFR §1.4 Tabell 3 kort " ..
                    "uthållighet caps deact at 20 %/s and the runner " ..
                    "sets it via driver_command('set_slew_rate', 15)." },
    },

    provides = {
        live   = { "battery.W", "battery.SoC_nom_fract",
                   "battery.available_charge_Wh", "battery.available_discharge_Wh",
                   "battery.available_charge_W", "battery.available_discharge_W",
                   "battery.V", "battery.A", "battery.temperature_C",
                   "inverter.W", "inverter.Hz", "inverter.heatsink_C",
                   -- Cabinet ADL400 meter (0.3.0). Flat per-phase keys,
                   -- not `meter.lines[]` — the l1 MeterEmit struct is
                   -- flat and silently drops anything else.
                   "meter.W", "meter.Hz",
                   "meter.L1_V", "meter.L2_V", "meter.L3_V",
                   "meter.L1_A", "meter.L2_A", "meter.L3_A",
                   "meter.L1_W", "meter.L2_W", "meter.L3_W",
                   "meter.total_import_Wh", "meter.total_export_Wh" },
        static = { "rated_W", "make", "model", "sn" },
    },
}

PROTOCOL = "modbus"

-- ── Register map (all literal, from the V1.16 workbook) ──────────────
-- Grouped into tables rather than flat locals on purpose: LuaJIT
-- (Lua 5.1, which is what l1 runs) caps a function at 60 upvalues,
-- and driver_poll referenced enough of these to blow the limit.
-- luac5.5 — which the registry validates with — allows 255 and so
-- compiles the flat form happily; only LuaJIT catches it. Tables cost
-- one upvalue each.
local R = {
    -- EMS holding (FC03 read / FC16 write) — control
    MODE_SETTING   = 300,   -- uint16, x100: 1 = Operating, 0 = Debug
    LOCAL_REMOTE   = 337,   -- uint16, x100: 1 = Remote
    EXT_CONTROL    = 343,   -- uint16, x100: 1 = External control on
    SLAVE_POWER    = 344,   -- float32 (344 hi, 345 lo), 0.01 kW, +discharge
    EMS_LIMITS     = 304,   -- float32 x4: max dis / max chg / min dis / min chg
    EMS_AUTH       = 301,   -- competing-authority block, 301..334
    -- EMS input (FC04)
    EMS_STATUS     = 0,     -- system/fault status block, 0..29
    -- PCS input (FC04) — fast telemetry block
    PCS            = 8034,  -- 8034..8063
    PCS_SN         = 8064,  -- 16 regs ASCII, 2 chars/reg
    -- PCS holding (FC03) — nameplate settings, read-only for us
    PCS_MAX_CHG_P  = 8255,  -- int16, 0.1 kW
    PCS_MAX_DIS_P  = 8256,  -- int16, 0.1 kW
    -- BMS input (FC04) — fast telemetry block
    BMS            = 2721,  -- 2721..2761
    -- Cabinet ADL400 meter input (FC04)
    MTR            = 4060,  -- 4060..4089, live V/A/Hz/W — every poll
    MTR_ENERGY     = 4010,  -- 4010..4021, lifetime fwd/rev Wh — slow path
}

-- Bundle lengths.
local N_EMS_AUTH   = 34   -- 301..334
local N_EMS_STATUS = 30   -- 0..29
local N_PCS        = 30   -- 8034..8063
local N_BMS        = 41   -- 2721..2761

-- Offsets inside the PCS bundle (1-based Lua index = addr - 8034 + 1)
local P = {
    HZ         = 8034 - R.PCS + 1,
    DERATE_K   = 8036 - R.PCS + 1,
    DERATE_FLG = 8037 - R.PCS + 1,
    AC_W       = 8047 - R.PCS + 1,
    BAT_V      = 8054 - R.PCS + 1,
    BAT_A      = 8055 - R.PCS + 1,
    DC_W       = 8056 - R.PCS + 1,
    OP_STATUS  = 8058 - R.PCS + 1,
    IGBT_C     = 8059 - R.PCS + 1,
    GRID_STATE = 8063 - R.PCS + 1,
}

-- Offsets inside the meter bundles, plus their lengths. Lengths live in
-- the table rather than as bare locals to stay clear of LuaJIT's
-- 60-upvalue-per-function limit (see the note on `R` above) — driver_poll
-- already carries a lot.
local M = {
    N          = 30,                -- 4060..4089
    N_ENERGY   = 12,                -- 4010..4021
    L1_V       = 4060 - 4060 + 1,   -- uint16, 0.1 V
    L2_V       = 4061 - 4060 + 1,
    L3_V       = 4062 - 4060 + 1,
    L1_A       = 4063 - 4060 + 1,   -- uint16, 0.01 A (unsigned magnitude)
    L2_A       = 4064 - 4060 + 1,
    L3_A       = 4065 - 4060 + 1,
    HZ         = 4066 - 4060 + 1,   -- uint16, 0.01 Hz
    L1_W       = 4082 - 4060 + 1,   -- int32 (hi at lower addr), 0.001 kW = 1 W
    L2_W       = 4084 - 4060 + 1,
    L3_W       = 4086 - 4060 + 1,
    TOTAL_W    = 4088 - 4060 + 1,
    FWD_WH     = 4010 - 4010 + 1,   -- uint32, 0.01 kWh = 10 Wh
    REV_WH     = 4020 - 4010 + 1,
}

-- Offsets inside the BMS bundle
local B = {
    SOC         = 2727 - R.BMS + 1,
    AVG_TEMP    = 2750 - R.BMS + 1,
    CHG_DIS_ST  = 2751 - R.BMS + 1,
    OP_STATUS   = 2752 - R.BMS + 1,
    FORBIDDEN   = 2755 - R.BMS + 1,
    FAULT_ST    = 2756 - R.BMS + 1,
    MAX_CHG_P   = 2758 - R.BMS + 1,  -- uint32 (2758 hi, 2759 lo), 0.1 kW
    MAX_DIS_P   = 2760 - R.BMS + 1,  -- uint32 (2760 hi, 2761 lo), 0.1 kW
}

-- EMS scalar registers use a documented ×100 scaling ("EMS External
-- Control Steps (All Scaling Factors = 100)").
local EMS_SCALE = 100

-- ── State ────────────────────────────────────────────────────────────
local rated_w = 0
local control_initialized = false

local battery_rated_w     = 0
local battery_capacity_wh = 0
local soc_min_pct = 0
local soc_max_pct = 100
local battery_max_c_rate = 1.0

local ffr_slew_rate_pct_per_s_default = 100000.0
local ffr_slew_rate_pct_per_s         = 100000.0

local slew_target_w    = 0
local slew_committed_w = 0
local slew_last_write_ms = 0
local self_heal_prev_committed_w = 0
-- host.now_ms() at which the current run of disagreement started; 0 =
-- no disagreement in progress. Wall-clock, not a poll count — see the
-- self-heal block in driver_poll.
local self_heal_disagree_since_ms = 0
local last_commanded_w = 0

local last_good_soc_pct = nil
local soc_invalid_polls = 0

local SELF_HEAL_FLOOR_W      = 1000   -- 0.8 % of a 125 kW cabinet
-- Wall-clock dwell before self-heal acts. Longer than every SvK
-- activation requirement (FFR C-tier 0.70 s; FCR-D Req 2 is 86 % in
-- 7.5 s but the setpoint itself steps immediately), so a slow EMS
-- cannot make the driver intervene mid-activation.
local SELF_HEAL_MIN_DISAGREE_MS = 3000
local MAX_BUDGET_ELAPSED_MS  = 1000   -- SvK FFR 1.6 §1.4 measurement window

local poll_count = 0
local SLOW_STATUS_EVERY_POLLS = 200   -- ~10 s at 50 ms
local last_ems_status_word = nil
local last_bms_status_word = nil
local last_pcs_status_word = nil

local avail_charge_w, avail_discharge_w = nil, nil

-- ---------------------------------------------------------------------
-- Sign convention — the ONLY place the flip happens.
-- Konja: + = discharge, − = charge.  Sourceful: − = discharge, + = charge.
--
-- SOURCING, precisely:
--   * For the SETPOINT this is stated outright — EMS sheet r63 reg 344
--     "Negative for Charging, Positive for Discharging", and the same
--     wording on PCS 8202 (r91) and 8211 (r100). Solid.
--   * For the READBACK registers (PCS 8047 Total AC Output Active
--     Power, 8056 DC Power, 8055 Battery Current) the workbook's
--     Description column is EMPTY. The sign is NOT stated anywhere.
--     We apply the same +discharge convention, which is the only
--     self-consistent reading — but it is an INFERENCE, not a fact.
--     BMS 2751 (r748) corroborates it for current: it defines
--     "Charging: ... Current < -1A; Discharging: ... Current > 1A".
--
-- The inference is confined to telemetry — it cannot move the battery.
-- `check_readback_sign` below cross-checks it live against a commanded
-- direction and logs loudly on contradiction. It NEVER auto-corrects:
-- silently flipping a sign because a reading disagreed is how you turn
-- a wiring question into an uncommanded charge. See OPEN QUESTION Q3.
-- ---------------------------------------------------------------------
local function k2s(konja_w) return -konja_w end   -- Konja  → Sourceful
local function s2k(srcful_w) return -srcful_w end -- Sourceful → Konja

local sign_check_done = false
local function check_readback_sign(commanded_srcful_w, measured_srcful_w)
    if sign_check_done then return end
    -- Only meaningful once we are commanding a decisive magnitude and
    -- the cabinet has clearly responded.
    if math.abs(commanded_srcful_w) < 2000 then return end
    if math.abs(measured_srcful_w) < math.abs(commanded_srcful_w) * 0.5 then return end
    sign_check_done = true
    local same = (commanded_srcful_w > 0) == (measured_srcful_w > 0)
    if same then
        host.log(string.format(
            "sign check PASSED: commanded %+dW, measured %+.0fW — the assumed " ..
            "'+ = discharge' convention on the readback registers holds (Q3 settled).",
            commanded_srcful_w, measured_srcful_w))
    else
        host.log(string.format(
            "*** SIGN CHECK FAILED *** commanded %+dW but measured %+.0fW — the " ..
            "readback registers (8047/8056/8055) appear to use the OPPOSITE sign " ..
            "to the setpoint register. Telemetry is being reported inverted. " ..
            "NOT auto-correcting. Stop testing and resolve OPEN QUESTION Q3 before " ..
            "trusting any SvK result from this run.",
            commanded_srcful_w, measured_srcful_w))
    end
end

-- ---------------------------------------------------------------------
-- Cabinet meter state (0.3.0). One table = one upvalue in driver_poll.
--
--   import_wh / export_wh   lifetime counters, refreshed on the slow
--                           path and re-emitted every poll so the field
--                           does not blink in and out of the snapshot.
--   baseline_w              meter reading last seen while the cabinet
--                           was committed to 0 W — the reference for
--                           the placement/sign verdict.
--   verdict_done            the verdict is one-shot; it answers a
--                           question about the installation, which does
--                           not change while the driver is loaded.
--   dead_logged             so a missing meter logs once, not at 20 Hz.
-- ---------------------------------------------------------------------
local MS = {
    import_wh = nil,
    export_wh = nil,
    baseline_w = nil,
    verdict_done = false,
    dead_logged = false,
}

-- Answer, from live data, the two things the workbook does not state
-- about reg 4088: WHERE the CT is, and WHICH SIGN is import.
--
-- Method: baseline the meter while the cabinet is committed to 0 W,
-- then on the first decisive setpoint that the PCS has visibly
-- delivered, compare the meter's movement against that delivery.
--   * |delta| ≈ |delivered| and SAME sign  → CT is at the grid
--     connection and + = import. Both assumptions hold.
--   * |delta| ≈ |delivered| and OPPOSITE   → CT is at the grid but the
--     meter signs + = export. Emitted power is inverted.
--   * |delta| ≈ 0                          → the CT does not see the
--     cabinet's own power, so it is NOT at the grid connection (or is
--     on a different feeder). The emit must not be used as the site
--     grid meter.
--
-- Never auto-corrects. `commanded`/`delivered` are Sourceful-signed
-- (− = discharge/export), which is the same axis the meter uses once
-- the +import reading is right, so a matching sign is the pass case.
local function check_meter_placement(committed_w, delivered_w, meter_w)
    if MS.verdict_done or meter_w == nil or delivered_w == nil then return end
    if committed_w == 0 then
        MS.baseline_w = meter_w          -- keep it fresh while idle
        return
    end
    if math.abs(committed_w) < 2000 then return end
    if MS.baseline_w == nil then return end
    -- Wait until the cabinet has actually moved, or we would be
    -- measuring the EMS's propagation delay instead of the CT.
    if math.abs(delivered_w) < math.abs(committed_w) * 0.5 then return end

    MS.verdict_done = true
    local delta = meter_w - MS.baseline_w
    local mag   = math.abs(delivered_w)
    if math.abs(delta) < mag * 0.3 then
        host.log(string.format(
            "*** METER PLACEMENT: CT IS NOT AT THE GRID CONNECTION *** cabinet " ..
            "delivered %+.0fW but the meter (4088) moved only %+.0fW from its " ..
            "%.0fW idle baseline. The ADL400 does not see the cabinet's own " ..
            "power, so this emit must NOT be the site grid meter — set " ..
            "site.grid_meter_device to a real grid meter in the dashboard. " ..
            "Settles OPEN QUESTION Q9.",
            delivered_w, delta, MS.baseline_w))
    elseif (delta > 0) == (delivered_w > 0) then
        host.log(string.format(
            "meter placement/sign PASSED: cabinet delivered %+.0fW and the meter " ..
            "(4088) moved %+.0fW from its %.0fW idle baseline — the CT IS at the " ..
            "grid connection and '+ = import' holds, so meter.ac_W is emitted " ..
            "un-negated and is safe as the site grid meter. Settles Q9 and Q10.",
            delivered_w, delta, MS.baseline_w))
    else
        host.log(string.format(
            "*** METER SIGN INVERTED *** cabinet delivered %+.0fW but the meter " ..
            "(4088) moved %+.0fW from its %.0fW idle baseline — reg 4088 signs " ..
            "'+ = EXPORT', the opposite of the Forward/Reverse energy registers " ..
            "and of Sourceful. meter.ac_W is currently reported INVERTED and is " ..
            "feeding fuse/export protection with the wrong sign. NOT " ..
            "auto-correcting: stop, confirm with Konja (Q10), and ship a driver " ..
            "version that negates.",
            delivered_w, delta, MS.baseline_w))
    end
end

-- ---------------------------------------------------------------------
-- Decoding helpers
-- ---------------------------------------------------------------------
local function s16(reg)
    if reg == nil then return nil end
    if reg >= 32768 then return reg - 65536 end
    return reg
end

local function u32_be(hi, lo)
    if hi == nil or lo == nil then return nil end
    return hi * 65536 + lo
end

-- Signed 32-bit, high word at the LOWER Modbus address — the rule the
-- Instruction sheet states explicitly for int32 (r4) and uint32 (r6).
local function i32_be(hi, lo)
    if hi == nil or lo == nil then return nil end
    local raw = hi * 65536 + lo
    if raw >= 2147483648 then raw = raw - 4294967296 end
    return raw
end

-- IEEE-754 binary32 → words. The workbook's data-type note says
-- 32-bit values put "the high word at the lower Modbus address", so
-- 344 = bits 31..16 and 345 = bits 15..0.
--
-- Hand-rolled because the runtime is LuaJIT (Lua 5.1) — no
-- `string.pack`. It also avoids `math.frexp`, which exists in 5.1 but
-- was removed in Lua 5.4/5.5 — and the registry validates uploads by
-- compiling them with `luac55`. Plain arithmetic works in every
-- version. Verified against the workbook's own worked example:
-- 5000.0 → 0x459C 0x4000.
local function f32_to_words(x)
    if x ~= x then return 0x7FC0, 0x0000 end            -- NaN
    if x == 0 then return 0, 0 end
    local sign = 0
    if x < 0 then sign = 1; x = -x end
    if x == math.huge then return sign * 32768 + 0x7F80, 0 end
    -- Normalise to mant in [1, 2) with x = mant * 2^expo.
    local expo = 0
    while x >= 2 do x = x / 2; expo = expo + 1 end
    while x < 1 do x = x * 2; expo = expo - 1 end
    local e = expo + 127                                -- IEEE biased exponent
    local frac = math.floor((x - 1) * 8388608 + 0.5)    -- 23-bit mantissa
    if frac >= 8388608 then frac = frac - 8388608; e = e + 1 end
    if e <= 0 then return sign * 32768, 0 end            -- flush subnormal → ±0
    if e >= 255 then e = 254; frac = 8388607 end         -- clamp to ±FLT_MAX
    local hi = sign * 32768 + e * 128 + math.floor(frac / 65536)
    local lo = frac % 65536
    return hi, lo
end

local function f32_from_words(hi, lo)
    if hi == nil or lo == nil then return nil end
    if type(host.decode_f32_be) == "function" then
        local ok, v = pcall(host.decode_f32_be, hi, lo)
        if ok then return v end
    end
    local sign = (hi >= 32768) and -1 or 1
    local e = math.floor((hi % 32768) / 128)
    local frac = (hi % 128) * 65536 + lo
    if e == 0 then return sign * frac * 2 ^ (-149) end
    if e == 255 then return sign * math.huge end
    return sign * (1 + frac / 8388608) * 2 ^ (e - 127)
end

local function now_ms()
    if type(host.now_ms) == "function" then
        local ok, v = pcall(host.now_ms)
        if ok and type(v) == "number" then return v end
    end
    return 0
end

-- ---------------------------------------------------------------------
-- Write helpers
-- ---------------------------------------------------------------------
local function write_u16(label, addr, value)
    local u = value
    if u < 0 then u = u + 0x10000 end
    u = u % 0x10000
    local ok = pcall(host.write, addr, u)
    if ok then
        host.log(string.format("[%s] reg %d = %d", label, addr, value))
        return true
    end
    host.log(string.format("[%s] FAIL reg %d = %d", label, addr, value))
    return false
end

-- Write the float32 setpoint as one FC16 of 2 registers — atomic on
-- the wire, so the EMS can never latch a half-updated value.
local function write_setpoint_konja_w(label, konja_w)
    -- Register unit is 0.01 kW → the float carries watts / 10.
    local scaled = konja_w / 10.0
    local hi, lo = f32_to_words(scaled)
    local ok = pcall(host.write_registers, R.SLAVE_POWER, { hi, lo })
    if ok then
        host.log(string.format(
            "[%s] FC16 reg %d..%d = %.2f (%.3f kW, konja %+dW) hi=0x%04X lo=0x%04X",
            label, R.SLAVE_POWER, R.SLAVE_POWER + 1, scaled,
            konja_w / 1000.0, konja_w, hi, lo))
        return true
    end
    host.log(string.format("[%s] FC16 setpoint FAILED (konja %+dW)", label, konja_w))
    return false
end

-- ---------------------------------------------------------------------
-- Caps + slew budget
-- ---------------------------------------------------------------------
local function setpoint_cap_w()
    if battery_rated_w > 0 then return battery_rated_w end
    if rated_w > 0 then return rated_w end
    if battery_capacity_wh > 0 then
        return math.floor(battery_capacity_wh * battery_max_c_rate)
    end
    return 0
end

local function slew_step_budget_w(elapsed_ms)
    local cap = setpoint_cap_w()
    if cap <= 0 then return math.huge end
    if elapsed_ms < 0 then elapsed_ms = 0 end
    if elapsed_ms > MAX_BUDGET_ELAPSED_MS then elapsed_ms = MAX_BUDGET_ELAPSED_MS end
    return cap * (ffr_slew_rate_pct_per_s / 100.0) * (elapsed_ms / 1000.0)
end

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
    host.set_make("Konja Power")
    host.set_model("MG-261 (MG500 EMS + Enjoy 125 kW PCS)")

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
        host.log(string.format("config: ffr_slew_rate_pct_per_s = %.2f %%/s (default)",
                               ffr_slew_rate_pct_per_s))
    end
    host.log("config: SoC band = " .. soc_min_pct .. "%-" .. soc_max_pct .. "%")

    -- SN: PCS Module SN Code, 8064..8079. "Each word represents two
    -- letters; high byte = 1st letter, low byte = 2nd letter" — exactly
    -- host.decode_string's layout. Retry 3× like the Solis driver: a
    -- fresh TCP connect to the EMS can drop the first request.
    local sn = nil
    for attempt = 1, 3 do
        local ok_sn, sn_regs = pcall(host.modbus_read, R.PCS_SN, 16, "input")
        if ok_sn and sn_regs then
            sn = host.decode_string(sn_regs, 1, 16)
            if sn and #sn > 0 then break end
        end
        host.log("SN read attempt " .. attempt .. " failed, retrying...")
        host.sleep(500)
        sn = nil
    end
    if not sn or #sn == 0 then
        -- Unlike Solis we do NOT hard-fail here: the PCS SN block is
        -- proxied by the EMS and may be blank on a cabinet whose PCS
        -- has not finished handshaking. Telemetry + control do not
        -- depend on it, and provides.static only needs *a* value.
        host.log("WARN: PCS SN block (8064-8079) unreadable/blank — using placeholder")
        sn = "KONJA-261-UNKNOWN"
    end
    host.set_sn(sn)
    host.log("SN: " .. sn)

    -- PCS 8255/8256 are "Maximum Charging / Discharging Power",
    -- Read/WRITE settings (PCS sheet r144/r145) — a CONFIGURED LIMIT,
    -- not a nameplate rating. The workbook exposes no nameplate power
    -- register anywhere, so we do NOT derive `rated_w` from them: an
    -- installer who set 8256 to 60 kW would silently halve every SvK
    -- test magnitude. They are read only to warn when a limit sits
    -- below our cap (below).
    local ok_r, rr = pcall(host.modbus_read, R.PCS_MAX_CHG_P, 2, "holding")
    if ok_r and rr then
        host.log(string.format(
            "PCS configured limits: max_charge=%.1fkW (8255) max_discharge=%.1fkW (8256) " ..
            "— settings, not nameplate",
            (s16(rr[1]) or 0) / 10.0, (s16(rr[2]) or 0) / 10.0))
    else
        host.log("WARN: PCS 8255-8256 (max charge/discharge power) unreadable")
    end

    -- Rated power comes from config, or from capacity x C-rate, or it
    -- is 0 and l1 fails closed. No bus-derived guess.
    if battery_rated_w > 0 then
        rated_w = battery_rated_w
    elseif battery_capacity_wh > 0 then
        rated_w = math.floor(battery_capacity_wh * battery_max_c_rate)
        host.log("rated_w not configured — falling back to capacity x C-rate")
    else
        rated_w = 0
        host.log("WARN: no battery_rated_w and no battery_capacity_wh — rated=0 " ..
                 "(fail-closed; l1 will clamp every setpoint to 0)")
    end
    host.set_rated_w(math.floor(rated_w))
    host.log("rated=" .. rated_w .. "W")

    -- What did reg 344/345 hold before we touched it? This is the
    -- evidence for whether the setpoint register is retentive (the
    -- workbook does not say — OPEN QUESTION Q11). A non-zero value
    -- here on a cold start means it IS retentive, and the
    -- seed-before-arm ordering in arm_external_control is load-bearing.
    local ok_sp, spr = pcall(host.modbus_read, R.SLAVE_POWER, 2, "holding")
    if ok_sp and spr and spr[1] and spr[2] then
        local held = f32_from_words(spr[1], spr[2])
        host.log(string.format(
            "reg 344/345 held hi=0x%04X lo=0x%04X on startup (decodes to %s reg-units " ..
            "= %.0f W if the assumed word order is right) — evidence for Q11 retentiveness",
            spr[1], spr[2], tostring(held), (held or 0) * 10))
    end

    -- Log the EMS's own power/SoC envelope. `Minimum Discharge Power`
    -- / `Minimum Charge Power` (308 / 310) are a potential dead-band:
    -- if non-zero the EMS may swallow the small setpoints that FCR-N
    -- linearity and aFRR tracking depend on. We only READ them — see
    -- OPEN QUESTION 2 before changing anything.
    local ok_l, lr = pcall(host.modbus_read, R.EMS_LIMITS, 8, "holding")
    if ok_l and lr then
        local max_dis = f32_from_words(lr[1], lr[2])
        local max_chg = f32_from_words(lr[3], lr[4])
        local min_dis = f32_from_words(lr[5], lr[6])
        local min_chg = f32_from_words(lr[7], lr[8])
        host.log(string.format(
            "EMS power envelope: max_dis=%.2fkW max_chg=%.2fkW min_dis=%.2fkW min_chg=%.2fkW",
            (max_dis or 0) / 100, (max_chg or 0) / 100,
            (min_dis or 0) / 100, (min_chg or 0) / 100))
        if (min_dis or 0) > 0 or (min_chg or 0) > 0 then
            host.log("WARN: EMS minimum charge/discharge power is NON-ZERO — " ..
                     "small setpoints may be swallowed (FCR-N linearity risk)")
        end
    else
        host.log("WARN: EMS 304-311 (power envelope) unreadable")
    end

    -- Max-power envelope vs. our own cap. If the EMS ceiling is below
    -- the setpoint cap, every SvK activation is silently clipped and
    -- the test fails the magnitude requirement with nothing in the log
    -- to explain it. Same for the PCS's own 8255/8256.
    local cap = setpoint_cap_w()
    local function warn_ceiling(what, ceiling_w)
        if ceiling_w and ceiling_w > 0 and cap > 0 and ceiling_w < cap then
            host.log(string.format(
                "WARN: %s = %.1fkW is BELOW the setpoint cap %.1fkW — " ..
                "SvK activations will be clipped", what, ceiling_w / 1000, cap / 1000))
        end
    end
    if ok_l and lr then
        warn_ceiling("EMS 304 max discharge", (f32_from_words(lr[1], lr[2]) or 0) * 10)
        warn_ceiling("EMS 306 max charge",    (f32_from_words(lr[3], lr[4]) or 0) * 10)
    end
    if ok_r and rr then
        warn_ceiling("PCS 8255 max charge",    math.abs(s16(rr[1]) or 0) * 100)
        warn_ceiling("PCS 8256 max discharge", math.abs(s16(rr[2]) or 0) * 100)
    end

    -- ── Competing EMS authority ────────────────────────────────────
    -- Any of these can quietly override or veto our external-control
    -- setpoint. Anti-reverse current (328) is the dangerous one: if
    -- it is active the EMS limits EXPORT, and every FFR / FCR-D
    -- DISCHARGE test returns a flat zero response that looks like a
    -- driver fault. We only READ and warn — see OPEN QUESTION A
    -- before writing any of them.
    local ok_a, ar = pcall(host.modbus_read, R.EMS_AUTH, N_EMS_AUTH, "holding")
    if ok_a and ar then
        local function at(addr) return ar[addr - R.EMS_AUTH + 1] end
        local competing = {
            { 328, "anti-reverse current (limits EXPORT — would zero every discharge test)" },
            { 331, "demand control (peak-shaving competes for the setpoint)" },
            { 334, "demand discharge" },
            { 303, "protection strategy" },
        }
        for _, c in ipairs(competing) do
            local v = at(c[1])
            if v and v ~= 0 then
                host.log(string.format(
                    "WARN: EMS reg %d ACTIVE (=%d) — %s", c[1], v, c[2]))
            end
        end
        local grid_mode = at(301)
        if grid_mode and grid_mode ~= 1 * EMS_SCALE and grid_mode ~= 1 then
            host.log(string.format(
                "WARN: EMS 301 grid-connected/islanded = %d (want grid-connected)", grid_mode))
        end
        -- SoC envelope + hysteresis: precision 0.0001 ⇒ raw 9500 = 95 %.
        local smax, smin = at(312), at(313)
        local hmax, hmin = at(314), at(315)
        host.log(string.format(
            "EMS SoC envelope: max=%.1f%% min=%.1f%% hysteresis(max/min)=%.1f/%.1f%%",
            (smax or 0) / 100, (smin or 0) / 100, (hmax or 0) / 100, (hmin or 0) / 100))
        if smax and smin then
            if smax / 100 < soc_max_pct or smin / 100 > soc_min_pct then
                host.log(string.format(
                    "WARN: EMS SoC band %.1f-%.1f%% is NARROWER than the configured " ..
                    "%d-%d%% — the EMS will clamp before the arbitrator does " ..
                    "(endurance tests will stop early)",
                    (smin or 0) / 100, (smax or 0) / 100, soc_min_pct, soc_max_pct))
            end
        end
    else
        host.log("WARN: EMS 301-334 (competing authority block) unreadable")
    end

    -- ── Cabinet meter (0.3.0) ──────────────────────────────────────
    -- Read it once here so the log carries the idle reading, the phase
    -- voltages, and — most importantly — the standing warning about
    -- what emitting `meter` from a CONTROLLABLE device means in l1.
    local ok_m, mr = pcall(host.modbus_read, R.MTR, M.N, "input")
    if ok_m and mr then
        local v1 = (mr[M.L1_V] or 0) / 10.0
        local v2 = (mr[M.L2_V] or 0) / 10.0
        local v3 = (mr[M.L3_V] or 0) / 10.0
        local tw = i32_be(mr[M.TOTAL_W], mr[M.TOTAL_W + 1])
        host.log(string.format(
            "cabinet meter (ADL400 @ 4060-4089): %.1f/%.1f/%.1f V, %.2f Hz, " ..
            "total active power (4088) = %s W",
            v1, v2, v3, (mr[M.HZ] or 0) / 100.0, tostring(tw)))
        if v1 <= 0 and v2 <= 0 and v3 <= 0 then
            host.log("WARN: cabinet meter reads 0 V on all three phases — the " ..
                     "ADL400 is absent or not communicating (check EMS reg 13, " ..
                     "meter_comm). `meter` will NOT be emitted.")
        else
            host.log("NOTE: this driver emits `meter` from a CONTROLLABLE device. " ..
                     "In l1 that becomes the SITE GRID METER (feeding the fuse " ..
                     "clamp and export protection) unless site.meter or " ..
                     "site.grid_meter_device names something else — pick the " ..
                     "intended grid meter in the dashboard. Reg 4088 is emitted " ..
                     "UN-NEGATED (+ = import); the placement/sign verdict is " ..
                     "logged on the first decisive setpoint.")
        end
    else
        host.log("WARN: cabinet meter block 4060-4089 unreadable — no `meter` emit")
    end

    host.set_warmup_s(2)
    return true
end

-- ---------------------------------------------------------------------
-- Control init — put the EMS under external control and zero output.
-- BYPASSES slew: init MUST take the cabinet to 0 W immediately.
-- Order is exactly the workbook's "EMS External Control Steps".
-- ---------------------------------------------------------------------
-- ── Setpoint encoding self-test ──────────────────────────────────────
-- The workbook does NOT state two things we must know before writing a
-- power setpoint, so we MEASURE them instead of assuming:
--
--   (1) FLOAT WORD ORDER. Instruction sheet r4/r6 state "the high word
--       is located at the lower Modbus address" for int32 and uint32.
--       Row 7, `float`, says only "32-bit word, in IEEE-754
--       floating-point format" — it does NOT repeat the word-order
--       rule. Assuming it carries over is a guess.
--   (2) WHICH FUNCTION CODE WRITES. The Instruction sheet's legend is
--       demonstrably wrong ("03H = Read multiple input registers",
--       "04H = Write coil registers" — both mislabelled), so its write
--       entries (05H/06H/10H) cannot be trusted either.
--
-- Both are observable, because reg 344 is Read/Write (EMS sheet r63)
-- and the YT block is readable with FC03. So: write a known value,
-- read it back, decode it, and require a match.
--
-- SAFETY OF THE PROBE: it runs while External Control (343) is still
-- 0, i.e. before the EMS has authority to apply any setpoint at all
-- (the workbook's "EMS External Control Steps" makes engaging 343 a
-- prerequisite, step 2, for the setpoint in step 4). The probe value
-- is 1.0 in register units = 0.01 kW = **10 W**, so even if the EMS
-- did apply it, it is 0.008 % of the cabinet rating. The probe always
-- writes 0 back before returning.
--
-- If the probe does NOT confirm, the driver refuses to arm and stays
-- telemetry-only. Fail closed — never write a power setpoint whose
-- encoding we have not verified on this specific unit.
local PROBE_REG_UNITS = 1.0        -- 0.01 kW = 10 W
local encoding_verified = false

local function verify_setpoint_encoding()
    local want_hi, want_lo = f32_to_words(PROBE_REG_UNITS)
    host.log(string.format(
        "encoding self-test: writing %.2f reg-units (=%.0f W) to %d/%d as hi=0x%04X lo=0x%04X",
        PROBE_REG_UNITS, PROBE_REG_UNITS * 10, R.SLAVE_POWER, R.SLAVE_POWER + 1,
        want_hi, want_lo))

    local ok_w = pcall(host.write_registers, R.SLAVE_POWER, { want_hi, want_lo })
    if not ok_w then
        host.log("encoding self-test FAILED: could not write 344/345 (FC16 rejected). " ..
                 "Control DISABLED — driver stays telemetry-only.")
        return false
    end

    local ok_r, rr = pcall(host.modbus_read, R.SLAVE_POWER, 2, "holding")
    if not ok_r or not rr or rr[1] == nil or rr[2] == nil then
        host.log("encoding self-test FAILED: could not read back 344/345 (FC03). " ..
                 "Control DISABLED — driver stays telemetry-only.")
        return false
    end

    host.log(string.format("encoding self-test: read back hi=0x%04X lo=0x%04X",
                           rr[1], rr[2]))
    pcall(host.write_registers, R.SLAVE_POWER, { 0, 0 })   -- always leave at 0

    if rr[1] == want_hi and rr[2] == want_lo then
        host.log("encoding self-test PASSED: IEEE-754 big-endian, high word at " ..
                 "the lower address, FC16 write / FC03 read confirmed on this unit.")
        return true
    end

    -- Diagnose the most likely alternative so the report writes itself.
    local swapped = f32_from_words(rr[2], rr[1])
    if rr[1] == want_lo and rr[2] == want_hi then
        host.log(string.format(
            "encoding self-test FAILED: words are SWAPPED (low word at the lower " ..
            "address). The driver's f32_to_words assumes the int32/uint32 rule. " ..
            "Control DISABLED — do not guess; confirm with Konja (question Q8), " ..
            "then ship a driver version that swaps. (swapped decode = %s)",
            tostring(swapped)))
    else
        host.log(string.format(
            "encoding self-test FAILED: read back neither the written words nor " ..
            "their swap — reg 344/345 may not be plain IEEE-754, or the EMS " ..
            "rewrites it. Control DISABLED. Report both word pairs to Konja."))
    end
    return false
end

-- `konja_w` is the value the cabinet should be running at the instant
-- external control engages.
--
-- SETPOINT FIRST. The workbook's "EMS External Control Steps" lists the
-- setpoint last (step 4, after engaging 343 in step 2). We deliberately
-- deviate, and seed the setpoint first as well.
--
-- WHY, stated honestly: the workbook does NOT say whether reg 344/345
-- is retentive across a power cycle or an external-control disengage.
-- We do not know that it is. But if it IS, then engaging 343 while 344
-- still holds a stale value from an unclean stop (l1 SIGKILLed
-- mid-discharge, no `deinit`) would apply that value the instant
-- authority is granted — a full-power event we would then be two
-- round-trips away from correcting. Seeding first costs one extra FC16
-- and is harmless if the register turns out to be volatile. This is a
-- defence against an unknown, not a claim about the hardware.
-- `driver_init` logs what 344/345 actually held at startup, which is
-- the evidence that settles it. See OPEN QUESTION Q11.
local function arm_external_control(label, konja_w)
    label = label or "init"
    konja_w = konja_w or 0
    local ok = write_setpoint_konja_w(label .. "/pre-seed", konja_w)
    if ok then ok = write_u16(label, R.LOCAL_REMOTE, 1 * EMS_SCALE) end
    if ok then ok = write_u16(label, R.EXT_CONTROL,  1 * EMS_SCALE) end
    if ok then ok = write_u16(label, R.MODE_SETTING, 1 * EMS_SCALE) end
    if ok then ok = write_setpoint_konja_w(label .. "/confirm", konja_w) end
    return ok
end

local function arm_remote_mode()
    -- Verify the setpoint encoding on THIS unit before any write that
    -- could move power. Fail closed: no verification, no control.
    if not encoding_verified then
        encoding_verified = verify_setpoint_encoding()
    end
    if not encoding_verified then
        control_initialized = false
        host.log("INIT ABORTED: setpoint encoding unverified — refusing to arm. " ..
                 "Telemetry continues; control stays disabled until the encoding " ..
                 "is confirmed (OPEN QUESTION Q8).")
        return false
    end

    local ok = arm_external_control("init", 0)
    control_initialized = ok
    if ok then
        last_commanded_w = 0
        slew_target_w = 0
        slew_committed_w = 0
        slew_last_write_ms = now_ms()
        self_heal_disagree_since_ms = 0
        host.log("Sleeping 1000ms for EMS external control to settle")
        host.sleep(1000)
        local ok_v, vr = pcall(host.modbus_read, R.MODE_SETTING, 1, "holding")
        local ok_e, er = pcall(host.modbus_read, R.EXT_CONTROL, 1, "holding")
        host.log(string.format("post-arm readback: mode(300)=%s ext_ctrl(343)=%s",
            (ok_v and vr and tostring(vr[1])) or "?",
            (ok_e and er and tostring(er[1])) or "?"))
    else
        host.log("INIT FAIL: could not put EMS under external control")
    end
    return ok
end

-- ---------------------------------------------------------------------
-- Bundle reads with bounded retry.
--
-- The host counts every failed read against the poll and takes a driver
-- that fails forever offline — so a block the EMS never answers (an EMS
-- build without the ADL400 meter proxy, a PCS that is powered down) must
-- not be re-read every 50 ms for the life of the session. After
-- BUNDLE_MISSES_BEFORE_SKIP misses in a row a bundle is left alone.
--
-- Unlike an optional register on a string inverter, the PCS and BMS
-- blocks are what the control path measures against, so silencing them
-- permanently after one bus hiccup would blind self-heal for the rest of
-- the session. A skipped bundle is therefore re-probed once every
-- BUNDLE_RETRY_EVERY polls (≈ 5 s at 50 ms) — one failed read per 5 s
-- instead of 20 per second — and comes straight back the moment it
-- answers. Control-time reads (readback of 343 in self-heal, arm/deinit
-- sequences) stay on plain pcall: they run only when there is a reason.
-- ---------------------------------------------------------------------
local BUNDLE_MISSES_BEFORE_SKIP = 3
local BUNDLE_RETRY_EVERY        = 100
local bundle_misses = {}   -- addr → consecutive misses
local bundle_skips  = {}   -- addr → polls skipped since last probe

local function bundle_read(addr, count, kind, label)
    local misses = bundle_misses[addr] or 0
    if misses >= BUNDLE_MISSES_BEFORE_SKIP then
        local skipped = (bundle_skips[addr] or 0) + 1
        if skipped < BUNDLE_RETRY_EVERY then
            bundle_skips[addr] = skipped
            return false, nil
        end
        bundle_skips[addr] = 0   -- fall through: one probe
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

-- ---------------------------------------------------------------------
-- driver_poll — fast telemetry + deferred slew step + self-heal.
-- ---------------------------------------------------------------------
function driver_poll()
    poll_count = poll_count + 1

    local ok_p, pcs = bundle_read(R.PCS, N_PCS, "input", "PCS")
    local ok_b, bms = bundle_read(R.BMS, N_BMS, "input", "BMS")
    -- Third bundle since 0.3.0. If the EMS ever objects to the added
    -- round trip, decimate this one read (it is the only consumer of
    -- the meter block) rather than dropping the poll rate — the PCS and
    -- BMS blocks are what the control path depends on.
    local ok_m, mtr = bundle_read(R.MTR, M.N, "input", "meter")

    -- ── PCS block ──────────────────────────────────────────────────
    local ac_w, dc_w, hz, bat_v, bat_a, igbt_c = nil, nil, nil, nil, nil, nil
    if ok_p and pcs then
        local ac_raw = s16(pcs[P.AC_W])
        if ac_raw then ac_w = k2s(ac_raw * 100) end        -- 0.1 kW → W
        local dc_raw = s16(pcs[P.DC_W])
        if dc_raw then dc_w = k2s(dc_raw * 100) end        -- 0.1 kW → W
        local hz_raw = s16(pcs[P.HZ])
        if hz_raw and hz_raw > 0 then hz = hz_raw / 100.0 end
        local v_raw = s16(pcs[P.BAT_V])
        if v_raw then bat_v = v_raw / 10.0 end
        local a_raw = s16(pcs[P.BAT_A])
        if a_raw then bat_a = k2s(a_raw) / 10.0 end        -- 0.1 A, +discharge
        local t_raw = s16(pcs[P.IGBT_C])
        if t_raw then igbt_c = t_raw / 10.0 end

        -- PCS derating + grid state, logged on change. Thermal derate
        -- during a 15-minute FCR-D endurance run silently caps output;
        -- 8063 ~= 4 (grid-connected operation) explains a flat zero
        -- response. Both are already in the bundle — free to surface.
        local dk   = s16(pcs[P.DERATE_K]) or 4096
        local dflg = s16(pcs[P.DERATE_FLG]) or 0
        local gs   = pcs[P.GRID_STATE]
        local pw = string.format("derate=%d/4096 flag=%d op=0x%04X grid=%s",
            dk, dflg, pcs[P.OP_STATUS] or 0, tostring(gs))
        if pw ~= last_pcs_status_word then
            host.log("PCS status: " .. pw)
            if dflg ~= 0 then
                host.log(string.format(
                    "WARN: PCS DERATING active (flag=%d, factor %.3f) — " ..
                    "1=IGBT over-temp, 2=ambient, 3=both. Output is capped.",
                    dflg, dk / 4096.0))
            end
            if gs ~= nil and gs ~= 4 then
                host.log(string.format(
                    "WARN: PCS 8063 = %d, not 4 (grid-connected operation) — " ..
                    "0=shutdown 1=power-on 2=standby 3=off-grid 5=fault 6=debug", gs))
            end
            last_pcs_status_word = pw
        end
    end
    -- Battery DC power is the RT control axis. Reg 8056 is the direct
    -- reading at 0.1 kW; V × I from 8054/8055 is a finer-grained
    -- cross-check and the fallback when 8056 is missing.
    if dc_w == nil and bat_v and bat_a then
        -- Round to a whole watt. V and A each carry one decimal, so
        -- the product can have two — and `%d` on a non-integer float
        -- is a hard error in Lua 5.4/5.5 (LuaJIT silently truncates).
        -- Keeping every power value integral makes the log formats
        -- safe on both runtimes.
        dc_w = math.floor(bat_v * bat_a + 0.5)
    end
    dc_w = dc_w or 0

    -- ── BMS block ──────────────────────────────────────────────────
    local soc_pct = nil
    local bms_temp_c = nil
    if ok_b and bms then
        local soc_raw = bms[B.SOC]
        -- Workbook precision is 0.001 → raw 1000 = 100 %. Guard the
        -- alternative reading (raw = tenths of a percent) by range.
        if soc_raw and soc_raw > 0 and soc_raw <= 1000 then
            soc_pct = soc_raw / 10.0
        elseif soc_raw and soc_raw > 1000 and soc_raw <= 10000 then
            soc_pct = soc_raw / 100.0
            if poll_count % 200 == 1 then
                host.log("WARN: SoC raw " .. soc_raw .. " > 1000 — assuming 0.0001 scaling; verify with Konja")
            end
        end
        local t_raw = s16(bms[B.AVG_TEMP])
        if t_raw then bms_temp_c = t_raw / 10.0 end

        local chg_p = u32_be(bms[B.MAX_CHG_P], bms[B.MAX_CHG_P + 1])
        local dis_p = u32_be(bms[B.MAX_DIS_P], bms[B.MAX_DIS_P + 1])
        if chg_p then avail_charge_w    = chg_p * 100 end   -- 0.1 kW → W
        if dis_p then avail_discharge_w = dis_p * 100 end

        -- BMS charge/discharge FORBID gate (2755). Without this the
        -- arbitrator keeps dispatching into a direction the BMS has
        -- vetoed, the self-heal probe reports a permanent delivery
        -- shortfall, and nothing says why. Zeroing the matching
        -- availability makes the veto visible to the arbitrator.
        local forbid = bms[B.FORBIDDEN]
        if forbid == 0x55 then           -- charge forbidden
            avail_charge_w = 0
        elseif forbid == 0xCC then       -- discharge forbidden
            avail_discharge_w = 0
        elseif forbid == 0xAA then       -- both forbidden
            avail_charge_w, avail_discharge_w = 0, 0
        end

        -- Log the BMS state words on change only (cheap, and it is the
        -- first thing to look at when the cabinet will not move).
        local bw = string.format(
            "chg_dis=0x%02X op=0x%02X forbid=0x%02X fault=%s",
            bms[B.CHG_DIS_ST] or 0, bms[B.OP_STATUS] or 0,
            forbid or 0, tostring(bms[B.FAULT_ST]))
        if bw ~= last_bms_status_word then
            host.log("BMS status: " .. bw)
            last_bms_status_word = bw
        end
    end

    -- Hold the last GOOD SoC through invalid reads. Emitting 0 on a
    -- bad read tells every consumer "battery empty" — on the Solis rig
    -- that aborted an 18-test SvK endurance suite at a phantom 0 %.
    if soc_pct ~= nil then
        last_good_soc_pct = soc_pct
        soc_invalid_polls = 0
    elseif last_good_soc_pct ~= nil then
        soc_pct = last_good_soc_pct
        soc_invalid_polls = soc_invalid_polls + 1
        if soc_invalid_polls % 100 == 1 then
            host.log(string.format(
                "WARN: SoC read invalid for %d polls — holding last good %.1f%%",
                soc_invalid_polls, soc_pct))
        end
    end
    local bat_soc = soc_pct and (soc_pct / 100.0) or 0

    -- ── Slew step ──────────────────────────────────────────────────
    if control_initialized and slew_committed_w ~= slew_target_w then
        local now = now_ms()
        local elapsed_ms = (now > 0 and slew_last_write_ms > 0)
            and (now - slew_last_write_ms) or 0
        local max_step = slew_step_budget_w(elapsed_ms)
        local next_w = slew_next_w(slew_committed_w, slew_target_w, max_step)
        if next_w ~= slew_committed_w then
            -- max_step is math.huge when the cap is unknown (fail-open);
            -- math.floor(inf) is not integer-representable, so format
            -- it as a float to stay safe under Lua 5.4/5.5.
            host.log(string.format(
                "slew: %dW → %dW (target=%dW, step<=%.0fW, elapsed=%dms)",
                slew_committed_w, next_w, slew_target_w,
                max_step, elapsed_ms))
            if write_setpoint_konja_w("slew", s2k(next_w)) then
                slew_committed_w = next_w
                slew_last_write_ms = now > 0 and now or slew_last_write_ms
                last_commanded_w = next_w
            end
        end
    end

    -- ── Self-heal latch ────────────────────────────────────────────
    -- Sustained disagreement between the MEASURED power and a STABLE
    -- committed setpoint means one of three things, and only one of
    -- them is fixable by re-arming:
    --
    --   (a) the EMS dropped external control  → re-arm
    --   (b) the EMS HAS our setpoint but the PCS cannot deliver it
    --       (thermal derate, BMS forbid, SoC limit)  → re-arming does
    --       nothing except glitch the output; just log it
    --   (c) we simply failed to read  → do nothing at all
    --
    -- EMS reg 24/25 ("Strategy PCS Power", float, 0.01 kW) is the
    -- EMS's own view of the command it latched, so it separates (a)
    -- from (b) definitively. It is only read when a disagreement has
    -- already persisted, so it costs nothing on the happy path.
    --
    -- The dwell is WALL-CLOCK, not a poll count: `poll_interval_ms` is
    -- overridable per-device, and the EMS→PCS propagation delay is not
    -- yet known (OPEN QUESTION 1). A poll-count dwell of 0.6 s would
    -- fire *inside* an FFR activation window on a slow EMS and command
    -- the cabinet away mid-test. 3 s is longer than any SvK activation
    -- requirement (FFR C-tier is 0.70 s, FCR-D Req 2 is 7.5 s for 86 %)
    -- while still catching a real de-arm well inside a test.
    if control_initialized then
        -- (c) no valid measurement this poll ⇒ no evidence either way.
        if not (ok_p and pcs) then
            self_heal_disagree_since_ms = 0
        else
            local meas_w = ac_w or dc_w
            check_readback_sign(slew_committed_w, meas_w)
            local err_w = math.abs(meas_w - slew_committed_w)
            local tol_w = math.max(SELF_HEAL_FLOOR_W,
                                   math.abs(slew_committed_w) * 0.15)
            local stable = (slew_committed_w == self_heal_prev_committed_w)
                       and (slew_committed_w == slew_target_w)
            local now = now_ms()
            if err_w > tol_w and stable then
                if self_heal_disagree_since_ms == 0 then
                    self_heal_disagree_since_ms = now
                elseif (now - self_heal_disagree_since_ms) >= SELF_HEAL_MIN_DISAGREE_MS then
                    -- Do we still HAVE authority? Read reg 343 back.
                    --
                    -- This is the sourced way to ask the question: EMS
                    -- sheet r62 defines 343 as Read/Write with
                    -- "0: Not activated; 1: Activated". An earlier
                    -- revision probed reg 24 ("Strategy PCS Power")
                    -- instead, on the assumption that it mirrors the
                    -- latched external-control command — but the
                    -- workbook says nothing of the sort about reg 24,
                    -- and a self-heal that suppresses itself on an
                    -- unsourced reading is exactly the kind of guess
                    -- that leaves a cabinet stuck at the wrong power.
                    local have_authority = nil
                    local ok_ec, ecr = pcall(host.modbus_read, R.EXT_CONTROL, 1, "holding")
                    if ok_ec and ecr and ecr[1] ~= nil then
                        have_authority = (ecr[1] == 1 * EMS_SCALE) or (ecr[1] == 1)
                        host.log(string.format(
                            "self-heal probe: 343 External Control reads %d ⇒ authority=%s",
                            ecr[1], tostring(have_authority)))
                    else
                        host.log("self-heal probe: could not read 343 — assuming authority lost")
                    end

                    if have_authority == true then
                        -- (b) we still hold authority, so this is a
                        -- DELIVERY shortfall (derate / BMS forbid /
                        -- SoC limit), not an authority problem.
                        -- Re-arming cannot fix it and would only notch
                        -- the output. Rewrite the setpoint once in
                        -- case the EMS dropped just that register,
                        -- then back off for another dwell.
                        host.log(string.format(
                            "self-heal: authority intact (343=1) but only %.0fW of %dW " ..
                            "delivered — delivery shortfall (derate / BMS forbid / SoC). " ..
                            "Rewriting setpoint, NOT re-arming.",
                            meas_w, slew_committed_w))
                        if write_setpoint_konja_w("self-heal", s2k(slew_committed_w)) then
                            slew_last_write_ms = now
                        end
                    else
                        -- (a) authority lost (or unreadable) — re-arm.
                        -- Re-arm AT the committed setpoint; never via
                        -- a 0 W intermediate, which would be a visible
                        -- notch mid-activation.
                        host.log(string.format(
                            "self-heal: committed=%dW but measured=%.0fW for %.1fs — re-arm at setpoint",
                            slew_committed_w, meas_w,
                            (now - self_heal_disagree_since_ms) / 1000.0))
                        if arm_external_control("self-heal", s2k(slew_committed_w)) then
                            slew_last_write_ms = now
                        end
                    end
                    self_heal_disagree_since_ms = 0
                end
            else
                self_heal_disagree_since_ms = 0
            end
        end
        self_heal_prev_committed_w = slew_committed_w
    end

    -- ── Slow path: arm verification + EMS system/fault status ──────
    if poll_count == 1 or (poll_count % SLOW_STATUS_EVERY_POLLS) == 0 then
        -- Verify the cabinet is still under external control. The hot
        -- setpoint path is a single FC16 and deliberately does NOT
        -- re-assert 337/343/300 (see driver_command) — so a silent
        -- de-arm (operator touching the HMI, an EMS restart, the
        -- 3-minute comms watchdog having fired during a stall) would
        -- otherwise only surface via the self-heal latch, i.e. AFTER
        -- the delivered power had already diverged. During an FFR test
        -- that is a failed test.
        --
        -- READ first and only write the registers that are actually
        -- wrong: in the normal case this costs one FC03 every ~10 s
        -- and issues zero writes, so it can never perturb a running
        -- test by rewriting values that are already correct.
        if control_initialized then
            local ok_a, ar = pcall(host.modbus_read, R.MODE_SETTING, 44, "holding")
            if ok_a and ar then
                local want = 1 * EMS_SCALE
                local mode = ar[R.MODE_SETTING - R.MODE_SETTING + 1]
                local remote = ar[R.LOCAL_REMOTE - R.MODE_SETTING + 1]
                local extc = ar[R.EXT_CONTROL - R.MODE_SETTING + 1]
                if mode ~= want or remote ~= want or extc ~= want then
                    host.log(string.format(
                        "WARN: external control lost (300=%s 337=%s 343=%s, want %d) — re-arming",
                        tostring(mode), tostring(remote), tostring(extc), want))
                    if remote ~= want then write_u16("re-arm", R.LOCAL_REMOTE, want) end
                    if extc   ~= want then write_u16("re-arm", R.EXT_CONTROL,  want) end
                    if mode   ~= want then write_u16("re-arm", R.MODE_SETTING, want) end
                    -- Restore the setpoint the controller last asked
                    -- for — re-arming alone leaves the EMS at whatever
                    -- the watchdog zeroed it to.
                    write_setpoint_konja_w("re-arm", s2k(slew_committed_w))
                    slew_last_write_ms = now_ms()
                end
            end
        end

        -- Lifetime meter energy. Deliberately NOT in the hot bundle:
        -- these are 0.01 kWh accumulators that cannot move meaningfully
        -- inside 10 s, so paying a fourth round trip at 20 Hz for them
        -- would buy nothing. Cached in MS and re-emitted every poll so
        -- the field is stable in the snapshot.
        --   4010 Forward Total Active Energy  uint32, 0.01 kWh → ×10 Wh
        --   4020 Reverse Total Active Energy  uint32, 0.01 kWh → ×10 Wh
        local ok_me, me = pcall(host.modbus_read, R.MTR_ENERGY, M.N_ENERGY, "input")
        if ok_me and me then
            local fwd = u32_be(me[M.FWD_WH], me[M.FWD_WH + 1])
            local rev = u32_be(me[M.REV_WH], me[M.REV_WH + 1])
            if fwd then MS.import_wh = fwd * 10 end
            if rev then MS.export_wh = rev * 10 end
        end

        local ok_e, ems = pcall(host.modbus_read, R.EMS_STATUS, N_EMS_STATUS, "input")
        if ok_e and ems then
            -- Registers 3..23 and 27..29 are all "0 normal / 1 abnormal".
            local faults = {}
            local names = {
                [4]="config_load", [5]="sys_init", [6]="grid_island_transition",
                [7]="sys_rw", [8]="pcs", [9]="bms", [10]="pv",
                [11]="pcs_comm", [12]="bms_comm", [13]="io_comm",
                [14]="meter_comm", [15]="pv_comm", [16]="pcs_ctrl",
                [17]="bms_ctrl", [18]="io_ctrl", [19]="pv_ctrl",
                [20]="slave_ctrl", [21]="cloud_comm", [22]="upper_ems_comm",
                [23]="local_ems_comm", [24]="networking",
                [28]="water_immersion", [29]="smoke", [30]="node",
            }
            for idx, nm in pairs(names) do
                local v = ems[idx]
                if v and v ~= 0 then faults[#faults + 1] = nm end
            end
            local word = string.format("sys=%s grid=%s faults=[%s]",
                tostring(ems[1]), tostring(ems[2]), table.concat(faults, ","))
            if word ~= last_ems_status_word then
                host.log("EMS status: " .. word)
                last_ems_status_word = word
            end
        end
    end

    -- ── Energy headroom from the CONFIGURED SoC band ───────────────
    -- Deliberately not the BMS's own chargeable/dischargeable energy
    -- (2721/2722): those report to the BMS's protection limits, not to
    -- the operating band the arbitrator is asked to respect.
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

    -- Nothing answered this poll ⇒ nothing to report. An emit with every
    -- field nil (and 0 Wh headroom) is a fabricated reading, and the host
    -- counts each failed read against the poll — keep the control path
    -- above running, but stay silent on telemetry until the bus is back.
    if not ((ok_p and pcs) or (ok_b and bms)) then
        return 50
    end

    host.emit("battery", {
        W                      = dc_w,
        SoC_nom_fract          = bat_soc,
        V                      = bat_v,
        A                      = bat_a,
        temperature_C          = bms_temp_c,
        available_charge_Wh    = chg_eh_wh,
        available_discharge_Wh = dis_eh_wh,
        available_charge_W     = avail_charge_w,
        available_discharge_W  = avail_discharge_w,
    })
    if ac_w ~= nil then
        host.emit("inverter", {
            W           = ac_w,
            Hz          = hz,
            heatsink_C  = igbt_c,
        })
    end

    -- ── Cabinet meter emit (0.3.0) ─────────────────────────────────
    -- Emitted LAST so a malformed meter block can never delay or
    -- displace the battery/inverter emits the control path depends on.
    --
    -- Suppressed unless at least one phase carries voltage: a dead
    -- ADL400 returns zeros, and a 0 W / 0 V "reading" would be taken by
    -- l1 as a real balanced grid and fed to the fuse and export
    -- guards. No meter is a safer input than a fabricated one.
    if ok_m and mtr then
        local v1 = (mtr[M.L1_V] or 0) / 10.0
        local v2 = (mtr[M.L2_V] or 0) / 10.0
        local v3 = (mtr[M.L3_V] or 0) / 10.0
        if v1 > 0 or v2 > 0 or v3 > 0 then
            MS.dead_logged = false
            -- int32, high word at the lower address, 0.001 kW = 1 W.
            -- NOT negated — see the CABINET METER header block.
            local mw = i32_be(mtr[M.TOTAL_W], mtr[M.TOTAL_W + 1])
            local m_hz = (mtr[M.HZ] or 0) / 100.0
            check_meter_placement(slew_committed_w, ac_w, mw)
            host.emit("meter", {
                W               = mw,
                Hz              = (m_hz > 0) and m_hz or nil,
                L1_V            = v1,
                L2_V            = v2,
                L3_V            = v3,
                L1_A            = (mtr[M.L1_A] or 0) / 100.0,
                L2_A            = (mtr[M.L2_A] or 0) / 100.0,
                L3_A            = (mtr[M.L3_A] or 0) / 100.0,
                L1_W            = i32_be(mtr[M.L1_W], mtr[M.L1_W + 1]),
                L2_W            = i32_be(mtr[M.L2_W], mtr[M.L2_W + 1]),
                L3_W            = i32_be(mtr[M.L3_W], mtr[M.L3_W + 1]),
                total_import_Wh = MS.import_wh,
                total_export_Wh = MS.export_wh,
            })
        elseif not MS.dead_logged then
            MS.dead_logged = true
            host.log("cabinet meter reads 0 V on all phases — suppressing the " ..
                     "`meter` emit rather than reporting a fabricated 0 W grid " ..
                     "(check EMS reg 13 meter_comm)")
        end
    end

    return 50
end

-- ---------------------------------------------------------------------
-- Control — battery power setpoint via the EMS Slave Power Setting.
-- ---------------------------------------------------------------------
local function deinit_safe_revert()
    host.log("CMD: deinit → safe revert (slew BYPASSED)")
    control_initialized = false
    last_commanded_w = 0
    slew_target_w = 0
    slew_committed_w = 0
    slew_last_write_ms = now_ms()
    self_heal_disagree_since_ms = 0
    -- Command 0 W and DELIBERATELY LEAVE EXTERNAL CONTROL ENGAGED.
    --
    -- The obvious move — also clear 343 to "hand the cabinet back" —
    -- is the wrong one here. Clearing 343 returns the EMS to *its own*
    -- configured strategy: demand control (331/334), TOU, anti-reverse
    -- (328). We do not know that strategy is benign, and the l1
    -- contract requires a safe-revert to leave the device in a state
    -- that will not autonomously charge, discharge or export.
    --
    -- Holding 343 = 1 with setpoint 0 means the cabinet holds OUR zero.
    -- If the controller never returns, the EMS's own 3-minute comms
    -- watchdog independently forces output to 0 — so the fail-safe is
    -- 0 W either way, and never "whatever the EMS felt like doing".
    -- An operator can always take it back from the HMI via 337.
    --
    -- 337 (Local/Remote) and 300 (Mode) are left alone for the same
    -- reason: flipping the cabinet to Local/Debug is a bigger state
    -- change than a safe-revert should make.
    --
    -- See OPEN QUESTION D — if Konja confirms the EMS parks at 0 W on
    -- 343 1→0 rather than resuming its strategy, clearing 343 becomes
    -- the tidier revert and this can change.
    local ok = write_setpoint_konja_w("deinit", 0)
    if ok then
        host.log("deinit: setpoint 0 W, external control LEFT ENGAGED " ..
                 "(343=1) so the EMS cannot resume its own strategy")
    end
    return ok
end

function driver_command(action, power_w, ctx)
    host.log("CMD: action=" .. tostring(action) .. " power_w=" .. tostring(power_w or 0))

    if action == "init" then
        return arm_remote_mode()
    end

    if action == "deinit" then
        return deinit_safe_revert()
    end

    if action == "set_slew_rate" then
        local pct = power_w or 0
        if pct <= 0 then
            ffr_slew_rate_pct_per_s = ffr_slew_rate_pct_per_s_default
            host.log(string.format("set_slew_rate: reset to default %.2f %%/s",
                                   ffr_slew_rate_pct_per_s))
        else
            ffr_slew_rate_pct_per_s = pct
            host.log(string.format("set_slew_rate: %.2f %%/s (was default %.2f %%/s)",
                                   ffr_slew_rate_pct_per_s, ffr_slew_rate_pct_per_s_default))
        end
        return true
    end

    if action == "battery" then
        if not control_initialized then
            host.log("CMD: auto-arming EMS external control (first battery call)")
            if not arm_remote_mode() then
                host.log("CMD FAIL: external-control arm failed")
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
            -- Activation / hold / direction-up-in-magnitude: write
            -- through immediately. FFR §1.2 Tabell 2 caps full
            -- activation at 0.70 s (C-tier); slewing here would break
            -- it. One FC16 — the arm registers are NOT re-asserted on
            -- the hot path (the EMS watchdog is comms-based, not
            -- write-based, and our polling already satisfies it).
            local dir = (target_w > 0 and "charge")
                or (target_w < 0 and "discharge") or "stop"
            host.log(string.format(
                "CMD: %s %dW (activation/hold, slew bypassed)", dir, target_w))
            local ok = write_setpoint_konja_w("battery", s2k(target_w))
            if ok then
                slew_committed_w = target_w
                slew_last_write_ms = now_ms()
                last_commanded_w = target_w
                self_heal_disagree_since_ms = 0
            end
            return ok
        else
            -- Deactivation: register the target; driver_poll steps
            -- `committed_w` toward it at the configured rate. Return
            -- true — the slew is a control policy, not a fault.
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

function driver_default_mode()
    host.log("CMD: default_mode → safe revert (slew BYPASSED)")
    deinit_safe_revert()
end

function driver_cleanup()
end

-- ── OPEN QUESTIONS FOR KONJA ENGINEERING ─────────────────────────────
-- Documented here so the driver never silently guesses. Ordered by
-- how much they gate the SvK test campaign.
--
-- ══ BLOCKING — answer before the first test window ═══════════════════
--
-- Q1. LATENCY (the big one). What is the EMS external-control scan
--     cycle, and the EMS→PCS setpoint propagation delay? SvK FFR
--     alternative C requires FULL activation within 0.70 s
--     end-to-end. If the EMS adds more than ~200 ms we need PCS reg
--     8211 ("Set Active Charging/Discharging Power", int16 0.1 kW)
--     enabled for direct writes — the Instruction sheet says non-EMS
--     writes require "prior notification". Please also tell us the
--     EMS software version (V1.14 of the protocol references
--     behaviour "applicable to V4.2.1 and above" and we have no
--     register to read it from).
--
-- QA. COMPETING AUTHORITY. Are these active from the factory, and
--     may we set them to 0 for the test window?
--       328/329  Anti-reverse current  ← if active the EMS limits
--                EXPORT and every FFR / FCR-D DISCHARGE test returns
--                a flat zero. This is the single most likely cause
--                of a "nothing happens" first light.
--       331/332  Demand control        (peak-shaving competes for
--       334      Demand discharge       the setpoint)
--       303      Protection strategy
--     The driver reads and warns on all of these at init but writes
--     none of them.
--
-- QB. POWER CEILINGS. What are 304 / 306 (Max Discharge / Max Charge
--     Power of Energy Storage) set to from the factory, and may we
--     write them to ±12500 (= 125.00 kW)? If they are lower than the
--     cabinet rating every SvK activation is silently clipped and the
--     magnitude requirement fails. Same question for PCS 8255/8256.
--
-- Q2. DEAD-BAND. Do 308 / 310 (Minimum Discharge / Minimum Charge
--     Power) act as a floor that suppresses small setpoints? SvK
--     FCR-N linearity and aFRR tracking dispatch down to a few
--     percent of rated. If they do, they must be 0 for the tests —
--     may we write them?
--
-- QC. WHICH AXIS DOES REG 344 COMMAND — AC grid-port power, or DC
--     battery power? This decides whether the setpoint should be
--     scored against `inverter.ac_W` or `battery.dc_W`. The driver
--     currently commands via 344 while reporting `battery.dc_W` as
--     the primary control axis; if 344 is AC, there is a systematic
--     conversion-loss offset (~3 % at full power) between what we
--     command and what we report.
--
-- ══ IMPORTANT — affects test design or interpretation ════════════════
--
-- QD. On 343 going 1→0, does the EMS hold 0 W, or immediately resume
--     its configured strategy? This driver currently leaves 343 = 1
--     at deinit precisely because we do not know (see
--     deinit_safe_revert). If the EMS parks at 0 W, clearing 343
--     becomes the tidier revert.
--
-- QE. Does the EMS enforce 312/313 (Max/Min SoC) and 314/315 (SoC
--     hysteresis) while under external control? The hysteresis
--     matters: after touching the SoC ceiling the EMS may refuse to
--     resume until SoC has fallen by the hysteresis band, which would
--     end an FCR-N or endurance run early.
--
-- QG. DERATING. At what IGBT / ambient temperature does reg 8037
--     trip, and what continuous power is guaranteed at 35 °C ambient
--     for a 15-minute FCR-D endurance run? The driver logs the
--     derating factor (8036) and flag (8037) on change.
--
-- Q6. RAMP LIMITS. Does the EMS or PCS impose an internal ramp rate
--     on the active-power setpoint? Nothing in the protocol exposes
--     one, but SvK FCR-D Req 2 needs 86 % of ΔP within 7.5 s and FFR
--     needs a full step in ≤ 0.70 s, so any hidden ramp caps us.
--
-- Q7. MASTER/SLAVE. Reg 26 reports Standalone / Master / Slave.
--     Reg 344 is named "Slave Power Setting" — is it the correct
--     external setpoint for a STANDALONE 261 cabinet, or only for a
--     master driving slaves? (The "EMS External Control Steps" note
--     implies it is the general one, and reg 26 will tell us what
--     this cabinet reports.)
--
-- QF. FUNCTION CODES. The Instruction sheet's function-code legend is
--     mistranslated (it shifts 04H / 05H / 06H by one), so the
--     per-sheet "Function Code 04 / 03" block headers are the only
--     evidence for the YC = FC04 / YT = FC03 split this driver uses.
--     Confirm — or we probe at first light (try FC04 at 8034, fall
--     back to FC03 on exception 0x02).
--
-- ══ ANSWERABLE ON THE BENCH — no reply needed ════════════════════════
--
-- Q8. FLOAT WORD ORDER — **now self-tested, no longer assumed.**
--     Instruction sheet r4/r6 state "the high word is located at the
--     lower Modbus address" for int32/uint32. Row 7 (`float`) says
--     only "IEEE-754 floating-point format" and does NOT repeat the
--     rule. Rather than assume it carries over, the driver writes a
--     10 W probe to 344/345 with External Control still 0, reads it
--     back with FC03, and refuses to arm unless the words match
--     (see verify_setpoint_encoding). Please still confirm in writing
--     so we can drop the probe: is the float high word at 344 and the
--     low word at 345?
--
-- QF2. WHICH FUNCTION CODE WRITES a holding register? The Instruction
--     sheet's legend is internally inconsistent — it lists
--     "03H = Read multiple input registers" and "04H = Write coil
--     registers", both of which are wrong for standard Modbus, and it
--     gives 06H and 10H the same description. The driver uses FC16
--     (0x10, write multiple) and FC03 to read back, and the same
--     encoding self-test confirms the pair works. Confirm FC16 is
--     correct, and whether FC06 is also accepted for single registers.
--
-- Q11. IS REG 344/345 RETENTIVE? Not stated anywhere in the workbook.
--     It matters: if the register survives a power cycle or an
--     external-control disengage, then engaging 343 after an unclean
--     controller stop would immediately re-apply the last setpoint —
--     potentially 125 kW. The driver defends against this by seeding
--     the setpoint before engaging 343, and logs what 344/345 held at
--     startup so the answer shows up in the first-light log. Please
--     confirm: what does 344/345 read after a cabinet power cycle, and
--     does the EMS clear it when 343 goes 1 -> 0?
--
-- Q3. SIGN of the READBACK path. The workbook states + = discharge
--     only for reg 344 (setpoint) and BMS 2751 (current). It does NOT
--     state the sign of PCS 8047 (Total AC Output Active Power) or
--     8056 (DC Power). This driver assumes + = discharge throughout.
--     Verified in one shot: command a known discharge and check both
--     read positive.
--     (The SoC half of this question is settled: reg 2727 is uint16
--     with "precision 0.001", which cannot be a percentage — it would
--     cap at 65.5 % — so raw 1000 = 100 %. SOH reading 998 → 99.8 %
--     corroborates. The driver guards the alternative scaling anyway.)
--
-- ══ COSMETIC ════════════════════════════════════════════════════════
--
-- Q5. V1.16 changelog says "Add SN information point" to the MG500
--     read-only block, but the EMS sheet still ends at reg 29. What
--     is the EMS SN register? Not blocking — we read the PCS module
--     SN at 8064-8079 instead.
--
-- Q9. INTERNAL METER CT PLACEMENT. The cabinet exposes a meter block
--     at 4000-4109, and reg 4088 (Total Active Power, int32,
--     0.001 kW) has **1 W resolution** — 100× finer than the PCS
--     power registers this driver reads (8047 / 8056 are int16 at
--     0.1 kW). That would be a better SvK scoring signal.
--
--     0.1.0 and 0.2.0 deliberately did NOT emit `meter`. In l1, a
--     controllable device's own meter-emit becomes the SITE GRID METER
--     whenever `site.meter` and `site.grid_meter_device` are both
--     unset — it then feeds the fuse and export protection, not just
--     telemetry. If Konja's CT sits at the PCS output rather than at
--     the site grid connection, that would feed protection with the
--     cabinet's own output and silently defeat the fuse guard.
--
--     **0.3.0 emits it anyway, by operator decision (2026-08-12):**
--     the finer signal is worth having, and the operator names the
--     intended site grid meter explicitly in the dashboard rather than
--     relying on the fallback. The placement question is no longer a
--     blocker but it is still a QUESTION — so the driver now ANSWERS
--     it from live data instead of waiting: `check_meter_placement`
--     baselines the meter at 0 W and compares its movement against a
--     delivered setpoint, logging one of three verdicts (CT at grid /
--     sign inverted / CT not at grid). Read that log line before
--     trusting the emit for protection.
--     → Still worth confirming with Konja: where is the CT installed?
--     → 0.1 kW on a 125 kW cabinet is 0.08 % of rated, negligible for
--       every SvK metric. It only becomes material if the suite is
--       de-rated (a 10 kW test override makes each LSB 1 % of cap).
--       Run the Konja suite at or near full rated power.
--
-- Q10. METER SIGN. The Meter sheet's Description column is EMPTY for
--     reg 4088 — the vendor never states which direction is positive.
--     The workbook has separate "Forward" (4010) / "Reverse" (4020)
--     active energy accumulators, and EMS 328/329 implement
--     anti-backflow, which only makes sense with the CT at the grid
--     connection and "reverse" meaning export. So forward = import,
--     and 0.3.0 emits reg 4088 with NO negation — matching Sourceful's
--     +import / −export. Unlike the PCS/BMS registers, which are
--     +discharge and ARE negated via k2s().
--     This is an inference, cross-checked live by
--     `check_meter_placement` and never auto-corrected.
