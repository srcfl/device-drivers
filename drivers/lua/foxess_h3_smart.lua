-- Fox ESS inverters on the H3-Smart register map: the 1K5-HI series
-- (three-phase hybrid, model strings like "1K5-HI-10-V1") and the
-- H3-Smart family they share the map with.
-- Emits: PV, Battery, Meter
-- Register type: HOLDING (FC 0x03), 32-bit values high word first
-- Port: 502, Modbus unit 247
--
-- Register map from the nathanmarlor/foxess_modbus community project
-- (Inv.H3_SMART profile), validated against a 1K5-HI-10-V1 on real
-- hardware: PV string power agrees with V*A within 0.5%, and
-- load + battery + pv balances against the grid CT within inverter
-- losses.
--
-- This device answers unknown registers with silence, not a Modbus
-- exception, so a wrong address costs a full read timeout. Every
-- address below was seen answering on hardware. The BMS block
-- (37609..37620) only answers single-register reads; SoC and battery
-- temperature are read one register at a time for that reason.
--
-- The distinct H1/H3 (11000-range) register map lives in the separate
-- `foxess` driver.
--
-- LOCAL CONTROL BUILD (operator's own risk, not the signed channel):
-- battery dispatch through the vendor remote-control block.
--
-- ============================ SEMANTICS ============================
-- The setpoint at 46003/46004 is the INVERTER'S AC ACTIVE POWER,
-- export-positive. It is not battery power and not a grid-meter
-- target. The inverter reaches the number by any means available --
-- running PV, curtailing PV, charging, or discharging -- bounded by
-- what the battery accepts at that moment.
--
-- Hardware evidence behind this model (1K5-HI-10-V1, 2026-08-03/05),
-- each once misdiagnosed before the model fell out:
--   * write -5000 ("charge 5 kW" naively): imported 4.5 kW from the
--     grid for 12 h against an idle plan -- import runs until the
--     battery's charge ceiling, and imported power DISPLACES PV
--     before adding to it;
--   * write +500 with a full battery in full sun ("discharge 500"
--     naively): the inverter CURTAILED PV 3191 W -> 600 W instead of
--     discharging -- the operator saw the array throttle, which the
--     meter data alone could not reveal;
--   * bare `vendor = -target` appeared to work for discharge on
--     2026-08-03 only because PV was ~0 that evening; the naive form
--     is correct exactly when PV is zero.
-- The same semantics are confirmed independently by the
-- nathanmarlor/foxess_modbus remote-control implementation, whose
-- comments describe the import-displaces-PV behaviour verbatim.
--
-- ========================== TRANSLATION ============================
-- DISCHARGE (battery_target < 0), hardware-validated 2026-08-05
-- (commanded -1000 in full sun: battery -1080, PV uncurtailed):
--     vendor = pv_now + |battery_target|
-- PV passes through at max; the battery fills the difference. The
-- ~8% overshoot is DC->AC conversion loss (the AC side is what we
-- set); the host's closed loop absorbs it.
--
-- CHARGE (battery_target > 0) is NOT a formula but a guarded one:
-- imported power displaces PV first, and a naive setpoint spirals
-- (curtailed PV -> lower reading -> deeper import). Guards, in order:
--   1. BMS ceiling: read Pwr_limit_Bat_up (46018/46019) fresh at the
--      command and on every refresh; effective charge is capped at
--      that limit minus a 200 W margin. The margin is the reference
--      implementation's finding: command right at the limit and the
--      inverter clips PV while the battery takes ~50 W less than it
--      could -- the gap is what lets PV fill in. Below a 250 W floor
--      the battery is effectively refusing charge (full, cold, BMS
--      hold): release remote control and report why, letting native
--      self-use surplus-charge instead.
--   2. Daylight split (PV string VOLTAGE >= 70 V -- voltage says the
--      panels are awake even when power is ~0 at dawn; power says
--      nothing at night):
--        daylight: vendor = pv_now - p_eff   (import only appears
--                  implicitly when p_eff exceeds live PV)
--        night:    vendor = -p_eff           (pure import; nothing
--                  to displace -- the reference does exactly this)
--   3. Import/export crossing pause: when the computed setpoint
--      changes sign between refreshes, write one cycle of 0 W first.
--      Reference finding: crossing in one step can oscillate.
--   4. Bounded worst case, documented deliberately: if the inverter
--      chooses to curtail PV rather than charge (seen only with a
--      full battery so far), the fresh-PV recomputation converges to
--      import-only charging capped by guard 1 -- wasteful of PV but
--      bounded; it cannot run away. If testing shows curtailment at
--      healthy SoC too, the next step is the reference's P-loop on
--      import power with battery-uptake feedback, not a bigger cap.
--
-- Divergence from the reference, on purpose: it swaps the fallback
-- work mode per direction (FEED_IN_FIRST for discharge, BACK_UP for
-- charge) to bias the inverter's behaviour if remote control drops.
-- This driver keeps SELF_USE as the only fallback: it is the mode the
-- operator runs, it never imports to the battery and never exports
-- the battery, and a dead-man fallback should be boring.
--
-- ============================ SAFETY ===============================
-- Two dead-man's switches: the vendor-side timeout (46002, refreshed
-- every poll; must be >= 60 s -- the master samples this block slowly
-- and a 15 s session expires unseen) and a driver-side 60 s command
-- lease. driver_default_mode releases remote control explicitly.
-- Charge is refused at SoC >= 99%: the inverter ignores its own Max
-- SoC under remote control (reference finding, and this battery
-- reached 100% under FTW charge on 2026-08-05).
--
DRIVER = {
  id = "foxess_h3_smart",
  name = "FoxESS H3-Smart / 1K5",
  manufacturer = "Fox ESS",
  version = "0.7.0",
  host_api_min = 1,
  host_api_max = 1,
  protocols = { "modbus" },
  capabilities = { "pv", "battery", "meter" },
  description = "Fox ESS H3-Smart register map: 1K5-HI series and H3-Smart three-phase hybrids. Modbus-TCP port 502, unit 247. Local control build: battery dispatch via the remote-control block.",
  authors = { "Sourceful Labs AB" },
  tested_models = { "1K5-HI-10-V1" },
  verification_status = "experimental",
  read_only = false,
}

