-- ferroamp_modbus: a float that answers NaN or infinity is left out, never
-- sent as 0. Run with the scenario as arg[1].
--
-- The EnergyHub's floats are IEEE 754 with the low word at the lower
-- address. NaN is 0x7FC00000, +infinity 0x7F800000, -infinity 0xFF800000.
-- The values are synthetic, not a capture.

local scenario = arg[1]

dofile("drivers/tests/lua_harness/host_mock.lua")
host.reset()

local function f32(value)
    local hi, lo = string.unpack(">I2I2", string.pack(">f", value))
    return { lo, hi }
end
local NAN = { 0x0000, 0x7FC0 }
local INF = { 0x0000, 0x7F80 }
local NEG_INF = { 0x0000, 0xFF80 }
local MAX = { 0xFFFF, 0x7F7F }   -- float32's largest finite value

-- Floats at slot offsets 0, 4, 8 of a block: { lo, hi, 0, 0, lo, hi, ... }.
local function slots(...)
    local block = {}
    for _, words in ipairs({ ... }) do
        block[#block + 1] = words[1]
        block[#block + 1] = words[2]
        block[#block + 1] = 0
        block[#block + 1] = 0
    end
    return block
end

local input = host._modbus_registers.input
input[2016] = f32(50.02)
input[2032] = slots(f32(231), f32(229), f32(230))
input[3100] = f32(1.25)
input[3112] = slots(f32(2), f32(1.5), f32(2))
input[3064] = slots(f32(800), f32(4100))
input[5100] = f32(3.4)
input[5064] = f32(9100)
input[6100] = f32(-0.8)                 -- charging 800 W
input[6016] = f32(64)
input[6064] = slots(f32(10), f32(12))

local function poll()
    dofile("drivers/lua/ferroamp_modbus.lua")
    driver_init({})
    local ok, err = pcall(driver_poll)
    if not ok then error(scenario .. ": driver_poll failed: " .. tostring(err)) end
    return host._emitted.meter and host._emitted.meter[1],
           host._emitted.pv and host._emitted.pv[1],
           host._emitted.battery and host._emitted.battery[1]
end

local function fail(text) error(scenario .. ": " .. text) end

local function want(name, actual, expected)
    if type(actual) ~= "number" or math.abs(actual - expected) > 0.01 then
        fail(name .. " = " .. tostring(actual) .. ", want " .. tostring(expected))
    end
end

local function absent(name, actual)
    if actual ~= nil then fail(name .. " = " .. tostring(actual) .. ", want it left out") end
end

local function metric(name)
    local entry = host._metrics[name]
    return entry and entry.value
end

if scenario == "nan_grid_power" then
    -- A NaN grid power is no reading: no meter, not a 0 W balanced site.
    input[3100] = NAN
    local meter, pv = poll()
    if meter then fail("emitted a meter reading with w = " .. tostring(meter.w)) end
    want("pv.w", pv.w, -3400)

elseif scenario == "inf_pv_power" then
    input[5100] = INF
    local meter, pv = poll()
    if pv then fail("emitted a PV reading with w = " .. tostring(pv.w)) end
    want("meter.w", meter.w, 1250)

elseif scenario == "nan_one_phase" then
    -- L2 voltage NaN: L2 voltage and watts are left out, L1 and L3 stay.
    input[2032] = slots(f32(231), NAN, f32(230))
    local meter = poll()
    want("meter.l1_v", meter.l1_v, 231)
    want("meter.l3_w", meter.l3_w, 460)
    absent("meter.l2_v", meter.l2_v)
    absent("meter.l2_w", meter.l2_w)
    absent("meter_l2_v", metric("meter_l2_v"))
    absent("meter_l2_w", metric("meter_l2_w"))
    want("meter.l2_a", meter.l2_a, 1.5)

elseif scenario == "nan_frequency_and_counter" then
    input[2016] = NAN
    input[3064] = slots(NEG_INF, f32(4100))
    local meter = poll()
    absent("meter.hz", meter.hz)
    absent("grid_hz", metric("grid_hz"))
    absent("meter.export_wh", meter.export_wh)
    want("meter.import_wh", meter.import_wh, 4100000)

elseif scenario == "nan_battery" then
    -- NaN SoC and a NaN power: both left out, the energy counters stay.
    input[6016] = NAN
    input[6100] = NAN
    local _, _, battery = poll()
    absent("battery.soc", battery.soc)
    absent("battery.w", battery.w)
    want("battery.charge_wh", battery.charge_wh, 12000)

elseif scenario == "largest_float_scaled" then
    -- float32's largest value times 1000 is infinite where Lua numbers are
    -- 32-bit floats, as in this harness (docs/WRITING-A-DRIVER.md, "Numbers").
    input[3100] = MAX
    local meter = poll()
    if meter then fail("emitted a meter reading with w = " .. tostring(meter.w)) end

elseif scenario == "real_zero_kept" then
    -- 0.0 is a reading, not a sentinel.
    input[3100] = f32(0)
    local meter = poll()
    want("meter.w", meter.w, 0)

else
    error("unknown scenario: " .. tostring(scenario))
end
