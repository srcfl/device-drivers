-- What the battery can do now, for konja-261-svk
-- (docs/WRITING-A-DRIVER.md, "What a battery can do now").
--
-- Usage: lua55 test_battery_limits_konja.lua <driver-path>
--
-- BMS block 2721..2761 (FC04): 2750 average temperature int16 0.1 °C,
-- 2755 forbid flag, 2758-2759 / 2760-2761 max charge / discharge power
-- uint32 0.1 kW. PCS block 8034..8063: 8059 IGBT temperature int16 0.1 °C.
local driver_path = arg[1]
assert(driver_path, "usage: test_battery_limits_konja.lua <driver-path>")

dofile("drivers/tests/lua_harness/host_mock.lua")
host.set_warmup_s = function() end

local CLOCK0 = 1000000

local function set_s16(addr, v)
    if v < 0 then v = v + 65536 end
    host._modbus_registers.input[addr] = v
end

local function set_u32(addr, v)
    host._modbus_registers.input[addr] = math.floor(v / 65536)
    host._modbus_registers.input[addr + 1] = v % 65536
end

local function healthy_registers()
    local reg = host._modbus_registers.input
    for i = 0, 15 do reg[8064 + i] = 0x4B4F end   -- PCS SN
    -- PCS: 8047 AC -3.0 kW (Konja +discharge), 8056 DC -3.1 kW, 8054 800.0 V.
    set_s16(8047, -30)
    set_s16(8056, -31)
    set_s16(8054, 8000)
    set_s16(8059, 512)          -- IGBT 51.2 °C
    reg[8063] = 4               -- grid-connected
    -- BMS.
    reg[2727] = 550             -- SoC 55.0 %
    set_s16(2750, 253)          -- 25.3 °C
    reg[2755] = 0               -- nothing forbidden
    set_u32(2758, 1250)         -- 125.0 kW charge
    set_u32(2760, 600)          -- 60.0 kW discharge
end

local function fresh()
    host.reset()
    host._millis_step = 0
    host._millis_counter = CLOCK0
    healthy_registers()
    driver_init, driver_poll = nil, nil
    dofile(driver_path)
    assert(driver_init({ battery_capacity_wh = 261000 }) == true, "driver_init failed")
end