PROTOCOL = "modbus"

-- Blixt L1 loads a target-specific artifact from this same source and
-- validates these promises at load time (tools/driver_package.py
-- requires the table for the blixt-l1 target). `live` mirrors exactly
-- what driver_poll emits; SoC, temperature and the energy counters are
-- omitted from an emit when their block has given up, same as every
-- other field here.
DRIVER_MANIFEST = {
  name = "foxess_h3_smart",
  version = "0.7.0",
  role = "inverter",
  requires = {},
  options = {},
  provides = {
    live = {
      "pv.W", "pv.mppts", "pv.total_generation_Wh",
      "battery.W", "battery.V", "battery.A",
      "battery.SoC_nom_fract", "battery.temperature_C",
      "battery.total_charge_Wh", "battery.total_discharge_Wh",
      "meter.W", "meter.Hz",
      "meter.L1_V", "meter.L2_V", "meter.L3_V",
      "meter.L1_W", "meter.L2_W", "meter.L3_W",
      "meter.L1_A", "meter.L2_A", "meter.L3_A",
      "meter.total_import_Wh", "meter.total_export_Wh",
    },
    static = { "make" },
  },
}

-- Model regs 30000..30015, serial regs 30016..30031, both ASCII.
local MODEL_ADDR  = 30000
-- One block covers inverter state through temperature:
-- pv V/A 39070..39077, grid V 39123..39125, freq 39139, temp 39141.
local STATUS_ADDR  = 39063
local STATUS_COUNT = 79
-- Load and inverter-side battery: load total 39225..39226,
-- battery voltage 39227, current 39228..39229, power total 39237..39238.
local POWER_ADDR  = 39219
local POWER_COUNT = 20
-- PV string power, i32 pairs: pv1 39279.., pv2 39281.., pv3 39283..,
-- pv4 39285...
local PV_ADDR  = 39279
local PV_COUNT = 8
-- Grid CT power, i32 pairs in 0.1 W units. Vendor sign: positive =
-- export. Total at 38814; per-phase R/S/T at 38816/38818/38820 — the
-- site meter's per-phase data feeds FTW's fuse bars.
local CT_ADDR  = 38814
local CT_COUNT = 8
-- Energy counters, u32 pairs in 0.01 kWh: solar 39601.., feed-in
-- 39613.., grid consumption 39617...
local ENERGY_ADDR  = 39601
local ENERGY_COUNT = 18
-- BMS singles (the individual-read-only block).
local SOC_ADDR      = 37612
local BAT_TEMP_ADDR = 37611

