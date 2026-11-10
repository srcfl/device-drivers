-- ctc_ecozenith: decode the registers an EcoZenith i255 actually returned.
--
-- The first case is the raw holding-register values read from one i255
-- (display software 2024-07-19) on 2026-11-10, not invented numbers.
--
-- Usage: lua55 test_ctc_ecozenith.lua

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

local function i255(overrides)
    host.reset()
    local h = host._modbus_registers.holding
    -- 62000..62015 as one block, exactly as read.
    local block = { 40, 570, 0, 0, 180, 1, 330, 280, 0, 0, 0, 260, -9999, 0, 0, 250 }
    for i, v in ipairs(block) do h[62000 + i - 1] = v end
    h[62017] = 0
    h[62027] = 280
    h[62037] = 311
    h[62157] = 29442
    h[62168] = 0
    h[62169] = 0
    h[62193] = 0
    h[62203] = 0
    h[62244] = 719
    h[62245] = 2024
    h[62253] = 39
    h[62274] = 350
    h[62275] = 0
    h[62276] = 570
    h[61509] = 200
    h[61513] = 350
    h[61517] = 10
    for addr, v in pairs(overrides or {}) do h[addr] = v end
    dofile(ROOT .. "drivers/lua/ctc_ecozenith.lua")
    driver_init({})
    return driver_poll()
end

-- The pump as it answered.
local interval = i255()
if interval ~= 30000 then fail("poll interval " .. tostring(interval)) end
if host._make ~= "CTC" then fail("make " .. tostring(host._make)) end
expect("hp_outdoor_temp_c", 4.0, "°C")
expect("hp_radiator_temp_c", 33.0, "°C")
expect("hp_flow_temp_c", 26.0, "°C")
expect("hp_return_temp_c", 25.0, "°C")
expect("hp_inlet_temp_c", 28.0, "°C")
expect("hp_outlet_temp_c", 31.1, "°C")
expect("hp_hw_top_temp_c", 57.0, "°C")
expect("hp_lower_tank_setpoint_c", 35.0, "°C")
expect("hp_room_setpoint_c", 20.0, "°C")
expect("hp_curve_inclination", 35.0)
expect("hp_curve_adjustment_c", 1.0, "°C")
expect("hp_compressor_rps", 0)
expect("hp_immersion_upper_w", 0, "W")
expect("hp_immersion_lower_w", 0, "W")
expect("hp_ctc_status", 1)
expect("hp_ctc_compressor_status", 0)
expect("hp_ctc_product_type", 39)
expect("hp_poll_ok", 1)
-- No room sensor is fitted: 0 is "not fitted", not 0 °C.
absent("hp_indoor_temp_c")
-- No electrical input register exists; none is made up.
absent("hp_power_w")

-- A fitted room sensor, the heater running, a negative outdoor reading,
-- and an open sensor on the flow.
i255({ [62203] = 215, [62168] = 32, [62193] = 523, [62000] = -85, [62011] = -9999 })
expect("hp_indoor_temp_c", 21.5, "°C")
expect("hp_immersion_upper_w", 3200, "W")
expect("hp_compressor_rps", 52.3)
expect("hp_outdoor_temp_c", -8.5, "°C")
absent("hp_flow_temp_c")

-- Outdoor 0.0 °C is a real reading and must not be dropped.
i255({ [62000] = 0 })
expect("hp_outdoor_temp_c", 0, "°C")

-- The main block does not answer: nothing from it, and the poll says so.
host.reset()
local h = host._modbus_registers.holding
h[62276] = 570
host._modbus_read_fail_addresses[62000] = "timeout"
dofile(ROOT .. "drivers/lua/ctc_ecozenith.lua")
driver_init({})
driver_poll()
absent("hp_outdoor_temp_c")
absent("hp_return_temp_c")
expect("hp_poll_ok", 0)
expect("hp_hw_top_temp_c", 57.0, "°C")

if failed > 0 then
    print("FAILED " .. failed)
    os.exit(1)
end
print("PASS")
