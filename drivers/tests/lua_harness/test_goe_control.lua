-- go-e Modbus: power orders become whole amps on AMPERE_VOLATILE, start and
-- stop go through FORCE_STATE, writes happen only on a change, default mode
-- stops the charger once, and a refused write fails.
dofile("drivers/tests/lua_harness/host_mock.lua")
local DRIVER_PATH = "drivers/lua/goe.lua"

local function u32(input, addr, value)
  input[addr] = math.floor(value / 65536)
  input[addr + 1] = math.floor(value % 65536)
end

-- amps: per-phase current in A; v: per-phase voltage.
local function boot(over, conf)
  over = over or {}
  host.reset()
  local input, holding = {}, {}
  input[100] = over.car or 3
  input[107] = 0
  local v = over.v or 230
  local amps = over.amps or { 0, 0, 0 }
  for i = 0, 2 do
    u32(input, 108 + 2 * i, v)
    u32(input, 114 + 2 * i, math.floor(amps[i + 1] * 10))
  end
  u32(input, 120, math.floor((amps[1] + amps[2] + amps[3]) * v * 100))
  u32(input, 128, 3456)          -- 345.6 kWh
  u32(input, 132, 432000)        -- 4 320 000 Ws = 1200 Wh
  input[200] = over.allow or 1
  input[304], input[305], input[306] = 0x3132, 0x3334, 0x3536   -- "123456"
  input[307], input[308], input[309] = 0, 0, 0
  holding[211] = over.ama or 32
  holding[299] = over.amp or 16
  holding[337] = over.frc or 0
  host._modbus_registers = { input = input, holding = holding }
  driver_init, driver_poll, driver_command, driver_default_mode = nil, nil, nil, nil
  dofile(DRIVER_PATH)
  local c = { host = "192.0.2.10", port = 502, unit_id = 1 }
  for k, v in pairs(conf or {}) do c[k] = v end
  driver_init(c)
  driver_poll()
end