-- Remote control block (single-register writes only for enable/timeout;
-- the setpoint is one multi-register write, high word at 46003).
local RC_ENABLE_ADDR  = 46001
local RC_TIMEOUT_ADDR = 46002
local RC_POWER_ADDR   = 46003
local WORK_MODE_ADDR  = 49203
local WORK_MODE_SELF_USE = 1

-- The inverter reverts to its fallback work mode when the timeout
-- expires without a refresh. Hardware-derived floor: the master
-- processor samples the remote-control block slowly, and a 15 s
-- session expired before it ever acted — writes landed, read back
-- correctly, and did nothing. The FoxESS app's own force periods use
-- these same registers with a period-length timeout. 60 s is long
-- enough for the master to act and still reverts the inverter within
-- a minute if this driver dies; the driver-side lease below is the
-- tighter of the two guards.
local RC_TIMEOUT_S = 60
-- Battery charge ceiling register (i32 pair, high word at 46018):
-- how much the battery accepts right now, BMS included.
local BAT_CHARGE_LIMIT_ADDR = 46018
-- See the CHARGE section of the header for all three of these.
local CHARGE_BMS_MARGIN_W = 200
local CHARGE_BMS_FLOOR_W  = 250
local PV_VOLTS_DAYLIGHT   = 70
-- The driver-side lease: without a fresh battery command inside this
-- window, release remote control rather than keep refreshing a stale
-- setpoint forever.
local RC_LEASE_MS = 60000

local identity_reported = false
local rated_w = nil
-- Device-fault latch: only raise/clear on a status block we actually
-- read, and only write the host state on a change (mirrors sungrow).
local fault_active = nil

-- Remote-control state. rc_enabled tracks whether *we* enabled it: the
-- FoxESS app's own strategy periods use the same register, so a driver
-- that did not enable remote control must never write the disable.
local rc_enabled = false
local rc_target_w = nil       -- site convention: positive = charge
local rc_command_ms = 0
local last_soc_fract = nil
-- PV generation as a positive magnitude, from the last poll. The
-- setpoint translation needs it; a command that arrives before the
-- first PV reading is refused rather than guessed.
local last_pv_w = nil
-- Highest PV string voltage from the last poll: the daylight detector.
local last_pv_volts = nil
-- Last AC setpoint written, for the sign-crossing pause.
local prev_vendor_w = nil

-- Sanity bound on the computed setpoint: the translation subtracts two
-- live values, and one bad sample should not ask this hardware for
-- something absurd. Comfortably outside its ~10 kW rating both ways.
local MAX_SETPOINT_W = 15000

local function reg(regs, base, addr)
  return regs[addr - base + 1]
end

local function i32(regs, base, addr)
  return host.decode_i32_be(reg(regs, base, addr), reg(regs, base, addr + 1))
end

local function u32(regs, base, addr)
  return host.decode_u32_be(reg(regs, base, addr), reg(regs, base, addr + 1))
end

-- A block that has stopped answering. The host counts every failed
-- host.modbus_read against the poll whether or not this driver caught
-- the error, so a block retried on every poll costs a failed poll on
-- every poll and the stale-telemetry watchdog takes the driver offline.
-- Three attempts absorb a transient blip; after that we stop asking.
-- A restart re-probes, so firmware that gains the block is picked up.
local GIVE_UP_AFTER = 3
local read_failures = {}

local function read(addr, count)
  if (read_failures[addr] or 0) >= GIVE_UP_AFTER then
    return nil
  end
  local ok, regs = pcall(host.modbus_read, addr, count, "holding")
  if ok and regs and regs[1] ~= nil then
    read_failures[addr] = nil
    return regs
  end
  local failures = (read_failures[addr] or 0) + 1
  read_failures[addr] = failures
  if failures == GIVE_UP_AFTER then
    host.log("info", string.format(
      "foxess_h3_smart: block %d did not answer %d times; leaving it " ..
      "alone until restart", addr, GIVE_UP_AFTER))
  end
  return nil
end

