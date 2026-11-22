-- What the battery can do now, for the three Solis 50-125 kW SvK drivers
-- (docs/WRITING-A-DRIVER.md, "What a battery can do now").
--
-- Usage: lua55 test_battery_limits_solis_svk.lua <driver-path>
--
-- 25004-25011 this unit's available charge / discharge / import / export
-- power, U32 1 W; 25012-25019 the same for a parallel system. The driver
-- sends the parallel figure first, as before, and reads the block on the
-- slow status poll (poll 1, then every 12th poll). On the same poll it
-- reads 34350/34351 (min / max cell temperature) and 33093 (inverter
-- module temperature), S16 0.1 °C.
local driver_path = arg[1]
assert(driver_path, "usage: test_battery_limits_solis_svk.lua <driver-path>")

dofile("drivers/tests/lua_harness/host_mock.lua")
-- Both real hosts have it; the shared mock does not.
host.set_warmup_s = function() end

local SLOW_EVERY = 12

local function set_u32(addr, v)
    host._modbus_registers.input[addr] = math.floor(v / 65536)
    host._modbus_registers.input[addr + 1] = v % 65536
end

local function set_s16(addr, v)
    if v < 0 then v = v + 65536 end
    host._modbus_registers.input[addr] = v
end

local function healthy_registers()
    local reg = host._modbus_registers.input
    -- Serial number, so driver_init succeeds.
    for i = 0, 15 do reg[33004 + i] = 0x4142 end
    reg[33067] = 10000                -- rated 100 kW (×10 W)
    reg[34799] = 0x0100
    -- Fast axis: battery 34755-56 = +5000 W, AC port 34765-66, SoC 55 %.
    set_u32(34755, 5000)
    set_u32(34765, 4000)
    reg[33139] = 55
    -- This unit.
    set_u32(25004, 48000)   -- available charge
    set_u32(25006, 51000)   -- available discharge
    set_u32(25008, 60000)   -- available import
    set_u32(25010, 70000)   -- available export
    -- Parallel system.
    set_u32(25012, 96000)
    set_u32(25014, 102000)
    set_u32(25016, 120000)
    set_u32(25018, 140000)
    -- Cells 15.0 / 20.0 °C, inverter module 45.6 °C.
    set_s16(34350, 150)
    set_s16(34351, 200)
    set_s16(33093, 456)
end

local function fresh()
    host.reset()
    healthy_registers()
    driver_init, driver_poll = nil, nil
    dofile(driver_path)
    assert(driver_init({ battery_capacity_wh = 100000 }) == true, "driver_init failed")
end

