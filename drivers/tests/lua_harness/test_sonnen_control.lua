-- sonnen control: manual setpoints, the driver-side lease, default mode and
-- the refusal paths, against a fake unit that behaves like a sonnenBatterie
-- with software 1.40.5: setpoints only take effect in manual mode ("1"),
-- the mode changes only through PUT /api/v2/configurations, and a manual
-- setpoint holds until it is replaced.

dofile("drivers/tests/lua_harness/host_mock.lua")

local BASE = "http://192.0.2.10:80/api/v2"
local unit
local writes

local function fail(msg) error(msg, 2) end

-- In the automatic modes a real unit reports its own load-following
-- target in SetPoint_W and covers the house load (seen: 1255 W), so the
-- fake does the same instead of reporting 0.
local LOAD_W = 1255

local function new_unit(mode)
    unit = { mode = mode, setpoint = 0, token = "token", rated = "9900",
             refuse_put = nil, unauthorized = false, omit_mode = false }
    writes = {}
end

local function install_fake_unit(with_put)
    host.http_get = function(url, headers)
        if (headers or {})["Auth-Token"] ~= unit.token or unit.unauthorized then
            return '{"error":"Unauthorized"}'
        end
        if url == BASE .. "/configurations" then
            local m = '"EM_OperatingMode":"' .. unit.mode .. '",'
            if unit.omit_mode then m = "" end
            return '{' .. m .. '"IC_InverterMaxPower_w":"'
                .. unit.rated .. '","DE_Software":"1.40.5"}'
        elseif url == BASE .. "/latestdata" then
            -- Manual mode: the battery follows FTW's setpoint. Automatic
            -- modes: it follows the house load. Sonnen sign.
            local pac, sp = LOAD_W, LOAD_W
            if unit.mode == "1" then pac, sp = unit.setpoint, unit.setpoint end
            return '{"FullChargeCapacity":18700,"Pac_total_W":' .. pac ..
                ',"RSOC":45,"USOC":40,"SetPoint_W":' .. sp ..
                ',"Timestamp":"2026-11-13 20:03:26","UTC_Offset":1}'
        end
        return nil, "HTTP 404"
    end
    host.http_post = function(url, body, headers)
        table.insert(writes, "POST " .. url)
        local dir, n = string.match(url, "/setpoint/(%a+)/(%d+)$")
        if not dir then return nil, "HTTP 404" end
        if unit.mode ~= "1" then return nil, "HTTP 403" end
        n = tonumber(n)
        if dir == "charge" then unit.setpoint = -n else unit.setpoint = n end
        return "true"
    end
    if with_put then
        host.http_put = function(url, body, headers)
            table.insert(writes, "PUT " .. url .. " " .. body)
            if unit.refuse_put then return nil, unit.refuse_put end
            if headers["Auth-Token"] ~= unit.token then return nil, "HTTP 401" end
            if headers["Content-Type"] ~= "application/x-www-form-urlencoded" then
                return nil, "HTTP 415"
            end
            local m = string.match(body, "^EM_OperatingMode=(%d+)$")
            if url ~= BASE .. "/configurations" or not m then return nil, "HTTP 404" end
            unit.mode = m
            if m ~= "1" then unit.setpoint = 0 end
            return '{"EM_OperatingMode":"' .. m .. '"}'
        end
    else
        host.http_put = nil
    end
end

local function boot(mode, config, with_put)
    host.reset()
    new_unit(mode)
    install_fake_unit(with_put ~= false)
    dofile("drivers/lua/sonnen.lua")
    local cfg = { host = "192.0.2.10", port = 80, api_token = "token" }
    for k, v in pairs(config or {}) do cfg[k] = v end
    driver_init(cfg)
end

