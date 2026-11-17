-- Default mode and cleanup must reset only an offset FTW wrote. An owner
-- who sets Z1_Heat_Request_Temp from Home Assistant keeps it across Core
-- restarts and watchdog trips (srcfl/device-drivers#233).
dofile("drivers/tests/lua_harness/host_mock.lua")

-- FTW's host.mqtt_publish returns nothing on success and an error string on
-- failure (go/internal/drivers/lua.go). The shared mock returns true, which
-- this driver reads as an error, so record publishes the way the host does.
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
    driver_init(config or {})
end

-- Startup default mode, before FTW sent anything: no write.
fresh_driver()
driver_default_mode()
assert(#publishes() == 0, "startup default mode overwrote an offset FTW never wrote")

-- Cleanup without a command: no write.
driver_cleanup()
assert(#publishes() == 0, "cleanup overwrote an offset FTW never wrote")

-- After FTW writes, default mode resets once, then leaves the pump alone.
fresh_driver({ safe_offset = 1 })
assert(driver_command("set_heat_curve_offset", 0, { value = 3 }) == true, "command failed")
driver_default_mode()
local p = publishes()
assert(#p == 2 and p[1] == "3" and p[2] == "1", "default mode did not reset FTW's offset to safe_offset")
driver_default_mode()
assert(#publishes() == 2, "a second default mode wrote again after the reset")

-- After FTW writes, cleanup resets.
fresh_driver()
driver_command("set_heat_curve_offset", 0, { offset = -2 })
driver_cleanup()
p = publishes()
assert(#p == 2 and p[2] == "0", "cleanup did not reset FTW's offset")

-- A rejected command (no value) writes nothing and arms no reset.
fresh_driver()
assert(driver_command("set_heat_curve_offset", 0, {}) == false, "command without value succeeded")
driver_default_mode()
assert(#publishes() == 0, "a rejected command armed a reset")

-- A failed reset keeps the mark, so the next default mode tries again.
fresh_driver()
driver_command("set_heat_curve_offset", 0, { value = 2 })
local real_publish = host.mqtt_publish
host.mqtt_publish = function() return "broker down" end
driver_default_mode()
host.mqtt_publish = real_publish
driver_default_mode()
p = publishes()
assert(#p == 2 and p[2] == "0", "a failed reset was not retried")
