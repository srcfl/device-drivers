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

DRIVER = {
  id = "foxess_h3_smart",
  name = "FoxESS H3-Smart / 1K5",
  manufacturer = "Fox ESS",
  version = "0.1.0",
  host_api_min = 1,
  host_api_max = 1,
  protocols = { "modbus" },
  capabilities = { "pv", "battery", "meter" },
  description = "Fox ESS H3-Smart register map: 1K5-HI series and H3-Smart three-phase hybrids. Modbus-TCP port 502, unit 247.",
  authors = { "Sourceful Labs AB" },
  tested_models = { "1K5-HI-10-V1" },
  verification_status = "experimental",
  read_only = true,
}

PROTOCOL = "modbus"

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

local identity_reported = false

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
      end
    end
    local bat_temp = read(BAT_TEMP_ADDR, 1)
    if bat_temp then
      out.temperature_C = host.decode_i16(bat_temp[1]) * 0.1
    end
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
    host.emit("meter", out)
  end

  return 5000
end

function driver_default_mode()
  -- Read-only driver: the safe state is to keep reading and command nothing.
end

function driver_cleanup()
end