local function last(der)
    local e = host._emitted[der]
    assert(e and #e > 0, "no " .. der .. " emit")
    return e[#e]
end

local function metric(name)
    local m = host._metrics[name]
    return m and m.value
end

local function metric_count(name)
    local n = 0
    for _, c in ipairs(host._calls) do
        if c.func == "emit_metric" and c.args[1] == name then n = n + 1 end
    end
    return n
end

-- lua55 is built with LUA_32BITS: floats are single precision.
local function near(a, b) return a ~= nil and b ~= nil and math.abs(a - b) < 1e-3 end

-- 1. Healthy: fields with the right scale and sign, and metrics.
fresh()
driver_poll()
local bat, inv = last("battery"), last("inverter")
assert(near(bat.temperature_C, 25.3), "temperature_C = " .. tostring(bat.temperature_C))
assert(bat.available_charge_W == 125000, "available_charge_W = " .. tostring(bat.available_charge_W))
assert(bat.available_discharge_W == 60000, "available_discharge_W = " .. tostring(bat.available_discharge_W))
assert(bat.W == 3100, "battery W = " .. tostring(bat.W))
assert(near(inv.heatsink_C, 51.2), "heatsink_C = " .. tostring(inv.heatsink_C))
assert(near(metric("battery_temp_c"), 25.3), "battery_temp_c metric")
assert(metric("battery_available_charge_w") == 125000, "battery_available_charge_w metric")
assert(metric("battery_available_discharge_w") == 60000, "battery_available_discharge_w metric")
assert(near(metric("inverter_temp_c"), 51.2), "inverter_temp_c metric")

-- 2. A forbidden direction is 0 W; the other keeps its limit.
fresh()
host._modbus_registers.input[2755] = 0x55
driver_poll()
bat = last("battery")
assert(bat.available_charge_W == 0, "charge forbidden but available_charge_W = " .. tostring(bat.available_charge_W))
assert(bat.available_discharge_W == 60000, "discharge limit lost when charge is forbidden")
fresh()
host._modbus_registers.input[2755] = 0xAA
driver_poll()
bat = last("battery")
assert(bat.available_charge_W == 0 and bat.available_discharge_W == 0, "both forbidden not both 0 W")

-- 3. Metrics reach history at most every 10 s, not at the 20 Hz poll.
fresh()
driver_poll()
host._millis_counter = CLOCK0 + 50
driver_poll()
host._millis_counter = CLOCK0 + 9999
driver_poll()
assert(metric_count("battery_temp_c") == 1, "metrics emitted more than once in 10 s")
host._millis_counter = CLOCK0 + 10000
driver_poll()
assert(metric_count("battery_temp_c") == 2, "metrics not emitted again after 10 s")
assert(#host._emitted.battery == 4, "battery not emitted on every poll")

-- 4. A BMS block that fails after a good one: fields and metrics left out,
--    not replayed. The PCS still answers, so the battery is still emitted.
fresh()
driver_poll()
host._metrics = {}
host._modbus_read_fail_addresses[2721] = "Illegal Data Address"
host._millis_counter = CLOCK0 + 10000
driver_poll()
bat = last("battery")
assert(bat.W == 3100, "battery not emitted while the PCS answers")
for _, k in ipairs({ "temperature_C", "available_charge_W", "available_discharge_W" }) do
    assert(bat[k] == nil, "battery." .. k .. " replayed after a failed BMS read: " .. tostring(bat[k]))
end
for _, k in ipairs({ "battery_temp_c", "battery_available_charge_w", "battery_available_discharge_w" }) do
    assert(metric(k) == nil, k .. " emitted after a failed BMS read")
end
assert(near(metric("inverter_temp_c"), 51.2), "inverter_temp_c lost with the BMS block")

-- 5. A PCS block that fails: no fabricated 0 W, no IGBT metric.
fresh()
host._modbus_read_fail_addresses[8034] = "Illegal Data Address"
driver_poll()
bat = last("battery")
assert(bat.W == nil, "battery W sent as " .. tostring(bat.W) .. " without a PCS reading")
assert(bat.available_charge_W == 125000, "BMS limit lost when the PCS fails")
assert(metric("inverter_temp_c") == nil, "inverter_temp_c without a PCS reading")

-- 6. Out of range is dropped, not clamped and not zeroed.
fresh()
set_s16(2750, 1001)                         -- 100.1 °C
set_u32(2758, 10001)                        -- 1000.1 kW
host._modbus_registers.input[2760] = 0xFFFF -- not-present sentinel
host._modbus_registers.input[2761] = 0xFFFF
set_s16(8059, 1501)                         -- IGBT 150.1 °C
driver_poll()
bat, inv = last("battery"), last("inverter")
assert(bat.temperature_C == nil, "100.1 °C battery temperature emitted")
assert(bat.available_charge_W == nil, "1000.1 kW charge limit emitted")
assert(bat.available_discharge_W == nil, "sentinel discharge limit emitted")
assert(inv.heatsink_C == nil, "150.1 °C IGBT temperature emitted")
assert(next(host._metrics) == nil, "a metric was emitted for an out-of-range value")
fresh()
set_s16(2750, -401)                         -- -40.1 °C
set_u32(2758, 10000)                        -- exactly 1000 kW: kept
driver_poll()
bat = last("battery")
assert(bat.temperature_C == nil, "-40.1 °C battery temperature emitted")
assert(bat.available_charge_W == 1000000, "a 1000 kW limit was dropped")
fresh()
set_s16(2750, -125)                         -- -12.5 °C is a real reading
driver_poll()
assert(near(last("battery").temperature_C, -12.5), "a cold battery was not reported")

-- 7. A SoC that never answered is not 0 % and gives no energy headroom.
fresh()
host._modbus_registers.input[2727] = 0
driver_poll()
bat = last("battery")
assert(bat.SoC_nom_fract == nil, "SoC sent as " .. tostring(bat.SoC_nom_fract) .. " without a reading")
assert(bat.available_charge_Wh == nil and bat.available_discharge_Wh == nil,
    "energy headroom sent without a SoC")

print("ok " .. driver_path)
