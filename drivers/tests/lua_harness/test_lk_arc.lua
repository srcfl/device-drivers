-- lk_arc: decode the registers an LK Arc gateway actually returned.
--
-- The first case is the raw register values read from one LK Arc gateway
-- (software 0.53.0) with three zones on 2026-11-10, except the gateway
-- serial and the thermostat addresses, which are replaced by made-up
-- numbers: they are hardware identifiers.
--
-- Usage: lua55 test_lk_arc.lua

local script_dir = arg[0]:match("(.*/)") or "./"
dofile(script_dir .. "host_mock.lua")

local ROOT = script_dir .. "../../../"
local failed = 0

local function fail(msg)
    failed = failed + 1
    io.stderr:write("FAIL " .. msg .. "\n")
end

local function expect(name, value, unit)
    local m = host._metrics[name]
    if not m then return fail(name .. ": not emitted") end
    if type(m.value) ~= "number" or math.abs(m.value - value) > 0.001 then
        fail(name .. ": value " .. tostring(m.value) .. " want " .. tostring(value))
    end
    if unit and m.unit ~= unit then
        fail(name .. ": unit " .. tostring(m.unit) .. " want " .. unit)
    end
end

local function absent(name)
    if host._metrics[name] ~= nil then
        fail(name .. ": emitted " .. tostring(host._metrics[name].value) .. ", want absent")
    end
end

local function set(map, addr, values)
    for i, v in ipairs(values) do map[addr + i - 1] = v end
end

local function load()
    dofile(ROOT .. "drivers/lua/lk_arc.lua")
    driver_init({})
end

local function gateway(overrides)
    host.reset()
    local inp = host._modbus_registers.input
    local hr = host._modbus_registers.holding
    set(inp, 0, { 0x1111, 0x2222, 0x3333, 0x4444 }) -- serial (made up)
    set(inp, 4, { 0, 53, 0 })                        -- software 0.53.0
    -- Actuators 1-7 open, 8-12 unallocated.
    set(inp, 60, { 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2 })
    -- temp, humidity, battery, signal, address x3 (made up), actuators
    set(inp, 100, { 200, 398, 25, 65457, 0xA1, 0xB1, 0xC1, 42 })
    set(inp, 200, { 209, 394, 99, 65481, 0xA2, 0xB2, 0xC2, 1 })
    set(inp, 300, { 189, 436, 25, 65450, 0xA3, 0xB3, 0xC3, 84 })
    hr[0] = 1
    set(hr, 100, { 230, 0, 0 })
    set(hr, 200, { 215, 0, 0 })
    set(hr, 300, { 240, 0, 0 })
    for addr, v in pairs((overrides or {}).input or {}) do inp[addr] = v end
    for addr, v in pairs((overrides or {}).holding or {}) do hr[addr] = v end
    load()
    return driver_poll()
end

-- The gateway as it answered.
local interval = gateway()
if interval ~= 60000 then fail("poll interval " .. tostring(interval)) end
-- The host caps a returned interval at 30 s; the minute is set instead.
local set_ms
for _, call in ipairs(host._calls) do
    if call.func == "set_poll_interval" then set_ms = call.args[1] end
end
if set_ms ~= 60000 then fail("set_poll_interval " .. tostring(set_ms)) end
if host._make ~= "LK Systems" then fail("make " .. tostring(host._make)) end
if host._sn ~= "1111222233334444" then fail("sn " .. tostring(host._sn)) end
expect("zone_1_temp_c", 20.0, "°C")
expect("zone_2_temp_c", 20.9, "°C")
expect("zone_3_temp_c", 18.9, "°C")
expect("zone_1_humidity_pct", 39.8, "%")
expect("zone_3_humidity_pct", 43.6, "%")
expect("zone_1_battery_pct", 25, "%")
expect("zone_2_battery_pct", 99, "%")
expect("zone_1_signal_dbm", -79, "dBm")
expect("zone_3_signal_dbm", -86, "dBm")
expect("zone_1_setpoint_c", 23.0, "°C")
expect("zone_2_setpoint_c", 21.5, "°C")
expect("zone_3_setpoint_c", 24.0, "°C")
-- Zone 1 drives actuators 2, 4, 6 (42), zone 2 actuator 1, zone 3 3, 5, 7.
expect("zone_1_actuators_connected", 3)
expect("zone_2_actuators_connected", 1)
expect("zone_3_actuators_connected", 3)
expect("zone_1_heating", 1)
expect("zone_1_actuators_open_pct", 100, "%")
expect("zone_1_override", 0)
expect("zone_1_override_level_pct", 0, "%")
expect("actuator_1_open", 1)
expect("actuator_7_open", 1)
absent("actuator_8_open")
expect("lk_operating_mode", 1)
expect("lk_poll_ok", 1)
-- Zones 4-12 have no thermostat: all zeros is "empty", not 0 °C.
absent("zone_4_temp_c")
absent("zone_12_temp_c")
-- The thermostat address is never emitted.
for name in pairs(host._metrics) do
    if name:find("address") or name:find("mac") then fail("emitted " .. name) end
