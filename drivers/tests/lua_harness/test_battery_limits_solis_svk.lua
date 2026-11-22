-- What the battery can do now, for the three Solis 50-125 kW SvK drivers
-- (docs/WRITING-A-DRIVER.md, "What a battery can do now").
--
-- Usage: lua55 test_battery_limits_solis_svk.lua <driver-path>
--
-- 25004-25011 this unit's available charge / discharge / import / export
-- power, U32 1 W; 25012-25019 the same for a parallel system. The driver
-- sends the parallel figure first, as before, and reads the block on the
-- slow status poll (poll 1, then every 12th poll).
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

-- 1. Healthy: the parallel-system figures, as before, with metrics.
fresh()
driver_poll()
local bat, inv = last("battery"), last("inverter")
assert(bat.available_charge_W == 96000, "available_charge_W = " .. tostring(bat.available_charge_W))
assert(bat.available_discharge_W == 102000, "available_discharge_W = " .. tostring(bat.available_discharge_W))
assert(inv.available_import_W == 120000, "available_import_W = " .. tostring(inv.available_import_W))
assert(inv.available_export_W == 140000, "available_export_W = " .. tostring(inv.available_export_W))
assert(bat.W == 5000, "battery W changed")
assert(bat.temperature_C == nil, "temperature_C sent without a temperature read")
assert(metric("battery_available_charge_w") == 96000, "battery_available_charge_w metric")
assert(metric("battery_available_discharge_w") == 102000, "battery_available_discharge_w metric")

-- 2. 0 W means "not allowed now" and is kept, not taken for "missing".
fresh()
set_u32(25012, 0)
driver_poll()
assert(last("battery").available_charge_W == 0, "a 0 W charge limit was dropped")

-- 3. Cadence unchanged: one 16-register read on poll 1, then every 12th
--    poll, and no other new reads. Values are held until the next read.
fresh()
poll_until(SLOW_EVERY - 1)
assert(reads_of(25004) == 1, "limits read " .. reads_of(25004) .. " times in 11 polls")
assert(last("battery").available_charge_W == 96000, "limit not held between reads")
assert(reads_of(34350) == 0 and reads_of(33093) == 0, "temperature registers read")
set_u32(25012, 30000)
poll_until(SLOW_EVERY)
assert(reads_of(25004) == 2, "limits not re-read on poll 12")
assert(last("battery").available_charge_W == 30000, "new limit not emitted")

-- 4. A failed read clears the fields and sends no metrics, also after a
--    good one: nothing is sent again after a failed read.
fresh()
poll_until(SLOW_EVERY - 1)
host._metrics = {}
host._modbus_read_fail_addresses[25004] = "Illegal Data Address"
poll_until(SLOW_EVERY)
bat, inv = last("battery"), last("inverter")
assert(bat.W == 5000, "battery not emitted while the fast axis answers")
assert(bat.available_charge_W == nil and bat.available_discharge_W == nil,
    "battery limits sent again after a failed read")
assert(inv.available_import_W == nil and inv.available_export_W == nil,
    "inverter headroom sent again after a failed read")
assert(next(host._metrics) == nil, "a metric was emitted for a failed read")
host._modbus_read_fail_addresses[25004] = nil
poll_until(2 * SLOW_EVERY)
assert(last("battery").available_charge_W == 96000, "limits did not come back after the read recovered")

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

-- 6. A SoC that did not answer is not 0 % and gives no energy headroom.
fresh()
host._modbus_read_fail_addresses[33139] = "Illegal Data Address"
driver_poll()
bat = last("battery")
assert(bat.SoC_nom_fract == nil, "SoC sent as " .. tostring(bat.SoC_nom_fract) .. " without a reading")
assert(bat.available_charge_Wh == nil and bat.available_discharge_Wh == nil,
    "energy headroom sent without a SoC")

print("ok " .. driver_path)
