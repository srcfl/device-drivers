-- Tesla Wall Connector Gen 3: charge power comes only through a closed
-- contactor with a car on the cable, from measured volts and amps.
dofile("drivers/tests/lua_harness/host_mock.lua")

local BASE = "http://wc.test"

local function poll(vitals, config)
  host.reset()
  host._http_responses[BASE .. "/api/1/version"] =
    '{"serial_number":"TWC-SN-1","part_number":"1529455-02-J","firmware_version":"24.36.3"}'
  host._http_responses[BASE .. "/api/1/vitals"] = vitals
  dofile("drivers/lua/tesla_wall_connector.lua")
  config = config or {}
  config.base_url = BASE
  driver_init(config)
  assert(driver_poll() == 5000)
  local ev = host._emitted.ev
  assert(ev and #ev == 1, "one ev reading per poll")
  return ev[1]
end

local function near(got, want, tol, label)
  assert(math.abs(got - want) <= tol,
    string.format("%s: got %.1f W, want %.1f W", label, got, want))
end

-- A real idle unit: no car, contactor open, 0 V on every output leg, and
-- 0.8 A and 0.6 A of sensor offset on legs A and B. The connection test
-- read EV 184 W, which is grid_v × vehicle_current_a (230 V × 0.8 A).
-- The report did not show those two fields; these are the values that
-- give 184 W.
local idle = [[{"contactor_closed":false,"vehicle_connected":false,"session_s":0,
"grid_v":230.0,"grid_hz":50.01,"vehicle_current_a":0.8,
"currentA_a":0.8,"currentB_a":0.6,"currentC_a":0.0,"currentN_a":0.0,
"voltageA_v":0.0,"voltageB_v":0.0,"voltageC_v":0.0,
"relay_coil_v":11.9,"pcba_temp_c":21.3,"handle_temp_c":14.2,"mcu_temp_c":27.5,
"uptime_s":86400,"input_thermopile_uv":-210,"prox_v":0.0,
"pilot_high_v":11.9,"pilot_low_v":11.9,"session_energy_wh":0.0,
"config_status":5,"evse_state":1,"current_alerts":[]}]]
local r = poll(idle)
assert(r.w == 0, "idle unit with open contactor reported " .. tostring(r.w) .. " W")
assert(r.connected == false and r.charging == false)
assert(host._metrics.ev_power_w.value == 0, "ev_power_w must match w")
-- The raw sensor reading stays visible as a diagnostic.
assert(host._metrics.ev_l1_a.value == 0.8 and host._metrics.ev_l1_v.value == 0)

-- A larger offset sample (the diagram showed 284 W) is still no load.
r = poll((idle:gsub('"vehicle_current_a":0.8', '"vehicle_current_a":1.2')
  :gsub('"grid_v":230.0', '"grid_v":236.7')))
assert(r.w == 0, "offset sample reported " .. tostring(r.w) .. " W")

-- A reply without contactor_closed: no car means no charge power.
r = poll('{"vehicle_connected":false,"evse_state":1,"grid_v":230,"vehicle_current_a":0.8,'
  .. '"currentA_a":0.8,"currentB_a":0.6,"voltageA_v":0,"voltageB_v":0,"voltageC_v":0}')
assert(r.w == 0 and r.charging == false)

-- Car on the cable, contactor open (waiting or finished): still no load.
r = poll((idle:gsub('"vehicle_connected":false', '"vehicle_connected":true')
  :gsub('"evse_state":1', '"evse_state":9')))
assert(r.w == 0, "open contactor with car reported " .. tostring(r.w) .. " W")
assert(r.connected == true and r.charging == false)

-- The EVSE state alone does not close the contactor.
r = poll((idle:gsub('"vehicle_connected":false', '"vehicle_connected":true')
  :gsub('"evse_state":1', '"evse_state":11')))
assert(r.w == 0 and r.charging == false, "state 11 with open contactor")

-- No car on the cable: nothing reaches a car, whatever the contactor says.
r = poll((idle:gsub('"contactor_closed":false', '"contactor_closed":true')))
assert(r.w == 0 and r.charging == false, "closed contactor without a car")

-- Split-phase installs use grid_v × vehicle_current_a: the same gate holds.
r = poll(idle, { split_phase = true })
assert(r.w == 0, "split-phase idle reported " .. tostring(r.w) .. " W")

-- Three-phase charging: the sum of measured V × A on each leg, positive.
local charging3 = [[{"contactor_closed":true,"vehicle_connected":true,"session_s":1800,
"grid_v":230.0,"grid_hz":50.0,"vehicle_current_a":16.0,
"currentA_a":16.1,"currentB_a":16.0,"currentC_a":16.2,"currentN_a":0.3,
"voltageA_v":230.0,"voltageB_v":229.5,"voltageC_v":230.4,
"session_energy_wh":4200.0,"config_status":5,"evse_state":11,"current_alerts":[]}]]
r = poll(charging3)
-- 230×16.1 + 229.5×16.0 + 230.4×16.2 = 11107.48
near(r.w, 11107.48, 0.01, "three-phase charging")
assert(r.connected == true and r.charging == true and r.phases == 3)
assert(r.session_wh == 4200)
assert(host._metrics.ev_power_w.value == r.w)

-- One-phase car: unused legs sit at a few volts and do not count.
r = poll([[{"contactor_closed":true,"vehicle_connected":true,"grid_v":230,
"vehicle_current_a":16,"currentA_a":16,"currentB_a":0.2,"currentC_a":0.1,
"voltageA_v":230,"voltageB_v":2.4,"voltageC_v":1.8,"session_energy_wh":100,"evse_state":11}]])
near(r.w, 3680, 0.01, "one-phase charging")
assert(r.phases == 1 and r.charging == true)

-- Contactor closed but no usable leg voltage: the contactor joins the
-- car to the grid, so the measured grid voltage applies.
r = poll([[{"contactor_closed":true,"vehicle_connected":true,"grid_v":230,
"vehicle_current_a":10,"voltageA_v":2,"voltageB_v":1,"voltageC_v":0,
"session_energy_wh":1,"evse_state":11}]])
near(r.w, 2300, 0.01, "closed contactor, grid voltage")

-- Split-phase charging: grid_v × vehicle_current_a.
r = poll([[{"contactor_closed":true,"vehicle_connected":true,"grid_v":240,
"vehicle_current_a":32,"currentA_a":40,"currentB_a":40,
"voltageA_v":120,"voltageB_v":120,"session_energy_wh":50,"evse_state":11}]],
  { split_phase = true })
near(r.w, 7680, 0.01, "split-phase charging")

-- A reply without contactor_closed falls back to the EVSE state.
r = poll([[{"vehicle_connected":true,"evse_state":11,"grid_v":230,"vehicle_current_a":16,
"currentA_a":16,"voltageA_v":230,"voltageB_v":0,"voltageC_v":0}]])
near(r.w, 3680, 0.01, "no contactor field, charging state")
assert(r.charging == true)

print("tesla_wall_connector: all cases pass")