end

-- Some actuators closed, a negative temperature, an override half open.
gateway({
    input = { [61] = 0, [63] = 0, [65] = 0, [64] = 0, [100] = 65486 },
    holding = { [101] = 1, [102] = 128 },
})
expect("zone_1_heating", 0)
expect("zone_1_actuators_open_pct", 0, "%")
-- Actuator 5 (input 64) is closed, so zone 3 has two of three open.
expect("zone_3_actuators_open_pct", 200 / 3, "%")
expect("zone_1_temp_c", -5.0, "°C")
expect("zone_1_override", 1)
expect("zone_1_override_level_pct", 50.2, "%")
expect("actuator_2_open", 0)

-- Out-of-range values are not readings.
gateway({ input = { [200] = 2000, [201] = 1500, [202] = 250 } })
absent("zone_2_temp_c")
absent("zone_2_humidity_pct")
absent("zone_2_battery_pct")
expect("zone_2_signal_dbm", -55, "dBm")

-- The gateway does not answer: nothing at all, and the poll says so.
host.reset()
host._modbus_read_error = "timeout"
load()
driver_poll()
expect("lk_poll_ok", 0)
absent("zone_1_temp_c")
absent("lk_operating_mode")

-- Zones 1 and 2 are one request (input 100..207), zone 3 its own (300).
local function reads_of(addr)
    local n, counts = 0, {}
    for _, c in ipairs(host._calls or {}) do
        if c.func == "modbus_read" and (addr == nil or c.args[1] == addr) then
            n = n + 1
            counts[#counts + 1] = c.args[1] .. ":" .. c.args[2] .. ":" .. c.args[3]
        end
    end
    return n, table.concat(counts, " ")
end

-- The scan poll: actuators, six zone pairs, two holding requests (zones
-- 1-2 and 3), the mode, and the identity.
gateway()
local n, list = reads_of(nil)
if n ~= 11 then fail("scan poll requests " .. n .. ": " .. list) end
if not list:find("100:108:input", 1, true) then fail("zones 1-2 not one request: " .. list) end
if not list:find("100:103:holding", 1, true) then fail("holding 1-2 not one request: " .. list) end

-- An ordinary poll: actuators and two zone requests, nothing else. The
-- setpoint is not read, and not re-emitted from the last read either.
host._calls = {}
host._metrics = {}
driver_poll()
n, list = reads_of(nil)
if n ~= 3 then fail("ordinary poll requests " .. n .. ": " .. list) end
expect("zone_1_temp_c", 20.0, "°C")
expect("zone_3_temp_c", 18.9, "°C")
absent("zone_1_setpoint_c")
absent("lk_operating_mode")

-- Every fifth poll reads the settings again.
for _ = 1, 3 do driver_poll() end
host._metrics = {}
driver_poll()
expect("zone_1_setpoint_c", 23.0, "°C")
expect("zone_3_setpoint_c", 24.0, "°C")
expect("lk_operating_mode", 1)

-- Zone 3 stops answering after the scan: its readings stop, the rest go on.
gateway()
host._metrics = {}
host._modbus_read_fail_addresses[300] = "timeout"
driver_poll()
absent("zone_3_temp_c")
expect("zone_1_temp_c", 20.0, "°C")
expect("zone_2_temp_c", 20.9, "°C")
expect("lk_poll_ok", 1)

-- A scan in which zones 3-4 do not answer keeps zone 3 from the last scan
-- and is repeated after five polls, not half an hour.
gateway()
for _ = 1, 29 do driver_poll() end            -- up to the next scan
host._modbus_read_fail_addresses[300] = "timeout"
host._metrics = {}
driver_poll()                                  -- the incomplete scan
absent("zone_3_temp_c")
host._modbus_read_fail_addresses[300] = nil
host._calls = {}
for _ = 1, 5 do driver_poll() end
local scans = select(1, reads_of(1100))        -- zones 11-12, only scanned
if scans ~= 1 then fail("incomplete scan repeated " .. scans .. " times in 5 polls") end
expect("zone_3_temp_c", 18.9, "°C")

-- A register that keeps failing is left alone after three polls, and the
-- next zone scan (30 polls on) tries it again.
gateway()
host._modbus_read_fail_addresses[60] = "timeout"
local function actuator_reads()
    local n = 0
    for _, c in ipairs(host._calls or {}) do
        if c.func == "modbus_read" and c.args[1] == 60 then n = n + 1 end
    end
    return n
end
host._calls = {}
for _ = 1, 10 do driver_poll() end
if actuator_reads() ~= 3 then fail("actuator reads while failing: " .. actuator_reads()) end
host._modbus_read_fail_addresses[60] = nil
host._calls = {}
for _ = 1, 25 do driver_poll() end
if actuator_reads() < 1 then fail("actuators never retried after the scan") end
expect("actuator_1_open", 1)

if failed > 0 then
    print("FAILED " .. failed)
    os.exit(1)
end
print("PASS")
