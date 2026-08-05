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
-- The remote-control setpoint (46003/46004) is a GRID active-power
-- setpoint, not a battery-power setpoint. Hardware proof, 2026-08-05:
-- with the battery charging on PV surplus and the meter at -4 W, a
-- "charge 500 W" command written straight through made the site import
-- 590 W and the battery charge ~590 W *above* the surplus. The
-- inverter had obeyed exactly what was asked of it: import 500 W.
-- Discharge hid this for two days, because for discharge both readings
-- move the grid the same way and the host's closed loop converged
-- anyway.
--
-- So a battery target must be translated. Solving
--   grid = load + battery + pv   (site convention, all signed)
-- for the grid setpoint that yields the requested battery power, with
-- load and pv cancelling out, leaves a form that needs no load
-- measurement at all:
--   desired_grid = grid_now + (battery_target - battery_now)
-- and the vendor register is import-negative, so it receives
-- -desired_grid. Each poll recomputes this from fresh readings, so PV
-- and load drift correct themselves on the next tick rather than
-- integrating. Two
-- dead-man's switches protect the inverter: the vendor-side timeout
-- (46002, refreshed every poll) reverts it if this driver dies, and a
-- driver-side lease releases remote control when the EMS stops sending
-- commands. driver_default_mode releases control explicitly.

DRIVER = {
  id = "foxess_h3_smart",
  name = "FoxESS H3-Smart / 1K5",
  manufacturer = "Fox ESS",
  version = "0.3.0",
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
  version = "0.3.0",
  role = "inverter",
  requires = {},
  options = {},
  provides = {
    live = {
      "pv.W", "pv.mppts", "pv.total_generation_Wh",
      "battery.W", "battery.V", "battery.A",
      "battery.SoC_nom_fract", "battery.temperature_C",
      "meter.W", "meter.Hz",
      "meter.L1_V", "meter.L2_V", "meter.L3_V",
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
-- Grid CT total power, i32, 0.1 W units. Vendor sign: positive = export.
local CT_ADDR  = 38814
local CT_COUNT = 2
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
-- The driver-side lease: without a fresh battery command inside this
-- window, release remote control rather than keep refreshing a stale
-- setpoint forever.
local RC_LEASE_MS = 60000

local identity_reported = false

-- Remote-control state. rc_enabled tracks whether *we* enabled it: the
-- FoxESS app's own strategy periods use the same register, so a driver
-- that did not enable remote control must never write the disable.
local rc_enabled = false
local rc_target_w = nil       -- site convention: positive = charge
local rc_command_ms = 0
local last_soc_fract = nil
-- Last polled site-convention readings, needed to translate a battery
-- target into the grid setpoint the inverter actually accepts. nil
-- until the first successful poll of each; a command that cannot be
-- translated is refused rather than guessed.
local last_grid_w = nil
local last_bat_w = nil

-- Sanity bound on the computed grid setpoint. The translation is a
-- subtraction of two live readings, so one bad telemetry sample could
-- otherwise ask the inverter for something absurd. Comfortably above
-- this hardware's ~10 kW rating in both directions.
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
  if not model:find("^1K5%-") and not model:find("^H3%-") then
    host.log("warn", "foxess_h3_smart: model '" .. model ..
      "' is not a known H3-Smart-map family; telemetry may be wrong")
  end
  identity_reported = true
end

function driver_init(config)
  host.set_make("FoxESS")
end

local function write_setpoint(battery_target_w)
  -- Translate a battery target into the grid setpoint that produces it
  -- under the conditions this driver last measured. See the header.
  if last_grid_w == nil or last_bat_w == nil then
    return false
  end
  local desired_grid = last_grid_w + (battery_target_w - last_bat_w)
  local vendor = -desired_grid
  if vendor > MAX_SETPOINT_W then
    vendor = MAX_SETPOINT_W
  elseif vendor < -MAX_SETPOINT_W then
    vendor = -MAX_SETPOINT_W
  end
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
  local ok = write_setpoint(site_w)
  return ok
end

local function release_remote_control()
  rc_target_w = nil
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

    local out = {}
    out.W = -pv_w
    out.mppts = mppts
    if energy then
      out.total_generation_Wh = u32(energy, ENERGY_ADDR, 39601) * 10
    end
    host.emit("pv", out)
  end

  -- ---- Battery ----
  -- Vendor sign: positive = discharge. Site convention: positive = charge.
  if power then
    local out = {}
    out.W = -i32(power, POWER_ADDR, 39237)
    out.V = reg(power, POWER_ADDR, 39227) * 0.1
    out.A = -i32(power, POWER_ADDR, 39228) * 0.001
    local soc = read(SOC_ADDR, 1)
    if soc then
      local fract = soc[1] / 100
      if fract >= 0 and fract <= 1 then
        out.SoC_nom_fract = fract
        last_soc_fract = fract
      end
    end
    local bat_temp = read(BAT_TEMP_ADDR, 1)
    if bat_temp then
      out.temperature_C = host.decode_i16(bat_temp[1]) * 0.1
    end
    last_bat_w = out.W
    host.emit("battery", out)
  end

  -- ---- Meter ----
  -- Vendor sign: positive = export. Site convention: positive = import.
  if ct then
    local out = {}
    out.W = -i32(ct, CT_ADDR, CT_ADDR) * 0.1
    if status then
      out.Hz   = reg(status, STATUS_ADDR, 39139) * 0.01
      out.L1_V = reg(status, STATUS_ADDR, 39123) * 0.1
      out.L2_V = reg(status, STATUS_ADDR, 39124) * 0.1
      out.L3_V = reg(status, STATUS_ADDR, 39125) * 0.1
    end
    if energy then
      out.total_import_Wh = u32(energy, ENERGY_ADDR, 39617) * 10
      out.total_export_Wh = u32(energy, ENERGY_ADDR, 39613) * 10
    end
    last_grid_w = out.W
    host.emit("meter", out)
  end

  -- Keep an active setpoint alive: the vendor timeout needs a
  -- refresh every poll, and the lease releases control when the EMS
  -- stops commanding instead of holding a stale target forever.
  if rc_target_w ~= nil then
    if host.millis() - rc_command_ms > RC_LEASE_MS then
      host.log("info", "foxess_h3_smart: battery command lease expired; releasing remote control")
      release_remote_control()
    else
      apply_remote_control(rc_target_w)
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
  if power_w == 0 then
    release_remote_control()
    return true
  end
  -- Under remote control the inverter ignores its own Max SoC, so a
  -- charge command into a full pack must be refused here.
  if power_w > 0 and last_soc_fract ~= nil and last_soc_fract >= 0.99 then
    return "battery is full; refusing forced charge"
  end
  rc_target_w = power_w
  rc_command_ms = host.millis()
  if not apply_remote_control(power_w) then
    return "remote control write failed"
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