local function last(der)
    local e = host._emitted[der]
    assert(e and #e > 0, "no " .. der .. " emit")
    return e[#e]
end

local function reads_of(addr)
    local n = 0
    for _, c in ipairs(host._calls) do
        if c.func == "modbus_read" and c.args[1] == addr then n = n + 1 end
    end
    return n
end

local function metric(name)
    local m = host._metrics[name]
    return m and m.value
end

local function poll_until(n)
    while #(host._emitted.battery or {}) < n do driver_poll() end
end

-- lua55 is built with LUA_32BITS: floats are single precision.
local function near(a, b) return a ~= nil and b ~= nil and math.abs(a - b) < 1e-3 end

-- 1. Healthy: the parallel-system figures, as before, with metrics.
fresh()
driver_poll()
local bat, inv = last("battery"), last("inverter")
assert(bat.available_charge_W == 96000, "available_charge_W = " .. tostring(bat.available_charge_W))
assert(bat.available_discharge_W == 102000, "available_discharge_W = " .. tostring(bat.available_discharge_W))
assert(inv.available_import_W == 120000, "available_import_W = " .. tostring(inv.available_import_W))
assert(inv.available_export_W == 140000, "available_export_W = " .. tostring(inv.available_export_W))
assert(bat.W == 5000, "battery W changed")
assert(near(bat.temperature_C, 17.5), "temperature_C = " .. tostring(bat.temperature_C))
assert(metric("battery_available_charge_w") == 96000, "battery_available_charge_w metric")
assert(metric("battery_available_discharge_w") == 102000, "battery_available_discharge_w metric")
assert(near(metric("battery_temp_c"), 17.5), "battery_temp_c metric")
assert(near(metric("battery_cell_temp_min_c"), 15.0), "battery_cell_temp_min_c metric")
assert(near(metric("battery_cell_temp_max_c"), 20.0), "battery_cell_temp_max_c metric")
assert(near(metric("inverter_temp_c"), 45.6), "inverter_temp_c metric")

-- 2. 0 W means "not allowed now" and is kept, not taken for "missing".
fresh()
set_u32(25012, 0)
driver_poll()
assert(last("battery").available_charge_W == 0, "a 0 W charge limit was dropped")

-- 2b. Below-zero cells decode as signed.
fresh()
set_s16(34350, -52)          -- -5.2 °C
set_s16(34351, -12)          -- -1.2 °C
driver_poll()
assert(near(last("battery").temperature_C, -3.2), "cold temperature_C = " .. tostring(last("battery").temperature_C))
assert(near(metric("battery_cell_temp_min_c"), -5.2), "cold min cell metric")

-- 3. Cadence: the limit block and the two temperature reads on poll 1,
--    then every 12th poll, nothing between. Values held until the next read.
fresh()
poll_until(SLOW_EVERY - 1)
assert(reads_of(25004) == 1, "limits read " .. reads_of(25004) .. " times in 11 polls")
assert(reads_of(34350) == 1 and reads_of(33093) == 1, "temperatures not read once in 11 polls")
assert(last("battery").available_charge_W == 96000, "limit not held between reads")
assert(near(last("battery").temperature_C, 17.5), "temperature not held between reads")
set_u32(25012, 30000)
set_s16(34351, 300)          -- hottest cell now 30.0 °C
poll_until(SLOW_EVERY)
assert(reads_of(25004) == 2, "limits not re-read on poll 12")
assert(reads_of(34350) == 2 and reads_of(33093) == 2, "temperatures not re-read on poll 12")
assert(last("battery").available_charge_W == 30000, "new limit not emitted")
assert(near(last("battery").temperature_C, 22.5), "new temperature not emitted")

-- 4. A failed read clears the fields and sends no metrics, also after a
--    good one: nothing is sent again after a failed read.
fresh()
poll_until(SLOW_EVERY - 1)
host._metrics = {}
host._modbus_read_fail_addresses[25004] = "Illegal Data Address"
host._modbus_read_fail_addresses[34350] = "Illegal Data Address"
host._modbus_read_fail_addresses[33093] = "Illegal Data Address"
poll_until(SLOW_EVERY)
bat, inv = last("battery"), last("inverter")
assert(bat.W == 5000, "battery not emitted while the fast axis answers")
assert(bat.available_charge_W == nil and bat.available_discharge_W == nil,
    "battery limits sent again after a failed read")
assert(bat.temperature_C == nil, "temperature sent again after a failed read")
assert(inv.available_import_W == nil and inv.available_export_W == nil,
    "inverter headroom sent again after a failed read")
assert(next(host._metrics) == nil, "a metric was emitted for a failed read")
host._modbus_read_fail_addresses[25004] = nil
host._modbus_read_fail_addresses[34350] = nil
host._modbus_read_fail_addresses[33093] = nil
poll_until(2 * SLOW_EVERY)
assert(last("battery").available_charge_W == 96000, "limits did not come back after the read recovered")
assert(near(last("battery").temperature_C, 17.5), "temperature did not come back after the read recovered")

-- 4b. Each read stands alone: a failed limit block keeps the temperatures,
--     and a failed temperature read keeps the limits.
fresh()
host._modbus_read_fail_addresses[25004] = "Illegal Data Address"
driver_poll()
bat = last("battery")
assert(bat.available_charge_W == nil, "limit sent from a failed block")
assert(near(bat.temperature_C, 17.5), "temperature lost with the limit block")
assert(near(metric("inverter_temp_c"), 45.6), "inverter temperature lost with the limit block")
fresh()
host._modbus_read_fail_addresses[34350] = "Illegal Data Address"
driver_poll()
bat = last("battery")
assert(bat.temperature_C == nil, "temperature sent from a failed read")
assert(metric("battery_cell_temp_min_c") == nil, "cell metric from a failed read")
assert(bat.available_charge_W == 96000, "limit lost with the temperature read")

-- 5. Out of range is dropped, not clamped and not zeroed. The parallel
--    figure still comes first; this unit's is used only when it is missing.
fresh()
set_u32(25012, 0xFFFFFFFF)   -- parallel charge: not-present sentinel
set_u32(25004, 0xFFFFFFFF)   -- this unit's too
set_u32(25014, 1000001)      -- parallel discharge: just over 1000 kW
set_u32(25006, 52000)        -- this unit's discharge
set_u32(25016, 1000000)      -- exactly 1000 kW: kept
driver_poll()
bat, inv = last("battery"), last("inverter")
assert(bat.available_charge_W == nil, "sentinel charge limit sent: " .. tostring(bat.available_charge_W))
assert(bat.available_discharge_W == 52000, "out-of-range parallel figure not dropped")
assert(inv.available_import_W == 1000000, "1000 kW import headroom dropped")
assert(metric("battery_available_charge_w") == nil, "sentinel charge metric")
fresh()
set_s16(34350, -401)         -- -40.1 °C
set_s16(34351, 200)
set_s16(33093, 1501)         -- 150.1 °C
driver_poll()
assert(last("battery").temperature_C == nil, "temperature sent with one cell out of range")
assert(metric("battery_cell_temp_min_c") == nil, "out-of-range min cell metric")
assert(near(metric("battery_cell_temp_max_c"), 20.0), "good max cell metric dropped")
assert(metric("inverter_temp_c") == nil, "out-of-range inverter temperature metric")
fresh()
set_s16(34350, 150)
set_s16(34351, 1001)         -- 100.1 °C
set_s16(33093, 1500)         -- 150.0 °C: kept
driver_poll()
assert(last("battery").temperature_C == nil, "a 100.1 °C cell was sent")
assert(near(metric("inverter_temp_c"), 150.0), "a 150 °C inverter module was dropped")

-- 6. A SoC that did not answer is not 0 % and gives no energy headroom.
fresh()
host._modbus_read_fail_addresses[33139] = "Illegal Data Address"
driver_poll()
bat = last("battery")
assert(bat.SoC_nom_fract == nil, "SoC sent as " .. tostring(bat.SoC_nom_fract) .. " without a reading")
assert(bat.available_charge_Wh == nil and bat.available_discharge_Wh == nil,
    "energy headroom sent without a SoC")

print("ok " .. driver_path)