local function poll()
    local ok, err = pcall(driver_poll)
    if not ok then fail("driver_poll failed: " .. tostring(err)) end
    local list = host._emitted.battery or {}
    return list[#list], #list
end

local function advance(ms)
    host._millis_counter = host._millis_counter + ms
end

-- ---- Telemetry and control feedback ---------------------------------------

boot("2")
if #writes ~= 0 then fail("init in self-consumption must not write") end
if DRIVER.read_only then fail("control driver must not declare read_only") end
local b = poll()
if b.w ~= -LOAD_W then fail("self-consumption reading wrong: " .. tostring(b.w)) end
if b.setpoint_w ~= nil then
    fail("setpoint_w must be absent in mode 2, got " .. tostring(b.setpoint_w))
end
if b.control_power_observed_at ~= "2026-11-13T20:03:26+01:00" then
    fail("observed_at = " .. tostring(b.control_power_observed_at))
end
if b.control_power_available ~= true then fail("control power must be available") end

-- ---- Charge: manual mode, then the setpoint -------------------------------

if driver_command("init", 0, {}) ~= true then fail("init action failed") end
if #writes ~= 0 then fail("init action must not write") end
local r = driver_command("battery", 1500, {})
if r ~= true then fail("charge command failed: " .. tostring(r)) end
if writes[1] ~= "PUT " .. BASE .. "/configurations EM_OperatingMode=1" or
   writes[2] ~= "POST " .. BASE .. "/setpoint/charge/1500" then
    fail("charge writes: " .. table.concat(writes, " | "))
end
b = poll()
if b.w ~= 1500 or b.setpoint_w ~= 1500 or b.control_power_w ~= 1500 then
    fail("charging must read +1500 in site signs, got w=" .. tostring(b.w)
        .. " setpoint_w=" .. tostring(b.setpoint_w))
end

-- A second command in manual mode does not switch the mode again.
writes = {}
driver_command("battery", 800, {})
if #writes ~= 1 or writes[1] ~= "POST " .. BASE .. "/setpoint/charge/800" then
    fail("repeat command writes: " .. table.concat(writes, " | "))
end

-- ---- Discharge is clamped to the lower of rating and owner cap -------------

boot("2", { max_power_w = 4000 })
driver_command("battery", -20000, {})
if unit.setpoint ~= 4000 then fail("discharge not clamped to owner cap: " .. unit.setpoint) end
b = poll()
if b.w ~= -4000 then fail("discharging must read -4000, got " .. tostring(b.w)) end
boot("2")
driver_command("battery", 20000, {})
if unit.setpoint ~= -9900 then fail("charge not clamped to inverter rating: " .. unit.setpoint) end

-- ---- The unit leaves manual mode behind FTW's back -------------------------

boot("2")
driver_command("battery", 500, {})
unit.mode = "2"
unit.setpoint = 0
r = driver_command("battery", 700, {})
if r ~= true or unit.mode ~= "1" or unit.setpoint ~= -700 then
    fail("recovery after external mode change failed: " .. tostring(r))
end

-- ---- Lease: no command for a minute hands the unit back -------------------

boot("2")
driver_command("battery", 1000, {})
advance(30000)
poll()
if unit.mode ~= "1" then fail("lease expired too early") end
advance(31000)
poll()
if unit.mode ~= "2" or unit.setpoint ~= 0 then
    fail("lease expiry must clear the setpoint and restore mode 2, got mode "
        .. unit.mode .. " setpoint " .. unit.setpoint)
end
writes = {}
advance(120000)
poll()
if #writes ~= 0 then fail("after the lease the driver must stop writing") end

-- ---- Default mode ----------------------------------------------------------

boot("2")
driver_command("battery", -1200, {})
if driver_default_mode() ~= true then fail("default mode failed") end
if unit.mode ~= "2" or unit.setpoint ~= 0 then fail("default mode did not restore") end
writes = {}
if driver_default_mode() ~= true or #writes ~= 0 then
    fail("default mode on a unit already in automatic mode must not write")
end
if driver_command("deinit", 0, {}) ~= true then fail("deinit failed") end

-- The automatic mode the unit ran before is the one restored.
boot("10")
driver_command("battery", 300, {})
driver_default_mode()
if unit.mode ~= "10" then fail("time-of-use was not restored, got " .. unit.mode) end

-- ---- A manual mode left by a stopped FTW is cleared at start --------------

host.reset()
new_unit("1")
unit.setpoint = -2500
install_fake_unit(true)
dofile("drivers/lua/sonnen.lua")
driver_init({ host = "192.0.2.10", port = 80, api_token = "token" })
if unit.mode ~= "2" or unit.setpoint ~= 0 then
    fail("orphan manual mode not cleared at init")
end

-- ---- An owner's manual idle (setpoint 0) is left alone --------------------

host.reset()
new_unit("1")
install_fake_unit(true)
dofile("drivers/lua/sonnen.lua")
driver_init({ host = "192.0.2.10", port = 80, api_token = "token" })
if #writes ~= 0 or unit.mode ~= "1" then fail("init changed an owner's manual idle") end
if driver_default_mode() ~= true or #writes ~= 0 then
    fail("default mode must leave an owner's manual idle untouched")
end
-- FTW then takes control; afterwards the unit goes back to self-consumption.
driver_command("battery", 400, {})
driver_default_mode()
if unit.mode ~= "2" or unit.setpoint ~= 0 then fail("own session was not handed back") end

-- ---- Without allow_write nothing is written, even from manual mode --------

host.reset()
new_unit("1")
unit.setpoint = -1500  -- left by a stopped FTW
unit.refuse_put = "http: write not granted (set capabilities.http.allow_write)"
install_fake_unit(true)
dofile("drivers/lua/sonnen.lua")
driver_init({ host = "192.0.2.10", port = 80, api_token = "token" })
driver_command("battery", 700, {})
driver_default_mode()
for _, w in ipairs(writes) do
    if string.find(w, "^POST") then fail("posted without write access: " .. w) end
end
if unit.setpoint ~= -1500 or unit.mode ~= "1" then fail("unit changed without write access") end

-- ---- A failed read emits nothing ------------------------------------------

boot("2")
unit.unauthorized = true
local _, count = poll()
if count ~= 0 then fail("an Unauthorized answer must not become a reading") end

-- ---- No setpoint without a confirmed PUT ----------------------------------
-- The unit already sits in manual mode (owner, app), and the host refuses
-- the PUT (no allow_write). http_post is not gated by allow_write, so the
-- driver itself must not post a setpoint.

host.reset()
new_unit("1")
unit.refuse_put = "http: write not granted (set capabilities.http.allow_write)"
install_fake_unit(true)
dofile("drivers/lua/sonnen.lua")
driver_init({ host = "192.0.2.10", port = 80, api_token = "token" })
if unit.mode ~= "1" then fail("setup: unit should still be in manual mode") end
writes = {}
r = driver_command("battery", 900, {})
if r == true then fail("command must fail when the PUT is refused") end
for _, w in ipairs(writes) do
    if string.find(w, "^POST") then fail("posted a setpoint without a confirmed PUT: " .. w) end
end
if unit.setpoint ~= 0 then fail("setpoint changed without a confirmed PUT") end

-- ---- Without host.http_put the driver refuses control ---------------------

boot("2", nil, false)
r = driver_command("battery", 1000, {})
if r == true or type(r) ~= "string" then fail("command without http_put must be refused") end
if #writes ~= 0 or unit.mode ~= "2" then fail("command without http_put wrote") end
if driver_default_mode() ~= true or #writes ~= 0 then
    fail("default mode without http_put must hold without writing")
end
b = poll()
if b.w ~= -LOAD_W then fail("telemetry must still work without http_put") end

-- ---- Refused writes stop the unprompted path ------------------------------

boot("2")
driver_command("battery", 1000, {})
unit.refuse_put = "HTTP 401"
for _ = 1, 3 do driver_default_mode() end
writes = {}
for _ = 1, 5 do driver_default_mode() end
if #writes ~= 0 then fail("default mode kept writing after refusals: " .. #writes) end

-- ---- Network loss must not use up the hand-back attempts -----------------
-- FTW's watchdog calls default mode while the unit is unreachable. Those
-- failures are not refusals; once the network returns, the lease must still
-- hand the unit back.

boot("2")
driver_command("battery", 600, {})
local real_get, real_post, real_put = host.http_get, host.http_post, host.http_put
host.http_get = function() return nil, "dial tcp 192.0.2.10:80: i/o timeout" end
host.http_post = function() return nil, "dial tcp 192.0.2.10:80: i/o timeout" end
host.http_put = function() return nil, "dial tcp 192.0.2.10:80: i/o timeout" end
for _ = 1, 6 do
    if driver_default_mode() == true then fail("default mode cannot succeed while unreachable") end
end
if unit.mode ~= "1" then fail("setup: unit should still hold manual mode") end
host.http_get, host.http_post, host.http_put = real_get, real_post, real_put
advance(61000)
poll()
if unit.mode ~= "2" or unit.setpoint ~= 0 then
    fail("after network loss the lease must hand the unit back, got mode "
        .. unit.mode .. " setpoint " .. unit.setpoint)
end

-- ---- setpoint_w follows a fresh mode read, not a cached one --------------
-- FTW put the unit in manual mode; then the app sets self-consumption. The
-- load-following SetPoint_W must not be reported as a setpoint.

boot("2")
driver_command("battery", 500, {})
unit.mode = "2"
b = poll()
if b.setpoint_w ~= nil then
    fail("setpoint_w reported after the unit left manual mode: " .. tostring(b.setpoint_w))
end

-- ---- A configurations reply without EM_OperatingMode is a failed read -----
-- The driver last saw mode 2. Another controller now holds a manual setpoint
-- and the reply omits the mode. Default mode must not claim the unit is in
-- automatic mode, and must not write blind.

boot("2")
unit.mode = "1"
unit.setpoint = -2500
unit.omit_mode = true
writes = {}
if driver_default_mode() == true then
    fail("default mode trusted a cached mode when the reply had none")
end
if #writes ~= 0 then fail("wrote without a confirmed mode: " .. table.concat(writes, " | ")) end

print("OK")