local function report_identity()
  local regs = read(MODEL_ADDR, 32)
  if not regs then
    return
  end
  local model  = host.decode_string(regs, 1, 16)
  local serial = host.decode_string(regs, 17, 16)
  if model == "" then
    return
  end
  host.set_model(model)
  if serial ~= "" then
    host.set_sn(serial)
  end
  -- Rated power straight from the family name: 1K5-HI-<kW>-V1.
  local kw = model:match("^1K5%-HI%-(%d+)")
  if kw then
    rated_w = tonumber(kw) * 1000
    pcall(host.set_rated_w, rated_w)
  end
  if not model:find("^1K5%-") and not model:find("^H3%-") then
    host.log("warn", "foxess_h3_smart: model '" .. model ..
      "' is not a known H3-Smart-map family; telemetry may be wrong")
  end
  identity_reported = true
end

function driver_init(config)
  host.set_make("FoxESS")
end

local function read_battery_charge_limit_w()
  local regs = read(BAT_CHARGE_LIMIT_ADDR, 2)
  if not regs then
    return nil
  end
  -- Sign varies by model/firmware (the reference expects negative,
  -- this hardware has read positive); the magnitude is the limit.
  local v = math.abs(host.decode_i32_be(regs[1], regs[2]))
  if v > 20000 then
    return nil -- implausible for this hardware; treat as unreadable
  end
  return v
end

