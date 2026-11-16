-- sonnen: battery.w sign. sonnen reports Pac_total_W positive while
-- discharging and negative while charging; FTW's battery.w is positive while
-- charging. Bodies follow /api/v2/latestdata from a sonnenBatterie running
-- software 1.40.5.

dofile("drivers/tests/lua_harness/host_mock.lua")

local URL = "http://192.0.2.10:80/api/v2/latestdata"

local function latest(pac_w, setpoint_w)
    return '{"Consumption_W":2259,"FullChargeCapacity":18700,' ..
        '"GridFeedIn_W":-2240,"Pac_total_W":' .. tostring(pac_w) ..
        ',"Production_W":16,"RSOC":45,"SetPoint_W":' .. tostring(setpoint_w) ..
        ',"Timestamp":"2026-11-13 20:03:26","USOC":40,"UTC_Offset":1}'
end

local function poll_battery_w(body)
    host.reset()
    dofile("drivers/lua/sonnen.lua")
    driver_init({ host = "192.0.2.10", port = 80, api_token = "token" })
    host._http_responses[URL] = body
    local ok, err = pcall(driver_poll)
    if not ok then error("driver_poll failed: " .. tostring(err)) end
    local list = host._emitted.battery
    if not list or #list == 0 then error("no battery emit") end
    return list[#list]
end

-- Charging: shaped like the readback of a 500 W charge setpoint
-- (measured -495 to -504 W; -500 here).
local charging = poll_battery_w(latest(-500, -500))
if charging.w ~= 500 then
    error("charging must be +500 W in site convention, got " .. tostring(charging.w))
end
if math.abs(charging.soc - 0.40) > 1e-9 then
    error("soc must come from USOC as a fraction, got " .. tostring(charging.soc))
end
if charging.capacity_wh ~= 18700 then
    error("capacity_wh lost: " .. tostring(charging.capacity_wh))
end

-- Discharging.
local discharging = poll_battery_w(latest(1200, 0))
if discharging.w ~= -1200 then
    error("discharging must be -1200 W in site convention, got " .. tostring(discharging.w))
end

-- The raw vendor value stays available, unconverted, as a metric.
if not host._metrics.battery_pac_w or host._metrics.battery_pac_w.value ~= 1200 then
    error("battery_pac_w must keep the vendor sign")
end

print("OK")
