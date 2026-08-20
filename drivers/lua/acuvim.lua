-- Accuenergy Acuvim II — three-phase revenue-grade power METER driver.
--
-- Spec: "ACUVIM II MODBUS MAP" (Accuenergy, 41-page register addendum to
-- the Acuvim II Series Power Meter User Manual, doc 1040E1303).  This is
-- a metering-only device: it sits at the grid connection and reports
-- V / I / P / Q / S / PF / frequency + cumulative energy.  There is NO
-- setpoint / control path — role = "meter", read-only, emits "meter".
--
-- ── Wire-protocol facts (from the MODBUS MAP) ───────────────────────
-- * Real-time metering parameters live in a contiguous IEEE-754 float32
--   block starting at wire address 0x4000 ("Real-time Metering: 03H
--   Read").  Each value is a 32-bit float packed into two consecutive
--   16-bit registers; addresses are therefore even, 2 regs apart.
-- * Function code: 03H (Read Holding Registers).  The map labels every
--   block "03H Read" — the Acuvim II does NOT split metering onto FC04
--   input registers; everything is holding-register space.  We pass
--   "holding" to host.modbus_read.
-- * Float word order: big-endian (most-significant 16-bit word first,
--   big-endian bytes inside each word) — the Accuenergy default.  We
--   decode every float with host.decode_f32_be(hi, lo) where hi is the
--   lower register address.  (If a deployment has flipped word order in
--   firmware, that is a config error to fix on the meter, not here.)
-- * Cumulative energy lives just past the metering block as unsigned
--   32-bit Dwords (also high-word-first), starting at 0x4048.
--
-- ── Register map used (wire addresses, hex; each float = 2 regs) ─────
--   0x4000  F      Frequency               Hz     float
--   0x4002  U1     Phase 1 voltage (L-N)   V      float
--   0x4004  U2     Phase 2 voltage (L-N)   V      float
--   0x4006  U3     Phase 3 voltage (L-N)   V      float
--   0x4012  IL1    Phase A current         A      float
--   0x4014  IL2    Phase B current         A      float
--   0x4016  IL3    Phase C current         A      float
--   0x401C  Pa     Phase A active power    W *    float
--   0x401E  Pb     Phase B active power    W *    float
--   0x4020  Pc     Phase C active power    W *    float
--   0x4022  Psum   Total system power      W *    float
--   0x4048  Ep_Imp Consumed (import) energy   kWh** Dword (u32)
--   0x404A  Ep_Exp Generated (export) energy  kWh** Dword (u32)
--
--   * Power scaling: the map's "Secondary Mode" relationship is
--     P = Rx / 1000 → kW, i.e. the raw float Rx is already in WATTS.
--     We emit Rx verbatim as watts (no /1000) — l1 wants watts.
--     (In "Primary Mode" the meter pre-multiplies by PT1/PT2·CT1/CT2;
--     either way Rx is watts on the wire — see PT/CT note below.)
--  ** Energy scaling: "Primary Mode" Ep = Rx / 10 (units of 0.1 kWh),
--     "Secondary Mode" Ep = Rx / 1000.  The meter's Energy Display Mode
--     (reg 0x1019) selects which; default is Primary.  We assume the
--     default Primary mode → Wh = Rx / 10 * 1000 = Rx * 100.  If a site
--     runs the meter in Secondary energy mode the lifetime counters will
--     be off by ×100 — see OPEN below.
--
-- ── PT / CT ratio (why there's no config field for it) ──────────────
-- The Acuvim II applies its configured PT (voltage) and CT (current)
-- transformer ratios INTERNALLY when in Primary mode (regs 0x1005-0x100B
-- PT1/PT2/CT1/CT2).  The float block then already carries primary-side
-- engineering units.  So the driver needs NO ct_ratio config — the
-- ratio is the meter's job, configured once at commissioning on the
-- device itself.  We read primary-side values straight off the bus.
-- (If the meter is left in Secondary mode it reports secondary-side
-- values and the install must scale at the meter — not our concern.)
--
-- ── Sign convention (Sourceful, applied at the boundary here) ───────
-- Acuvim II: positive active power = "Consumed" (current flowing in the
-- installer-configured forward direction, regs 0x1012-0x1014 default
-- Positive).  At a service-entrance meter wired forward = grid import,
-- so Acuvim positive == grid import == Sourceful positive:
--   +W = importing from grid   (power INTO the site)
--   -W = exporting to grid     (power OUT of the site)
-- Values therefore emit AS-IS — no negation.  If a deployment wires the
-- CTs backwards, fix the wiring (or flip reg 0x1012-0x1014 on the
-- meter); don't flip signs in this driver.
--
-- ── Identification (driver_init only) ───────────────────────────────
-- Model       0xC364, 16-register ASCII string (32 chars)
-- Serial No.  0xC384, 16-register ASCII string (32 chars)
-- These sit far from the metering block (0xC3xx vs 0x40xx) so they get
-- their own one-shot FC03 reads on init, with retries — never polled.
--
-- ── Bundle range ────────────────────────────────────────────────────
-- One FC03 read per poll covers the metering block AND the energy
-- counters in a single round trip:
--   start = 0x4000, count = 76 regs  (covers 0x4000 .. 0x404B inclusive)
-- 0x4000 (F) through 0x404B (Ep_Exp low word) = 76 registers, well under
-- FC03's 125-reg cap.  Unmapped floats inside the window (Uavg, line
-- voltages, Iavg, In, reactive/apparent power, PF) are included in the
-- response and ignored on decode.

PROTOCOL = "modbus"

-- ────────────────────────────────────────────────────────────────────
-- Manifest. Static, read by l1 before driver_init() runs.
--
-- A meter has no operator-configurable nameplate (no capacity, no SoC
-- bounds, no setpoint) and the PT/CT ratio lives on the meter, so
-- `requires` and `options` are empty.  l1 still validates `provides`
-- after init / first poll and loads the driver in both telemetry and
-- control modes.  In control mode driver_command is invoked but the
-- meter ignores every action — there is nothing to control.
-- ────────────────────────────────────────────────────────────────────
PROTOCOL = "modbus"

DRIVER = {
    host_api_min = 1,
    host_api_max = 1,
    id = "acuvim",
    name = "Accuenergy Acuvim II meter",
    manufacturer = "Accuenergy",
    version = "0.4.2",
    protocols = { "modbus" },
    capabilities = { "meter" },
    read_only = true,
    description = "Accuenergy Acuvim II three-phase revenue-grade meter via Modbus RTU or TCP.",
    authors = { "David and Blixt L1 contributors", "Sourceful contributors" },
    tested_models = { "Acuvim II" },
    verification_status = "experimental",
    verification_notes = "Migrated from the Blixt L1 driver source; source has run on hardware under Blixt L1 but no HIL record exists in this repository yet.",
    connection_defaults = {
        port = 502, unit_id = 1,
    },
}

DRIVER_MANIFEST = {
    name    = "acuvim",
    version = "0.4.2",
    role    = "meter",

    requires = {},
    options  = {},

    -- Field names match @srcful/data-models MeterTelemetry verbatim and
    -- the SDM630 reference driver.  Top-level W/Hz are totals; per-phase
    -- rows are flat (L1_V/L1_A/L1_W ...) — the shape l1's MeterEmit /
    -- arbitrator per-phase fuse clamp reads (lua_driver.rs reads
    -- tbl.get("L1_V") etc.; the Rust side converts A→mA and V→dV).
    provides = {
        live   = { "meter.W", "meter.Hz",
                   "meter.L1_V", "meter.L2_V", "meter.L3_V",
                   "meter.L1_A", "meter.L2_A", "meter.L3_A",
                   "meter.L1_W", "meter.L2_W", "meter.L3_W",
                   "meter.total_import_Wh", "meter.total_export_Wh" },
        static = { "make", "model", "sn" },
    },
}

-- ── Module state ────────────────────────────────────────────────────
-- The Acuvim II has no per-cycle state we need to remember; everything
-- comes from the bus.  We cache nothing across polls.

-- ── Helpers ─────────────────────────────────────────────────────────

-- Decode a float32 from a bundled FC03 result, given the bundle base
-- wire address `base` and the float's wire address `off`.  Returns nil
-- if the underlying read failed so callers can substitute 0.  hi word
-- first (big-endian word order).
local function f32(regs, base, off)
    if not regs then return nil end
    local idx_hi = off - base + 1            -- Lua 1-based; hi word first
    local hi = regs[idx_hi]
    local lo = regs[idx_hi + 1]
    if hi == nil or lo == nil then return nil end
    return host.decode_f32_be(hi, lo)
end

-- Decode an unsigned 32-bit Dword (energy counter) from the bundle,
-- high word first.  nil-safe like f32.
local function u32(regs, base, off)
    if not regs then return nil end
    local idx_hi = off - base + 1
    local hi = regs[idx_hi]
    local lo = regs[idx_hi + 1]
    if hi == nil or lo == nil then return nil end
    return host.decode_u32_be(hi, lo)
end

-- ────────────────────────────────────────────────────────────────────
-- driver_init — READ-ONLY identification.
--
-- Reads the model (0xC364) and serial number (0xC384) ASCII strings.
-- No writes; the Acuvim II has no remote mode or watchdog.  Retry each
-- small read 3x: RS-485 transceivers / USB converters can be slow on
-- the first request after a cold start.
-- ────────────────────────────────────────────────────────────────────
-- Energy block (0x4048) probing state — see driver_poll.
local ENERGY_ABSENT_LIMIT = 3
local energy_absent_strikes = 0

function driver_init(config)
    host.set_make("Accuenergy")

    -- Model — 16 registers (32 ASCII chars) at 0xC364.
    local model = nil
    for attempt = 1, 3 do
        local ok, regs = pcall(host.modbus_read, 0xC364, 16, "holding")
        if ok and regs and regs[1] then
            local s = host.decode_string(regs, 1, 16)
            if s and s ~= "" then model = s; break end
        end
        host.log("Acuvim II: model read attempt " .. attempt .. " failed, retrying...")
        host.sleep(500)
    end
    if model then
        host.set_model(model)
        host.log("Acuvim II: model = " .. model)
    else
        host.set_model("Acuvim II")
        host.log("Acuvim II: model reg 0xC364 unavailable, using default")
    end

    -- Serial number — 16 registers (32 ASCII chars) at 0xC384.
    local sn = nil
    for attempt = 1, 3 do
        local ok, regs = pcall(host.modbus_read, 0xC384, 16, "holding")
        if ok and regs and regs[1] then
            local s = host.decode_string(regs, 1, 16)
            if s and s ~= "" then sn = s; break end
        end
        host.log("Acuvim II: SN read attempt " .. attempt .. " failed, retrying...")
        host.sleep(500)
    end
    if sn then
        host.set_sn(sn)
        host.log("Acuvim II: SN = " .. sn)
    else
        -- Don't fail init — a missing SN shouldn't block telemetry on a
        -- working meter.  l1 logs a static-provided warning.
        host.set_sn("UNKNOWN")
        host.log("Acuvim II: SN unavailable (reg 0xC384 not responding)")
    end

    return true
end

-- ────────────────────────────────────────────────────────────────────
-- driver_poll — one bundled FC03 read, decode, emit "meter".
-- ────────────────────────────────────────────────────────────────────
function driver_poll()
    -- Split read: 0x4000 cnt=36 covers Frequency + voltages + currents
    -- + per-phase active + Psum (everything l1 actually consumes), and
    -- 0x4048 cnt=4 covers Ep_Imp + Ep_Exp (the only energy fields we
    -- emit). We deliberately SKIP 0x4024..0x4047 (reactive Q, apparent
    -- S, power factor, unbalance, load characteristic, demand) — none
    -- of it is read by l1 or surfaced to the dashboard. Reading the
    -- old 76-reg single block ate ~175 ms on the wire @ 9600 baud,
    -- which capped the meter's effective sample rate at ~14 Hz and
    -- ate ~10-15 mHz off SvK FFR §4.2.2 ramp activation budget
    -- (±50 mHz @ -0.2 Hz/s ≙ ±250 ms). The two narrow reads + their
    -- frame overheads come in around ~95 ms, near-doubling the
    -- effective Acuvim sample rate.
    local base = 0x4000
    local ok, regs = pcall(host.modbus_read, base, 36, "holding")
    if not ok or not regs then
        -- Don't emit on a bus failure — silent in steady state, l1
        -- handles staleness.  modbus_read rate-limits the FAIL line on
        -- the Rust side.
        return 1000
    end
    -- Second narrow read for the cumulative energy Dwords. A bus
    -- failure here is non-fatal: energy is a steady-rising telemetry
    -- counter, not a control input — fall back to "unknown" so the
    -- per-poll metering frame still emits without the kWh fields.
    -- The host counts every failed read against the poll, so a meter
    -- that never answers 0x4048 (firmware / register-map variant) is
    -- probed a bounded number of times and then left alone: the kWh
    -- fields simply stay absent from the emit.
    local energy_base = 0x4048
    local regs_e = nil
    if energy_absent_strikes < ENERGY_ABSENT_LIMIT then
        local ok_e, r = pcall(host.modbus_read, energy_base, 4, "holding")
        if ok_e and r then
            regs_e = r
            energy_absent_strikes = 0
        else
            energy_absent_strikes = energy_absent_strikes + 1
            if energy_absent_strikes == ENERGY_ABSENT_LIMIT then
                host.log("acuvim: energy block 0x4048 absent after "
                    .. ENERGY_ABSENT_LIMIT .. " reads — kWh fields disabled")
            end
        end
    end

    -- Frequency (Hz).
    local hz = f32(regs, base, 0x4000) or 0

    -- Per-phase line-to-neutral voltage (V).  Always positive on a live
    -- grid.  Drives the arbitrator's per-phase fuse clamp (V→deci-volts
    -- on the Rust side).
    local v_l1 = f32(regs, base, 0x4002) or 0
    local v_l2 = f32(regs, base, 0x4004) or 0
    local v_l3 = f32(regs, base, 0x4006) or 0

    -- Per-phase current (A).  Magnitude; the arbitrator takes |I| in mA.
    local i_l1 = f32(regs, base, 0x4012) or 0
    local i_l2 = f32(regs, base, 0x4014) or 0
    local i_l3 = f32(regs, base, 0x4016) or 0

    -- Per-phase active power (W), signed (forward / consumed = positive
    -- = import).  Raw float is already in watts (see header).
    local p_l1 = f32(regs, base, 0x401C) or 0
    local p_l2 = f32(regs, base, 0x401E) or 0
    local p_l3 = f32(regs, base, 0x4020) or 0

    -- Total system active power (W), signed.
    local p_total = f32(regs, base, 0x4022) or 0

    -- Lifetime import / export energy.  Assuming the meter's default
    -- Primary energy-display mode (reg 0x1019 = 0): Ep = Rx / 10 (units
    -- of 0.1 kWh) → Wh = Rx / 10 * 1000 = Rx * 100. Read from the
    -- second narrow FC03 block (energy_base = 0x4048). If that read
    -- failed, leave the fields nil so the emit drops them — the
    -- aggregator treats absent energy as "no fresh reading", which is
    -- truer than fabricating 0 Wh on a transient bus error.
    local import_wh, export_wh = nil, nil
    if regs_e then
        local imp_raw = u32(regs_e, energy_base, 0x4048) or 0
        local exp_raw = u32(regs_e, energy_base, 0x404A) or 0
        import_wh = math.floor(imp_raw * 100 + 0.5)
        export_wh = math.floor(exp_raw * 100 + 0.5)
    end

    -- @srcful/data-models MeterTelemetry.  Sourceful sign on W and
    -- per-phase L*_W: positive = import, negative = export.  Acuvim
    -- ships consumed-positive which matches as long as CTs are wired in
    -- the import (forward) direction — the conventional install.
    host.emit("meter", {
        W               = p_total,   -- a meter measures AC; +import / −export
        Hz              = hz,
        L1_V            = v_l1,
        L2_V            = v_l2,
        L3_V            = v_l3,
        L1_A            = i_l1,
        L2_A            = i_l2,
        L3_A            = i_l3,
        L1_W            = p_l1,
        L2_W            = p_l2,
        L3_W            = p_l3,
        total_import_Wh = import_wh,
        total_export_Wh = export_wh,
    })

    return 1000   -- next-poll hint (ms); l1 owns the actual cadence
end

-- ────────────────────────────────────────────────────────────────────
-- driver_command — meter has nothing to command.
-- l1 may still call init/deinit in control mode; both are no-ops here
-- so an Acuvim II sitting on a shared bus alongside an inverter doesn't
-- block control-mode start-up.  Returning true (not false) keeps the
-- arbitrator from treating this asset as failed on a probe write.
-- ────────────────────────────────────────────────────────────────────
function driver_command(action, value, ctx)
    if action == "init" or action == "deinit" then
        return true
    end
    return true
end

function driver_default_mode()
    -- Nothing to revert.  A meter only measures.
end

function driver_cleanup()
    -- No resources held between calls.
end
