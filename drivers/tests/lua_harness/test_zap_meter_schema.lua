-- Exercise zap.lua's meter field reading against both the v1 and v2 Zap
-- local API field names. Run with the scenario as arg[1]: "v1" or "v2".
--
-- This file is a draft for drivers/tests/lua_harness/test_zap_meter_schema.lua
-- in srcfl/device-drivers — see pr-drafts/README.md for how this fits that
-- repo's `make test-driver ID=zap` harness. Not run against the real harness
-- yet (no local checkout with lua55/pytest); matches the structure of the
-- existing drivers/tests/lua_harness/test_esphome_dsmr_aliases.lua, which
-- solves the same kind of field-name-aliasing problem.

local scenario = arg[1]
if scenario ~= "v1" and scenario ~= "v2" then
    error("schema scenario must be v1 or v2")
end

dofile("drivers/tests/lua_harness/host_mock.lua")
host.reset()

local function respond(path, body)
    host._http_responses["http://127.0.0.1" .. path] = body
end

-- The device list is unaffected by the v2 meter-field rename (see
-- https://github.com/srcfl/device-drivers/issues/170 — only `ders[].type`
-- for pv/battery changes, not for the P1 meter), so both scenarios use the
-- same /api/devices response.
respond("/api/devices", [[
{"devices":[{"sn":"TESTZAP-P1-1","type":"p1_uart","device_type":"energy_meter",
  "ders":[{"type":"meter","enabled":true}]}]}
]])

if scenario == "v1" then
    respond("/api/devices/TESTZAP-P1-1/data/json", [[
{"meter":{"W":1850,"Hz":50.0,
  "L1_W":600,"L1_V":230.1,"L1_A":2.61,
  "L2_W":600,"L2_V":230.4,"L2_A":2.60,
  "L3_W":650,"L3_V":229.8,"L3_A":2.83,
  "total_import_Wh":58000000,"total_export_Wh":9000000}}
]])
else
    respond("/api/devices/TESTZAP-P1-1/data/json", [[
{"meter":{"W_ac":1850,"Hz":50.0,
  "l1_W_ac":600,"l1_V_ac":230.1,"l1_A_ac":2.61,
  "l2_W_ac":600,"l2_V_ac":230.4,"l2_A_ac":2.60,
  "l3_W_ac":650,"l3_V_ac":229.8,"l3_A_ac":2.83,
  "total_import_Wh_ac":58000000,"total_export_Wh_ac":9000000},
 "version":"v2","format":"p1_uart"}
]])
end

dofile("drivers/lua/zap.lua")

if DRIVER.id ~= "zap" or DRIVER.version ~= "3.1.2" then
    error("Zap identity metadata is wrong or version was not bumped")
end
if DRIVER.host_api_min ~= 1 or DRIVER.host_api_max ~= 1 or DRIVER.read_only ~= true then
    error("Zap host API or read-only metadata is wrong")
end

driver_init({ host = "127.0.0.1" })
local ok, err = pcall(driver_poll)
if not ok then error("driver_poll failed: " .. tostring(err)) end

local samples = host._emitted.meter
if not samples or #samples ~= 1 then
    error("expected exactly one meter sample for scenario " .. scenario
        .. ", got " .. tostring(samples and #samples or 0))
end

local meter = samples[1]
local function near(actual, expected)
    return type(actual) == "number" and math.abs(actual - expected) < 0.001
end

if not near(meter.w, 1850) then error(scenario .. ": meter.w wrong: " .. tostring(meter.w)) end
if not near(meter.l1_w, 600) or not near(meter.l2_w, 600) or not near(meter.l3_w, 650) then
    error(scenario .. ": phase power wrong")
end
if not near(meter.l1_v, 230.1) or not near(meter.l2_v, 230.4) or not near(meter.l3_v, 229.8) then
    error(scenario .. ": phase voltage wrong")
end
if not near(meter.l1_a, 2.61) or not near(meter.l2_a, 2.60) or not near(meter.l3_a, 2.83) then
    error(scenario .. ": phase current wrong")
end
if not near(meter.freq_hz, 50.0) then error(scenario .. ": Hz wrong (unsuffixed in both schemas)") end
if not near(meter.total_import_wh, 58000000) or not near(meter.import_wh, 58000000) then
    error(scenario .. ": total_import_Wh / import_wh alias wrong")
end
if not near(meter.total_export_wh, 9000000) or not near(meter.export_wh, 9000000) then
    error(scenario .. ": total_export_Wh / export_wh alias wrong")
end

driver_cleanup()