-- Translate a battery target (site convention, charge-positive) into
-- the vendor AC setpoint. Returns vendor watts, or nil + reason.
-- See the header for the model and every guard's justification.
local function compute_vendor(battery_target_w)
  if battery_target_w <= 0 then
    -- Discharge, and HOLD-AT-ZERO: AC = pv - target, so target 0 pins
    -- the battery at 0 with all PV flowing to house + grid. Zero must
    -- be an enforced setpoint, not a release: this inverter's
    -- uncommanded state is self-use, which absorbs the surplus into
    -- the battery -- and a controller that commands 0, releases, and
    -- watches native charging surge back gets a ~90 s limit cycle
    -- (observed live 2026-08-05: steady 3 kW PV, battery saw-toothing
    -- 250..2300 W against FTW's absorb ceiling).
    if last_pv_w == nil then
      return nil, "no PV reading yet"
    end
    return last_pv_w - battery_target_w
  end
  -- Charge: guard 1, the live BMS ceiling.
  local limit = read_battery_charge_limit_w()
  if limit == nil then
    return nil, "battery charge limit unreadable"
  end
  if limit < CHARGE_BMS_FLOOR_W then
    return nil, "battery is not accepting charge now"
  end
  local p_eff = math.min(battery_target_w, limit - CHARGE_BMS_MARGIN_W)
  -- Guard 2: daylight by string voltage, not power.
  if (last_pv_volts or 0) >= PV_VOLTS_DAYLIGHT then
    if last_pv_w == nil then
      return nil, "no PV reading yet"
    end
    return last_pv_w - p_eff
  end
  return -p_eff
end

local function write_setpoint(battery_target_w)
  local vendor, why = compute_vendor(battery_target_w)
  if vendor == nil then
    return false, why
  end
  if vendor > MAX_SETPOINT_W then
    vendor = MAX_SETPOINT_W
  elseif vendor < -MAX_SETPOINT_W then
    vendor = -MAX_SETPOINT_W
  end
  -- Guard 3: one cycle of 0 W when crossing import/export.
  if prev_vendor_w ~= nil and
     ((prev_vendor_w > 0 and vendor < 0) or (prev_vendor_w < 0 and vendor > 0)) then
    vendor = 0
  end
  prev_vendor_w = vendor
  -- Two's complement from the signed value directly. Adding 2^32 first
  -- would be exact only where Lua numbers are doubles; Lua's modulo is
  -- floored, so this yields the same two words while every operand
  -- stays small enough for a single-precision host.
  local hi = math.floor(vendor / 65536) % 65536
  local lo = vendor % 65536
  return pcall(host.write_registers, RC_POWER_ADDR, { hi, lo })
end

local function apply_remote_control(site_w)
  if not rc_enabled then
    -- Fallback first: if we vanish and the timeout fires, the inverter
    -- lands in self-use rather than whatever mode was last configured.
    local ok, mode = pcall(host.modbus_read, WORK_MODE_ADDR, 1, "holding")
    if ok and mode and mode[1] ~= nil and mode[1] ~= WORK_MODE_SELF_USE then
      pcall(host.write, WORK_MODE_ADDR, WORK_MODE_SELF_USE)
    end
    if not pcall(host.write, RC_TIMEOUT_ADDR, RC_TIMEOUT_S) then return false end
    if not pcall(host.write, RC_ENABLE_ADDR, 1) then return false end
    rc_enabled = true
  end
  return write_setpoint(site_w)
end

local function release_remote_control()
  rc_target_w = nil
  prev_vendor_w = nil
  if rc_enabled then
    rc_enabled = false
    pcall(host.write, RC_ENABLE_ADDR, 0)
  end
end

function driver_poll()
  if not identity_reported then
    report_identity()
  end

  local status = read(STATUS_ADDR, STATUS_COUNT)
  local power  = read(POWER_ADDR, POWER_COUNT)
  local pv     = read(PV_ADDR, PV_COUNT)
  local ct     = read(CT_ADDR, CT_COUNT)
  local energy = read(ENERGY_ADDR, ENERGY_COUNT)

  -- ---- PV ----
  -- A string that reads all-zero V, A and W is not fitted; trailing
  -- absent strings are dropped so `mppts` is as long as the hardware.
  if status and pv then
    local mppts = {}
    local last_present = 0
    for s = 0, 3 do
      local v = reg(status, STATUS_ADDR, 39070 + 2 * s) * 0.1
      local a = reg(status, STATUS_ADDR, 39071 + 2 * s) * 0.01
      local w = i32(pv, PV_ADDR, PV_ADDR + 2 * s)
      if w < 0 then w = 0 end
      mppts[s + 1] = { V = v, A = a, W = w }
      if v ~= 0 or a ~= 0 or w ~= 0 then
        last_present = s + 1
      end
    end
    local pv_w = 0
    for s = 1, last_present do
      pv_w = pv_w + mppts[s].W
    end
    for s = #mppts, last_present + 1, -1 do
      mppts[s] = nil
    end

    local pv_out = {}
    pv_out.W = -pv_w
    pv_out.mppts = mppts
    if rated_w then
      pv_out.rated_w = rated_w
    end
    -- Inverter heatsink temperature rides the pv stream, sungrow-style.
    pv_out.temp_c = host.decode_i16(reg(status, STATUS_ADDR, 39141)) * 0.1
    if energy then
      pv_out.total_generation_Wh = u32(energy, ENERGY_ADDR, 39601) * 10
    end
    last_pv_w = pv_w
    local volts = 0
    for s = 1, #mppts do
      if mppts[s].V > volts then volts = mppts[s].V end
    end
    last_pv_volts = volts
    host.emit("pv", pv_out)
  end

  -- ---- Battery ----
  -- Vendor sign: positive = discharge. Site convention: positive = charge.
  if power then
    local bat_out = {}
    bat_out.W = -i32(power, POWER_ADDR, 39237)
    bat_out.V = reg(power, POWER_ADDR, 39227) * 0.1
    bat_out.A = -i32(power, POWER_ADDR, 39228) * 0.001
    local soc = read(SOC_ADDR, 1)
    if soc then
      local fract = soc[1] / 100
      if fract >= 0 and fract <= 1 then
        bat_out.SoC_nom_fract = fract
        last_soc_fract = fract
      end
    end
    local bat_temp = read(BAT_TEMP_ADDR, 1)
    if bat_temp then
      bat_out.temperature_C = host.decode_i16(bat_temp[1]) * 0.1
    end
    -- Lifetime counters live in the energy block this poll already
    -- read; added only when it answered (a zero would read as a reset
    -- meter).
    if energy then
      bat_out.total_charge_Wh    = u32(energy, ENERGY_ADDR, 39605) * 10
      bat_out.total_discharge_Wh = u32(energy, ENERGY_ADDR, 39609) * 10
    end
    host.emit("battery", bat_out)
  end

  -- ---- Meter ----
  -- Vendor sign: positive = export. Site convention: positive = import.
  if ct then
    local met_out = {}
    met_out.W = -i32(ct, CT_ADDR, CT_ADDR) * 0.1
    if status then
      met_out.Hz   = reg(status, STATUS_ADDR, 39139) * 0.01
      met_out.L1_V = reg(status, STATUS_ADDR, 39123) * 0.1
      met_out.L2_V = reg(status, STATUS_ADDR, 39124) * 0.1
      met_out.L3_V = reg(status, STATUS_ADDR, 39125) * 0.1
      -- Per-phase CT power (site sign: import-positive), amps derived
      -- as W/V so the sign carries through — FTW's fuse bars read
      -- l1_a..l3_a signed, negative meaning export on that phase.
      met_out.L1_W = -i32(ct, CT_ADDR, 38816) * 0.1
      met_out.L2_W = -i32(ct, CT_ADDR, 38818) * 0.1
      met_out.L3_W = -i32(ct, CT_ADDR, 38820) * 0.1
      if met_out.L1_V > 0 then met_out.L1_A = met_out.L1_W / met_out.L1_V end
      if met_out.L2_V > 0 then met_out.L2_A = met_out.L2_W / met_out.L2_V end
      if met_out.L3_V > 0 then met_out.L3_A = met_out.L3_W / met_out.L3_V end
    end
    if energy then
      met_out.total_import_Wh = u32(energy, ENERGY_ADDR, 39617) * 10
      met_out.total_export_Wh = u32(energy, ENERGY_ADDR, 39613) * 10
    end
    host.emit("meter", met_out)
  end

  -- Fault codes 39067..39069 (already in the status read): any
  -- nonzero raises a device fault carrying the codes; all-zero clears.
  -- Both transitions require a status block we actually read — a
  -- failed read must neither raise nor clear.
  if status then
    local f1 = reg(status, STATUS_ADDR, 39067) or 0
    local f2 = reg(status, STATUS_ADDR, 39068) or 0
    local f3 = reg(status, STATUS_ADDR, 39069) or 0
    local faulted = (f1 ~= 0 or f2 ~= 0 or f3 ~= 0)
    if faulted and fault_active ~= true then
      host.set_device_fault(true, string.format(
        "inverter fault codes %d/%d/%d", f1, f2, f3))
      fault_active = true
    elseif not faulted and fault_active ~= false then
      host.set_device_fault(false, "")
      fault_active = false
    end
    -- Diagnostics for the metric browser: the values this week's
    -- debugging kept needing and never had.
    host.emit_metric("inverter_temp_c",
      host.decode_i16(reg(status, STATUS_ADDR, 39141)) * 0.1)
    host.emit_metric("foxess_inverter_state", reg(status, STATUS_ADDR, 39063) or -1)
  end
  host.emit_metric("foxess_rc_enabled", rc_enabled and 1 or 0)
  if prev_vendor_w ~= nil then
    host.emit_metric("foxess_rc_setpoint_w", prev_vendor_w)
  end

  -- Keep an active setpoint alive: the vendor timeout needs a
  -- refresh every poll, and the lease releases control when the EMS
  -- stops commanding instead of holding a stale target forever.
  if rc_target_w ~= nil then
    if host.millis() - rc_command_ms > RC_LEASE_MS then
      host.log("info", "foxess_h3_smart: battery command lease expired; releasing remote control")
      release_remote_control()
    else
      local ok, why = apply_remote_control(rc_target_w)
      if not ok and why ~= nil then
        -- The setpoint is no longer computable (battery stopped
        -- accepting charge, PV reading lost). Holding the session
        -- would freeze the last written value; native self-use is the
        -- safer place to wait.
        host.log("warn", "foxess_h3_smart: releasing remote control: " .. why)
        release_remote_control()
      end
    end
  end

  return 5000
end

function driver_command(action, value, context)
  if action == "init" or action == "deinit" then
    return true
  end
  if action ~= "battery" then
    return "unsupported action: " .. tostring(action)
  end
  local power_w = tonumber(value)
  if power_w == nil then
    return "battery command needs a numeric power_w"
  end
  -- power_w == 0 is a real setpoint (hold the battery at zero), not a
  -- release. Release happens on lease expiry and driver_default_mode.

  -- Under remote control the inverter ignores its own Max SoC, so a
  -- charge command into a full pack must be refused here.
  if power_w > 0 and last_soc_fract ~= nil and last_soc_fract >= 0.99 then
    return "battery is full; refusing forced charge"
  end
  rc_target_w = power_w
  rc_command_ms = host.millis()
  local ok, why = apply_remote_control(power_w)
  if not ok then
    rc_target_w = nil
    return why or "remote control write failed"
  end
  return true
end

function driver_default_mode()
  -- Safe state: the inverter's own self-use logic. Release remote
  -- control; if the write cannot go through, the vendor timeout
  -- reverts the inverter on its own within RC_TIMEOUT_S.
  release_remote_control()
end

function driver_cleanup()
  release_remote_control()
end
