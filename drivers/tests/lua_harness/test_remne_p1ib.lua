-- Exercise remne_p1ib against a /meterData payload shaped like the bridge's.
-- Values are synthetic; the shape (OBIS arrays, oldest first, info.okCnt)
-- matches firmware 757b45d.

dofile("drivers/tests/lua_harness/host_mock.lua")
host.reset()

local clock = 0
host.now_ms = function() return clock end
host.set_poll_interval = function() end

local URL = "http://127.0.0.1/meterData"

local function payload(ok_cnt, fields)
    local parts = {}
    for obis, values in pairs(fields) do
        table.insert(parts, string.format('"%s":[%s]', obis, table.concat(values, ",")))
    end
    return string.format(
        '{"d":{%s},"last_ok_interval":10000,"info":{"mac":"00:11:22:33:44:55",' ..
        '"meter":"TESTMETER","mode":"Mode-D","rssi":-50,"okCnt":%d,"failCnt":0}}',
        table.concat(parts, ","), ok_cnt)
end

-- Import on L1 and L3, export on L2: net site import of 1.0 kW.
local THREE_PHASE = {
    ["1-0:1.7.0"]  = {"9.9", "1.5"},
    ["1-0:2.7.0"]  = {"9.9", "0.5"},
    ["1-0:21.7.0"] = {"0", "1.0"},
    ["1-0:22.7.0"] = {"0", "0"},
    ["1-0:41.7.0"] = {"0", "0"},
    ["1-0:42.7.0"] = {"0", "0.5"},
    ["1-0:61.7.0"] = {"0", "0.5"},
    ["1-0:62.7.0"] = {"0", "0"},
    ["1-0:32.7.0"] = {"0", "230.1"},
    ["1-0:52.7.0"] = {"0", "231.2"},
    ["1-0:72.7.0"] = {"0", "232.3"},
    ["1-0:31.7.0"] = {"0", "4.4"},
    ["1-0:51.7.0"] = {"0", "2.2"},
    ["1-0:71.7.0"] = {"0", "2.1"},
    ["1-0:1.8.0"]  = {"0", "1234.5"},
    ["1-0:2.8.0"]  = {"0", "12.5"},
    ["1-0:3.7.0"]  = {"0", "0"},
    ["1-0:4.7.0"]  = {"0", "0.2"},
}

local function near(actual, expected, what)
    if type(actual) ~= "number" or math.abs(actual - expected) > 1e-6 then
        error(what .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
    end
end

local function emitted()
    return host._emitted.meter and #host._emitted.meter or 0
end

dofile("drivers/lua/remne_p1ib.lua")
if DRIVER.id ~= "remne_p1ib" or DRIVER.read_only ~= true then
    error("remne_p1ib identity or read-only metadata is wrong")
end
-- FTW setup seeds config.host only for drivers that declare this key; without
-- it a driver added through the setup wizard never learns the bridge address.
if type(DRIVER.connection_defaults) ~= "table" or DRIVER.connection_defaults.host ~= "" then
    error("remne_p1ib must declare connection_defaults.host so setup passes the IP")
end

driver_init({host = "127.0.0.1", poll_ms = 5000})

-- 1. First telegram: newest array element, site sign convention, identity.
host._http_responses[URL] = payload(100, THREE_PHASE)
driver_poll()
if emitted() ~= 1 then error("first telegram did not emit exactly one meter sample") end
local m = host._emitted.meter[1]
near(m.w, 1000, "net site power")
near(m.l1_w, 1000, "L1 power")
near(m.l2_w, -500, "L2 power (export is negative)")
near(m.l3_w, 500, "L3 power")
near(m.l1_v, 230.1, "L1 voltage")
near(m.l3_a, 2.1, "L3 current")
near(m.import_wh, 1234500, "lifetime import")
near(m.export_wh, 12500, "lifetime export")
if host._sn ~= "p1ib-001122334455" then error("serial not taken from the bridge MAC: " .. tostring(host._sn)) end
if host._model ~= "TESTMETER" then error("model not taken from info.meter") end

-- 2. Same telegram counter: the rolling window is not re-emitted as fresh.
clock = clock + 5000
driver_poll()
if emitted() ~= 1 then error("re-emitted a reading without a new telegram") end

-- 3. Counter stuck past three telegram intervals: still silent, one warning.
clock = clock + 40000
driver_poll()
clock = clock + 5000
driver_poll()
if emitted() ~= 1 then error("emitted while the meter was stale") end
local warnings = 0
for _, line in ipairs(host._logs) do
    if string.find(line, "no new meter telegram", 1, true) then warnings = warnings + 1 end
end
if warnings ~= 1 then error("expected one stale warning, got " .. warnings) end

-- 4. Bridge reboot: a lower counter is a new telegram.
clock = clock + 5000
host._http_responses[URL] = payload(3, THREE_PHASE)
driver_poll()
if emitted() ~= 2 then error("did not emit after the bridge rebooted") end

-- 5. A meter without per-phase export: phase power omitted, not faked as 0.
local no_phase_export = {}
for k, v in pairs(THREE_PHASE) do no_phase_export[k] = v end
no_phase_export["1-0:22.7.0"] = nil
no_phase_export["1-0:31.7.0"] = nil
clock = clock + 5000
host._http_responses[URL] = payload(4, no_phase_export)
driver_poll()
local last = host._emitted.meter[emitted()]
if last.l1_w ~= nil then error("L1 power emitted without L1 export reading") end
if last.l1_a ~= nil then error("L1 current emitted without an L1 current reading") end
near(last.l2_w, -500, "L2 power still emitted")

-- 6. Empty arrays right after boot: no emit rather than a zero site reading.
local empty = {}
for k in pairs(THREE_PHASE) do empty[k] = {} end
clock = clock + 5000
host._http_responses[URL] = payload(5, empty)
driver_poll()
if emitted() ~= 3 then error("emitted a sample from empty arrays") end

print("remne_p1ib: all scenarios passed")
