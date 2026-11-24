-- victron (Modbus TCP, com.victronenergy.system on unit 100): the meter and
-- PV streams carry only what answered. Run with the scenario as arg[1].
--
-- Victron's attributes.csv for dbus_modbustcp:
--   808-810  /Ac/PvOnOutput/L1..L3/Power  U16, W  (AC-coupled PV)
--   850      /Dc/Pv/Power                 U16, W  (DC-coupled PV)
--   820-822  /Ac/Grid/L1..L3/Power        I16, W  (import positive)
-- The values are synthetic, not a capture.

local scenario = arg[1]

dofile("drivers/tests/lua_harness/host_mock.lua")
host.reset()

local holding = host._modbus_registers.holding
holding[808] = { 1200, 900, 600 }       -- AC PV 2700 W
holding[850] = { 1500 }                 -- DC PV 1500 W
holding[820] = { 400, 0xFFFF - 99, 50 } -- grid +400, -100, +50 W
holding[840] = { 521, 0xFFFF - 229, 0xFFFF - 1199, 64 }

local function fail_reads(...)
    for _, addr in ipairs({ ... }) do
        host._modbus_read_fail_addresses[addr] = "Illegal Data Address"
    end
end

local function poll()
    dofile("drivers/lua/victron.lua")
    driver_init({})
    local ok, err = pcall(driver_poll)
    if not ok then error(scenario .. ": driver_poll failed: " .. tostring(err)) end
    return host._emitted.meter and host._emitted.meter[1],
           host._emitted.pv and host._emitted.pv[1]
end

local function want(name, actual, expected)
    if type(actual) ~= "number" or math.abs(actual - expected) > 0.001 then
        error(scenario .. ": " .. name .. " = " .. tostring(actual) .. ", want " .. tostring(expected))
    end
end

local function metric(name)
    local entry = host._metrics[name]
    return entry and entry.value
end

local function no_meter(meter)
    if meter then error(scenario .. ": emitted a meter reading with w = " .. tostring(meter.w)) end
    for _, name in ipairs({ "meter_l1_w", "meter_l2_w", "meter_l3_w" }) do
        if metric(name) ~= nil then error(scenario .. ": emitted " .. name) end
    end
end

if scenario == "all_answer" then
    local meter, pv = poll()
    want("meter.w", meter.w, 350)
    want("meter.l1_w", meter.l1_w, 400)
    want("meter.l2_w", meter.l2_w, -100)
    want("meter.l3_w", meter.l3_w, 50)
    want("meter_l2_w", metric("meter_l2_w"), -100)
    want("pv.w", pv.w, -4200)

elseif scenario == "grid_read_fails" then
    -- 0 W from a failed read looks like a site in balance.
    fail_reads(820)
    local meter, pv = poll()
    no_meter(meter)
    want("pv.w", pv.w, -4200)

elseif scenario == "pv_reads_fail" then
    fail_reads(808, 850)
    local meter, pv = poll()
    if pv then error(scenario .. ": emitted a PV reading with w = " .. tostring(pv.w)) end
    want("meter.w", meter.w, 350)

elseif scenario == "no_dc_pv" then
    -- A GX without a DC-coupled MPPT does not answer 850: PV is the
    -- AC-coupled part alone.
    fail_reads(850)
    local _, pv = poll()
    want("pv.w", pv.w, -2700)

elseif scenario == "no_ac_pv" then
    fail_reads(808)
    local _, pv = poll()
    want("pv.w", pv.w, -1500)

elseif scenario == "nothing_answers" then
    fail_reads(808, 850, 820, 840)
    local meter, pv = poll()
    no_meter(meter)
    if pv then error(scenario .. ": emitted a PV reading") end
    if host._emitted.battery then error(scenario .. ": emitted a battery reading") end

else
    error("unknown scenario: " .. tostring(scenario))
end
