-- ferroamp_modbus: the meter and PV streams carry only what answered.
-- Run with the scenario as arg[1].
--
-- Ferroamp Modbus TCP Revision D, input registers, float32 with the low
-- word at the lower address:
--   2016       grid frequency, Hz
--   2032/2036/2040  grid voltage L1..L3, V (each in a 4-register slot)
--   3100       grid active power, kW (import positive)
--   3112/3116/3120  grid active current L1..L3, A
--   3064/3068  grid energy exported / imported, kWh
--   5100       solar power, kW
--   5064       solar energy produced, kWh
-- The values are synthetic, not a capture.

local scenario = arg[1]

dofile("drivers/tests/lua_harness/host_mock.lua")
host.reset()

local function f32(value)
    local hi, lo = string.unpack(">I2I2", string.pack(">f", value))
    return { lo, hi }
end

-- Floats at slot offsets 0, 4, 8 of a block: { lo, hi, 0, 0, lo, hi, ... }.
local function slots(...)
    local block = {}
    for _, value in ipairs({ ... }) do
        local words = f32(value)
        block[#block + 1] = words[1]
        block[#block + 1] = words[2]
        block[#block + 1] = 0
        block[#block + 1] = 0
    end
    return block
end

local input = host._modbus_registers.input
input[2016] = f32(50.02)
input[2032] = slots(231, 229, 230)
input[3100] = f32(1.25)                 -- 1250 W import
input[3112] = slots(2, 1.5, 2)
input[3064] = slots(800, 4100)          -- exported, imported kWh
input[5100] = f32(3.4)                  -- 3400 W
input[5064] = f32(9100)                 -- kWh
input[6100] = f32(0)
input[6016] = f32(50)
input[6064] = slots(10, 12)

local function fail_reads(...)
    for _, addr in ipairs({ ... }) do
        host._modbus_read_fail_addresses[addr] = "Illegal Data Address"
    end
end

local function poll()
    dofile("drivers/lua/ferroamp_modbus.lua")
    driver_init({})
    local ok, err = pcall(driver_poll)
    if not ok then error(scenario .. ": driver_poll failed: " .. tostring(err)) end
    return host._emitted.meter and host._emitted.meter[1],
           host._emitted.pv and host._emitted.pv[1]
end

local function want(name, actual, expected)
    if type(actual) ~= "number" or math.abs(actual - expected) > 0.01 then
        error(scenario .. ": " .. name .. " = " .. tostring(actual) .. ", want " .. tostring(expected))
    end
end

local function absent(name, actual)
    if actual ~= nil then
        error(scenario .. ": " .. name .. " = " .. tostring(actual) .. ", want it left out")
    end
end

local function metric(name)
    local entry = host._metrics[name]
    return entry and entry.value
end

if scenario == "all_answer" then
    local meter, pv = poll()
    want("meter.w", meter.w, 1250)
    want("meter.hz", meter.hz, 50.02)
    want("meter.l1_v", meter.l1_v, 231)
    want("meter.l3_v", meter.l3_v, 230)
    want("meter.l2_a", meter.l2_a, 1.5)
    want("meter.l1_w", meter.l1_w, 462)
    want("meter.l2_w", meter.l2_w, 343.5)
    want("meter.export_wh", meter.export_wh, 800000)
    want("meter.import_wh", meter.import_wh, 4100000)
    want("meter_l2_w", metric("meter_l2_w"), 343.5)
    want("grid_hz", metric("grid_hz"), 50.02)
    want("pv.w", pv.w, -3400)
    want("pv.lifetime_wh", pv.lifetime_wh, 9100000)

elseif scenario == "grid_power_fails" then
    -- 0 W from a failed read looks like a site in balance. The fields that
    -- answered still reach history as metrics.
    fail_reads(3100)
    local meter, pv = poll()
    if meter then error(scenario .. ": emitted a meter reading with w = " .. tostring(meter.w)) end
    want("meter_l1_v", metric("meter_l1_v"), 231)
    want("pv.w", pv.w, -3400)

elseif scenario == "voltage_fails" then
    -- No voltage: no voltages and no per-phase watts (V x I), the rest stays.
    fail_reads(2032)
    local meter = poll()
    want("meter.w", meter.w, 1250)
    want("meter.l1_a", meter.l1_a, 2)
    for _, key in ipairs({ "l1_v", "l2_v", "l3_v", "l1_w", "l2_w", "l3_w" }) do
        absent("meter." .. key, meter[key])
        absent("meter_" .. key, metric("meter_" .. key))
    end

elseif scenario == "current_fails" then
    fail_reads(3112)
    local meter = poll()
    want("meter.l2_v", meter.l2_v, 229)
    for _, key in ipairs({ "l1_a", "l2_a", "l3_a", "l1_w", "l2_w", "l3_w" }) do
        absent("meter." .. key, meter[key])
        absent("meter_" .. key, metric("meter_" .. key))
    end

elseif scenario == "frequency_and_energy_fail" then
    fail_reads(2016, 3064)
    local meter = poll()
    want("meter.w", meter.w, 1250)
    absent("meter.hz", meter.hz)
    absent("grid_hz", metric("grid_hz"))
    absent("meter.import_wh", meter.import_wh)
    absent("meter.export_wh", meter.export_wh)

elseif scenario == "pv_power_fails" then
    fail_reads(5100)
    local meter, pv = poll()
    if pv then error(scenario .. ": emitted a PV reading with w = " .. tostring(pv.w)) end
    want("meter.w", meter.w, 1250)

elseif scenario == "pv_energy_fails" then
    fail_reads(5064)
    local _, pv = poll()
    want("pv.w", pv.w, -3400)
    absent("pv.lifetime_wh", pv.lifetime_wh)

elseif scenario == "short_reply" then
    -- A reply with fewer registers than asked for did not answer them all;
    -- the missing word must not decode as 0.
    host._modbus_read_short_counts[3100] = 1
    host._modbus_read_short_counts[2032] = 6
    host._modbus_read_short_counts[5100] = 1
    local meter, pv = poll()
    if meter then error(scenario .. ": emitted a meter reading with w = " .. tostring(meter.w)) end
    if pv then error(scenario .. ": emitted a PV reading with w = " .. tostring(pv.w)) end
    absent("meter_l3_v", metric("meter_l3_v"))
    want("meter_l1_a", metric("meter_l1_a"), 2)

elseif scenario == "nothing_answers" then
    fail_reads(2016, 2032, 3100, 3112, 3064, 5100, 5064, 6100, 6016, 6064)
    local meter, pv = poll()
    if meter then error(scenario .. ": emitted a meter reading") end
    if pv then error(scenario .. ": emitted a PV reading") end
    if host._emitted.battery then error(scenario .. ": emitted a battery reading") end
    if next(host._metrics) then error(scenario .. ": emitted a metric") end

else
    error("unknown scenario: " .. tostring(scenario))
end
