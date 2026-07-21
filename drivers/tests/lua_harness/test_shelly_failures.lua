local app = arg[1]
if not app then error("Shelly app is required") end
local scenario = arg[2] or "all"

dofile("drivers/tests/lua_harness/host_mock.lua")
host.reset()
host._http_responses["http://127.0.0.1:80/rpc/Shelly.GetDeviceInfo"] =
    '{"app":"' .. app .. '"}'

dofile("drivers/lua/shelly.lua")
driver_init({host = "127.0.0.1", port = 80})
host._http_responses = {}
host._emitted = {}

if scenario == "partial" then
    local endpoint_by_app = {
        ProEM = "EM1.GetStatus",
        Plus2PM = "Switch.GetStatus",
        Pro4PM = "Switch.GetStatus",
    }
    local endpoint = endpoint_by_app[app]
    if not endpoint then error("partial scenario does not support app: " .. app) end
    local power_field = endpoint == "EM1.GetStatus" and "act_power" or "apower"
    host._http_responses["http://127.0.0.1:80/rpc/" .. endpoint .. "?id=0"] =
        '{"' .. power_field .. '":123}'
elseif scenario ~= "all" then
    error("unknown scenario: " .. scenario)
end

local ok, poll_error = pcall(driver_poll)
if not ok then error("failed HTTP poll raised: " .. tostring(poll_error)) end
if host._emitted.meter and #host._emitted.meter > 0 then
    error(scenario .. " HTTP poll emitted a meter sample")
end
