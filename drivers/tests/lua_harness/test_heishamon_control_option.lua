-- control: false keeps heishamon read-only. The metrics still arrive, DRIVER.controls is empty and no
-- Z1_Heat_Request_Temp is ever published, so Home Assistant or the pump's own controller keeps the offset.
dofile("drivers/tests/lua_harness/host_mock.lua")

host.mqtt_publish = function(topic, payload)
    table.insert(host._calls, { func = "mqtt_publish", args = { topic, payload } })
    return nil
end

local SET = "panasonic_heat_pump/set/Z1_Heat_Request_Temp"

local function publishes()
    local out = {}
    for _, c in ipairs(host._calls) do
        if c.func == "mqtt_publish" and c.args[1] == SET then
            table.insert(out, c.args[2])
        end
    end
    return out
end

local function fresh_driver(config)
    host.reset()
    dofile("drivers/lua/heishamon.lua")
    driver_init(config)
end

-- Default: control stays on, as before this option existed.
fresh_driver({})
assert(#DRIVER.controls > 0, "controls must be offered by default")
assert(driver_command("set_heat_curve_offset", 0, { value = 2 }) == true, "default must still write")
assert(#publishes() == 1 and publishes()[1] == "2", "default write did not publish the offset")

-- control: true behaves like the default.
fresh_driver({ control = true })
assert(#DRIVER.controls > 0, "control: true must offer controls")

-- control: false (and the spellings a YAML or string config produces): read-only.
for _, off in ipairs({ false, 0, "false", "False", "no", "off", "0" }) do
    fresh_driver({ control = off })
    assert(#DRIVER.controls == 0, "control = " .. tostring(off) .. " must empty DRIVER.controls")
    assert(driver_command("set_heat_curve_offset", 0, { value = 2 }) == false,
        "control = " .. tostring(off) .. " must refuse the command")
    driver_default_mode()
    driver_cleanup()
    assert(#publishes() == 0, "control = " .. tostring(off) .. " must never publish an offset")
end

-- Anything else that is set keeps control on.
for _, on in ipairs({ true, 1, "true", "yes", "on" }) do
    fresh_driver({ control = on })
    assert(#DRIVER.controls > 0, "control = " .. tostring(on) .. " must keep controls")
end

print("heishamon control option ok")