local function writes()
  local out = {}
  for _, call in ipairs(host._calls) do
    if call.func == "modbus_write_multiple" then
      out[#out + 1] = { addr = call.args[1], value = call.args[2][1] }
    end
  end
  return out
end
local function reg(addr) return host._modbus_registers.holding[addr] end
local THREE = { phase_mode = "3p", voltage = 230 }
local function order(w, cmd) return driver_command("ev_set_current", w, cmd or THREE) end
local function check(cond, msg) if not cond then error(msg, 2) end end

-- 1. Power to amps.
boot()
check(order(4140), "6 A order failed")
local w = writes()
check(#w == 2 and w[1].addr == 299 and w[1].value == 6 and w[2].addr == 337 and w[2].value == 2,
  "4140 W 3p should write AMPERE_VOLATILE=6 then FORCE_STATE=2")
check(#writes() == 2 and reg(300) == nil, "AMPERE_EEPROM (300) must never be written")

boot()
check(order(11000), "11 kW order failed")
check(reg(299) == 15, "11000 W 3p should be 15 A, got " .. tostring(reg(299)))

boot()
check(order(4139), "4139 W order failed")
check(reg(337) == 1 and reg(299) == 16, "5.99 A must stop the charger and leave the current alone")

-- A "1p" order on an idle charger divides by three: idle proves nothing.
boot()
check(order(6900, { phase_mode = "1p", voltage = 230 }), "1p order on an idle charger failed")
check(reg(299) == 10, "6900 W 1p on an idle charger should be P/(3V) = 10 A, got " .. tostring(reg(299)))
boot({ car = 2, amps = { 10, 0, 0 } })
check(order(3680, { phase_mode = "1p", voltage = 230 }), "1p order on one phase failed")
check(reg(299) == 16, "3680 W 1p on one measured phase should be 16 A")
boot(nil, { phases = 1 })
check(order(3680), "order on a one-phase installation failed")
check(reg(299) == 16, "3680 W on an idle one-phase installation should be 16 A")
boot({ car = 2, amps = { 10, 10, 10 } }, { phases = 1 })
check(order(6900), "order with three live phases failed")
check(reg(299) == 10, "three live phases override phases = 1")

boot({ car = 2, amps = { 10, 10, 10 } })
check(order(3680, { phase_mode = "1p", voltage = 230 }), "1p order on three phases failed")
check(reg(337) == 1, "3680 W over three measured phases is 5.3 A and must stop")

boot()
check(order(22000, { phase_mode = "3p", voltage = 230, max_amps_per_phase = 10 }), "fuse cap order failed")
check(reg(299) == 10, "max_amps_per_phase must cap the order")
boot()
check(order(22000, { phase_mode = "3p", voltage = 230, max_amps_per_phase = 25, cap_amps_per_phase = 7.9 }), "cap order failed")
check(reg(299) == 7, "cap_amps_per_phase 7.9 must cap at 7 A")
boot({ ama = 12 })
check(order(22000), "AMPERE_MAX order failed")
check(reg(299) == 12, "AMPERE_MAX 12 must cap the order")
boot()
check(order(22000, { phase_mode = "3p", voltage = 230 }), "32 A order failed")
check(reg(299) == 31, "22000 W 3p is 31.9 A, rounded down to 31")

-- 2. Writes only on change.
boot()
check(order(6900), "10 A order failed")
local n = #writes()
check(order(6900), "repeat order failed")
driver_poll()
check(order(6900), "repeat order after a poll failed")
check(#writes() == n, "an unchanged order wrote again")
check(order(4140), "decrease failed")
w = writes()
check(#w == n + 1 and w[#w].addr == 299 and w[#w].value == 6, "a decrease writes the current alone")
-- The charger rebooted and went back to its saved current: write again.
host._modbus_registers.holding[299] = 16
driver_poll()
check(order(4140), "order after reboot failed")
check(#writes() == n + 2 and reg(299) == 6, "a current the charger lost must be written again")

-- 3. Pause and resume.
boot()
check(order(6900), "order before pause failed")
check(driver_command("ev_pause", 0, {}), "pause failed")
check(reg(337) == 1, "pause should write FORCE_STATE=1")
n = #writes()
check(driver_command("ev_resume", 0, {}), "resume failed")
check(reg(337) == 2 and reg(299) == 10 and #writes() == n + 1, "resume writes FORCE_STATE=2 at the last order")

-- 4. Default mode does nothing until FTW wrote, then settles.
boot()
for _ = 1, 3 do check(driver_default_mode() == true, "default mode on a fresh driver failed") end
check(#writes() == 0, "default mode on a fresh driver wrote")
check(order(6900), "order before default failed")
n = #writes()
for _ = 1, 5 do check(driver_default_mode() == true, "default mode failed") end
check(#writes() == n + 1 and reg(337) == 1, "default mode should write FORCE_STATE=1 once")
boot({ frc = 1 })
for _ = 1, 3 do driver_default_mode() end
check(#writes() == 0, "default mode wrote to a charger that was already off")

-- 5. A refused write returns false, and default mode stops trying.
boot()
host._modbus_write_error = "modbus exception function=0x10 code=0x02"
check(order(6900) == false, "a refused current write must return false")
check(#writes() == 1, "after a refused current FORCE_STATE must not be written")
check(driver_command("ev_pause", 0, {}) == false, "a refused stop must return false")
boot()
check(order(6900), "order before refusal failed")
local base = #writes()
host._modbus_write_error = "modbus exception function=0x10 code=0x02"
local results = {}
for i = 1, 6 do results[i] = driver_default_mode() end
check(#writes() - base == 3, "default mode should stop after three refusals, wrote " .. (#writes() - base))
check(results[1] == false and results[4] == true, "false while trying, true once it holds")

-- 6. Readings.
boot({ car = 2, amps = { 8, 8, 8 }, amp = 10, frc = 2 })
local ev = host._emitted.ev[#host._emitted.ev]
check(math.abs(ev.w - 3 * 8 * 230) < 1, "w should be POWER_TOTAL in W, got " .. tostring(ev.w))
check(ev.connected == true and ev.charging == true, "car 2 is connected and charging")
check(ev.max_a == 10 and ev.phases == 3, "max_a is AMPERE_VOLATILE, phases are measured")
check(math.abs(ev.session_wh - 1200) < 0.01 and ev.lifetime_wh == 345600, "energy units")
check(math.abs(ev.l1_a - 8) < 0.001 and ev.l1_v == 230, "per-phase readings")
check(host._sn == "123456", "serial number not set")
boot({ frc = 1 })
ev = host._emitted.ev[#host._emitted.ev]
check(ev.max_a == 0 and ev.connected == true and ev.charging == false, "a charger forced off offers 0 A")
boot()
local before = #host._emitted.ev
host._modbus_read_fail_addresses[107] = "timeout"
driver_poll()
check(#host._emitted.ev == before, "a failed measurement read must not emit")

print("PASS test_goe_control")
