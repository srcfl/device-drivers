-- NIBE local-API driver: FTW v1 contract + the opt-in Solar PV write path
-- (srcfl/ftw#537). The fake pump speaks the Local REST API dialect FTW's
-- hermetic Go test established: points keyed by variableId, metadata carrying
-- modbusRegisterID/divisor/variableSize, values as datavalue objects.

dofile("drivers/tests/lua_harness/host_mock.lua")

local SERIAL = "06613225140002"
local BASE = "https://pump"
local DEVICES_URL = BASE .. "/api/v1/devices"
local POINTS_URL = BASE .. "/api/v1/devices/" .. SERIAL .. "/points"

local DEVICES_BODY =
    '{"devices":[{"product":{"manufacturer":"NIBE","name":"S735",' ..
    '"firmwareId":"nibe-n","serialNumber":"' .. SERIAL .. '"}}]}'

-- The Solar PV points live on DIFFERENT variableIds (5201/5202) than their
-- Modbus registers (2107/2109) — resolution must go through metadata.
local function points_body(enable_val, avail_raw)
    return '{' ..
        '"1801":{"title":"Compressor power","metadata":{"variableSize":"u32",' ..
        '"unit":"W","divisor":1,"modbusRegisterID":1801,"isWritable":false},' ..
        '"value":{"type":"datavalue","isOk":true,"integerValue":1234}},' ..
        '"4":{"title":"Outdoor temp BT1","metadata":{"variableSize":"s16",' ..
        '"unit":"\194\176C","divisor":10,"modbusRegisterID":4,"isWritable":false},' ..
        '"value":{"type":"datavalue","isOk":true,"integerValue":-53}},' ..
        '"5201":{"title":"Modbus TCP/IP Ext. (Solar PV)","metadata":{"variableSize":"u8",' ..
        '"unit":"","divisor":1,"modbusRegisterID":2107,"isWritable":true},' ..
        '"value":{"type":"datavalue","isOk":true,"integerValue":' .. tostring(enable_val) .. '}},' ..
        '"5202":{"title":"Available power","metadata":{"variableSize":"u16",' ..
        '"unit":"W","divisor":1,"modbusRegisterID":2109,"isWritable":true},' ..
        '"value":{"type":"datavalue","isOk":true,"integerValue":' .. tostring(avail_raw) .. '}}' ..
        '}'
end

local function boot(write_config, enable_val, avail_raw)
    host.reset()
    dofile("drivers/lua/nibe_local.lua")
    host._http_responses[DEVICES_URL] = DEVICES_BODY
    host._http_responses[POINTS_URL] = points_body(enable_val, avail_raw)
    driver_init({
        base_url = BASE, username = "u", password = "p",
        write = write_config,
    })
    local ok, err = pcall(driver_poll)
    if not ok then error("driver_poll failed: " .. tostring(err)) end
end

local function patch_count()
    return #host._http_patches
end

local function last_patch()
    return host._http_patches[#host._http_patches]
end

-- ---- Metadata and read-only-by-default contract ---------------------------

boot(nil, 1, 0)

if type(DRIVER) ~= "table" or DRIVER.id ~= "nibe-local" or DRIVER.version ~= "1.2.0" then
    error("NIBE identity metadata is wrong")
end
if DRIVER.host_api_min ~= 1 or DRIVER.host_api_max ~= 1 then
    error("NIBE host API range changed")
end
if type(driver_init) ~= "function" or type(driver_poll) ~= "function" or
   type(driver_command) ~= "function" or type(driver_default_mode) ~= "function" or
   type(driver_cleanup) ~= "function" then
    error("NIBE lifecycle is incomplete")
end
if host._make ~= "NIBE" or host._sn ~= SERIAL then
    error("NIBE did not report make/serial")
end
if not host._metrics.hp_power_w or host._metrics.hp_power_w.value ~= 1234 then
    error("NIBE headline power metric missing or wrong")
end
if not host._metrics.hp_outdoor_temp_c or host._metrics.hp_outdoor_temp_c.value ~= -5.3 then
    error("NIBE divisor scaling broke: " ..
        tostring(host._metrics.hp_outdoor_temp_c and host._metrics.hp_outdoor_temp_c.value))
end

-- Without write config every write door is closed.
local res = driver_command("solar_pv", -3000, {})
if type(res) ~= "string" or not string.find(res, "disabled", 1, true) then
    error("solar_pv without opt-in must return an explanatory error, got: " .. tostring(res))
end
if driver_command("battery", 1000, {}) ~= false then
    error("non-solar_pv actions must still be rejected with false")
end
driver_default_mode()
driver_cleanup()
if patch_count() ~= 0 then
    error("read-only lifecycle attempted an HTTP write")
end

-- Enabling the feed without max_w must refuse NEW writes and say why.
boot({ solar_pv = true }, 1, 0)
res = driver_command("solar_pv", -3000, {})
if type(res) ~= "string" or not string.find(res, "max_w", 1, true) then
    error("solar_pv without max_w must name the missing key, got: " .. tostring(res))
end
if patch_count() ~= 0 then error("missing max_w still allowed a write") end

-- ...but the clearing machinery stays armed on the same invalid config: an
-- orphaned feed from a previous run is still swept on startup.
boot({ solar_pv = true }, 1, 620)
if patch_count() ~= 1 or not string.find(last_patch().body, '"integerValue":0', 1, true) then
    error("invalid write config must not disarm the orphan sweep")
end

-- ---- The write path -------------------------------------------------------

boot({ solar_pv = true, max_w = 9000, min_interval_ms = 0 }, 1, 0)
if patch_count() ~= 0 then error("poll with a clean pump must not write") end

-- Site convention in, pump value out: -3000 W (export) → 3000.
res = driver_command("solar_pv", -3000, {})
if res ~= true then error("solar_pv command failed: " .. tostring(res)) end
if patch_count() ~= 1 then error("expected exactly one PATCH") end
local p = last_patch()
if not string.find(p.url, "/api/v1/devices/" .. SERIAL .. "/points", 1, true) then
    error("PATCH went to the wrong endpoint: " .. tostring(p.url))
end
if not string.find(p.body, '"variableId":5202', 1, true) then
    error("PATCH must target the resolved variableId of register 2109: " .. p.body)
end
if not string.find(p.body, '"integerValue":3000', 1, true) then
    error("PATCH carried the wrong value: " .. p.body)
end
if not string.find(p.body, '"type":"datavalue"', 1, true) then
    error("PATCH body is not a datavalue array: " .. p.body)
end
if not (p.headers and p.headers["Content-Type"] == "application/json") then
    error("PATCH must declare a JSON content type")
end
if not host._metrics.hp_solar_pv_feed_w or host._metrics.hp_solar_pv_feed_w.value ~= 3000 then
    error("feed observability metric missing")
end

-- Clamp to max_w: a 50 kW claim must never reach the pump.
res = driver_command("solar_pv", -50000, {})
if res ~= true then error("clamped command failed: " .. tostring(res)) end
if patch_count() ~= 2 or not string.find(last_patch().body, '"integerValue":9000', 1, true) then
    error("clamp to write.max_w failed: " .. last_patch().body)
end

-- Deadband: 20 W of movement is churn, not signal.
res = driver_command("solar_pv", -8980, {})
if res ~= true or patch_count() ~= 2 then
    error("deadband failed to swallow a 20 W change")
end

-- Import (positive site W) means no surplus → explicit 0, always written.
res = driver_command("solar_pv", 2500, {})
if res ~= true or patch_count() ~= 3 or
   not string.find(last_patch().body, '"integerValue":0', 1, true) then
    error("positive power_w must clear the feed to 0")
end
-- A second zero is a no-op, not another request.
res = driver_command("solar_pv", 0, {})
if res ~= true or patch_count() ~= 3 then
    error("repeated zero must not re-write")
end

-- ---- Rate limiting keeps the safety direction ----------------------------

-- With the default 60 s min-interval: increases inside the window are
-- swallowed, but a collapse of the surplus is written immediately.
boot({ solar_pv = true, max_w = 9000 }, 1, 0)
res = driver_command("solar_pv", -9000, {})
if res ~= true or patch_count() ~= 1 then error("first feed write failed") end
res = driver_command("solar_pv", -5000, {})
if res ~= true or patch_count() ~= 2 or
   not string.find(last_patch().body, '"integerValue":5000', 1, true) then
    error("a large surplus decrease must bypass the rate limit")
end
res = driver_command("solar_pv", -8000, {})
if res ~= true or patch_count() ~= 2 then
    error("an increase inside min_interval must be swallowed")
end

-- ---- Pump-side gates ------------------------------------------------------

-- Owner has not enabled the Solar PV input (2107 = 0): refuse loudly.
boot({ solar_pv = true, max_w = 9000 }, 0, 0)
res = driver_command("solar_pv", -3000, {})
if type(res) ~= "string" or not string.find(res, "2107", 1, true) then
    error("disabled 2107 must be surfaced, got: " .. tostring(res))
end
if patch_count() ~= 0 then error("disabled 2107 still allowed a write") end

-- An explicit clear bypasses the enable gate: the owner turning 2107 off
-- mid-feed must not block FTW from zeroing what it wrote.
res = driver_command("solar_pv", 0, {})
if res ~= true or patch_count() ~= 1 or
   not string.find(last_patch().body, '"integerValue":0', 1, true) then
    error("clear must go through with 2107 disabled, got: " .. tostring(res))
end

-- Pump API left read-only (installer menu 7.5.15): HTTP 200 with a
-- per-point error string. Must be surfaced as failure, not success.
boot({ solar_pv = true, max_w = 9000 }, 1, 0)
host._http_patch_responses[POINTS_URL] =
    '[{"status":"error: read only value"}]'
res = driver_command("solar_pv", -3000, {})
if type(res) ~= "string" or not string.find(res, "7.5.15", 1, true) then
    error("silent pump-side rejection must be surfaced, got: " .. tostring(res))
end
if host._metrics.hp_solar_pv_feed_w then
    error("a refused write must not report a live feed metric")
end

-- ---- Dead-man's switch, orphan clear, default mode ------------------------

-- Commands stop arriving → the driver clears the feed on its own.
boot({ solar_pv = true, max_w = 9000, ttl_s = 60 }, 1, 0)
res = driver_command("solar_pv", -4000, {})
if res ~= true or patch_count() ~= 1 then error("feed write failed") end
host._millis_counter = host._millis_counter + 120000  -- 2 min of silence
local ok2, err2 = pcall(driver_poll)
if not ok2 then error("poll during dead-man clear failed: " .. tostring(err2)) end
if patch_count() ~= 2 or not string.find(last_patch().body, '"integerValue":0', 1, true) then
    error("dead-man's switch did not clear the stale feed")
end

-- A previous run died mid-feed: the pump still shows 750 W. First poll
-- after startup must clear it (the pump-side timeout is undocumented).
boot({ solar_pv = true, max_w = 9000 }, 1, 750)
if patch_count() ~= 1 or not string.find(last_patch().body, '"integerValue":0', 1, true) then
    error("orphaned feed was not cleared on startup")
end

-- The u16 not-connected sentinel is NOT a standing feed: writing 0 over it
-- would turn "no accessory" into "accessory reporting zero".
boot({ solar_pv = true, max_w = 9000 }, 1, 65535)
if patch_count() ~= 0 then
    error("orphan sweep must not clear the not-connected sentinel")
end

-- default mode clears an active feed, once, and is quiet when idle.
boot({ solar_pv = true, max_w = 9000 }, 1, 0)
res = driver_command("solar_pv", -4000, {})
if res ~= true then error("feed write failed: " .. tostring(res)) end
local before = patch_count()
driver_default_mode()
if patch_count() ~= before + 1 or
   not string.find(last_patch().body, '"integerValue":0', 1, true) then
    error("default mode did not clear the feed")
end
driver_default_mode()
driver_default_mode()
if patch_count() ~= before + 1 then
    error("default mode must be idempotent once the feed is cleared")
end

print("nibe_local FTW contract + solar PV write path: OK")
