-- victron_mqtt keeps the GX publishing with the Venus keep-alive.
-- Run with the scenario as arg[1].
--
-- Venus OS (victronenergy/dbus-flashmq README, "Keep-alive"): a read
-- request to R/<portal ID>/keepalive keeps the GX publishing for 60 s; an
-- empty payload asks for a full republish, which ends with
-- N/<portal ID>/full_publish_completed; {"keepalive-options":
-- ["suppress-republish"]} keeps it awake without one. dbus-flashmq publishes
-- N/<portal ID>/system/0/Serial retained.

local scenario = arg[1]

dofile("drivers/tests/lua_harness/host_mock.lua")
host.reset()
host._millis_step = 0     -- the test moves the clock itself

-- FTW's host.mqtt_publish returns nothing when it sends and an error text
-- when it refuses (go/internal/drivers/lua.go). The mock returns true, so
-- replace it with FTW's behaviour here.
local refuse = nil
local published = {}
function host.mqtt_publish(topic, payload)
    if refuse then return refuse end
    published[#published + 1] = { topic = topic, payload = payload, at = host._millis_counter }
end

dofile("drivers/lua/victron_mqtt.lua")
driver_init({})

local SUPPRESS = '{"keepalive-options": ["suppress-republish"]}'

local function msg(topic, value)
    local payload
    if value == nil then
        payload = '{"value": null}'
    elseif type(value) == "string" then
        payload = '{"value": "' .. value .. '"}'
    else
        payload = '{"value": ' .. tostring(value) .. '}'
    end
    return { topic = "N/c0ffee/" .. topic, payload = payload }
end

local function serial() return msg("system/0/Serial", "c0ffee") end
local function completed() return msg("full_publish_completed", 1763800000) end
local function battery_power(w) return msg("system/0/Dc/Battery/Power", w or 500) end

local function poll(messages, advance_ms)
    host._millis_counter = host._millis_counter + (advance_ms or 1000)
    host._emitted = {}
    host._metrics = {}
    host._mqtt_buffer = messages or {}
    local ok, err = pcall(driver_poll)
    if not ok then error(scenario .. ": driver_poll failed: " .. tostring(err)) end
    return host._emitted.battery and host._emitted.battery[#host._emitted.battery]
end

local function fail(text) error(scenario .. ": " .. text) end

local function expect_published(count)
    if #published ~= count then
        local seen = {}
        for _, p in ipairs(published) do
            seen[#seen + 1] = string.format("%d ms %s %q", p.at, p.topic, p.payload)
        end
        fail(string.format("%d keep-alives, want %d: %s", #published, count,
            table.concat(seen, "; ")))
    end
end

local function expect_keepalive(i, payload, at)
    local p = published[i]
    if not p then fail("no keep-alive " .. i) end
    if p.topic ~= "R/c0ffee/keepalive" then fail("keep-alive " .. i .. " on " .. p.topic) end
    if p.payload ~= payload then
        fail(string.format("keep-alive %d payload %q, want %q", i, p.payload, payload))
    end
    if at and p.at ~= at then fail(string.format("keep-alive %d at %d ms, want %d", i, p.at, at)) end
end

local function count_logs(text)
    local n = 0
    for _, line in ipairs(host._logs) do
        if string.find(line, text, 1, true) then n = n + 1 end
    end
    return n
end

if scenario == "subscribes" then
    -- The portal ID and the end of a full republish are listened for.
    local want = { ["N/+/system/0/Serial"] = false, ["N/+/full_publish_completed"] = false }
    for _, call in ipairs(host._calls) do
        if call.func == "mqtt_subscribe" and want[call.args[1]] ~= nil then
            want[call.args[1]] = true
        end
    end
    for topic, seen in pairs(want) do
        if not seen then fail("no subscription to " .. topic) end
    end

elseif scenario == "no_portal_no_keepalive" then
    -- Nothing has named a portal ID yet: nothing to send to.
    for _ = 1, 40 do poll({}) end
    expect_published(0)

elseif scenario == "first_keepalive_full" then
    -- The retained Serial names the portal; the first keep-alive asks for
    -- every value.
    poll({ serial() })
    expect_published(1)
    expect_keepalive(1, "", 1000)

elseif scenario == "portal_from_any_topic" then
    poll({ battery_power() })
    expect_published(1)
    expect_keepalive(1, "")

elseif scenario == "interval" then
    -- Every 30 s, also on polls with no messages, since a sleeping GX sends
    -- none. A full republish every 120 s, suppress-republish in between.
    poll({ serial() })                      -- t = 1 s
    for _ = 1, 125 do poll({}) end          -- t = 2 .. 126 s
    expect_published(5)
    expect_keepalive(1, "", 1000)
    expect_keepalive(2, SUPPRESS, 31000)
    expect_keepalive(3, SUPPRESS, 61000)
    expect_keepalive(4, SUPPRESS, 91000)
    expect_keepalive(5, "", 121000)

elseif scenario == "silent_link_asks_again" then
    -- After 60 s with no messages at all, cached values are forgotten. The
    -- first poll that hears the GX again asks for every value at once,
    -- without waiting for the 30 s timer.
    poll({ serial(), battery_power() })     -- t = 1 s: full
    for _ = 1, 69 do poll({}) end           -- t = 2 .. 70 s: 31 s, 61 s
    poll({ battery_power() })               -- t = 71 s
    expect_published(4)
    expect_keepalive(1, "", 1000)
    expect_keepalive(2, SUPPRESS, 31000)
    expect_keepalive(3, SUPPRESS, 61000)
    expect_keepalive(4, "", 71000)

elseif scenario == "refused" then
    -- FTW refuses mqtt.publish for a driver it runs read-only. The driver
    -- warns once, keeps reading, and tries again on the next keep-alive.
    refuse = "mqtt.publish: read-only driver cannot write"
    local b = poll({ serial(), battery_power(700), msg("system/0/Dc/Battery/Soc", 55) })
    if not b or b.W ~= 700 then fail("no battery reading while the keep-alive is refused") end
    if count_logs("refused the keep-alive") ~= 1 then fail("refusal not logged once") end
    local calls = 0
    local real = host.mqtt_publish
    host.mqtt_publish = function(...) calls = calls + 1; return real(...) end
    for _ = 1, 29 do poll({ battery_power(700) }) end   -- t = 2 .. 30 s
    if calls ~= 0 then fail("retried within 30 s: " .. calls) end
    poll({ battery_power(700) })                       -- t = 31 s
    if calls ~= 1 then fail("did not retry after 30 s") end
    if count_logs("refused the keep-alive") ~= 1 then fail("refusal logged again") end
    -- The host allows it again.
    refuse = nil
    for _ = 1, 30 do poll({ battery_power(700) }) end  -- t = 61 s
    expect_published(1)
    expect_keepalive(1, "")
    if count_logs("sends the keep-alive again") ~= 1 then fail("recovery not logged") end

elseif scenario == "refused_keeps_values" then
    -- With no full republish ever completed there is no proof a value is
    -- gone, so the SoC stays as before.
    refuse = "mqtt.publish: read-only driver cannot write"
    poll({ serial(), battery_power(), msg("system/0/Dc/Battery/Soc", 55),
           msg("system/0/Dc/Battery/Temperature", 18) })
    local b
    for _ = 1, 30 do b = poll({ battery_power() }, 10000) end   -- 300 s
    if not b or b.SoC_nom_fract ~= 0.55 then fail("SoC dropped without a republish") end
    if b.temperature_C ~= 18 then fail("temperature dropped without a republish") end

elseif scenario == "republish_drops_gone_value" then
    -- The battery monitor left while the driver was not listening, so its
    -- empty payload never came. The next full republish does not resend
    -- its SoC or temperature: they are left out from then on.
    poll({ serial(), battery_power(), msg("system/0/Dc/Battery/Soc", 64),
           msg("system/0/Dc/Battery/Voltage", 52.1),
           msg("system/0/Dc/Battery/Temperature", 17.5), completed() })
    -- Battery power keeps arriving, so the link is not silent.
    local b
    for _ = 1, 11 do b = poll({ battery_power() }, 10000) end   -- t = 111 s
    if b.SoC_nom_fract ~= 0.64 then fail("SoC missing before the republish") end
    b = poll({ battery_power(), msg("system/0/Dc/Battery/Voltage", 52.2), completed() }, 10000)
    if b.SoC_nom_fract ~= nil then fail("kept SoC the republish left out") end
    if b.temperature_C ~= nil then fail("kept temperature the republish left out") end
    if b.V ~= 52.2 then fail("dropped the voltage the republish resent") end
    if host._metrics.battery_temp_c then fail("kept the temperature metric") end
    -- It comes back with the next message for it.
    b = poll({ battery_power(), msg("system/0/Dc/Battery/Soc", 63) })
    if b.SoC_nom_fract ~= 0.63 then fail("SoC did not come back") end

elseif scenario == "republish_keeps_resent_value" then
    -- A full pack's 100 % SoC never changes, but every full republish
    -- resends it, so it stays for as long as the GX has it, also when the
    -- republish spans more than one poll.
    poll({ serial(), battery_power(), msg("system/0/Dc/Battery/Soc", 100),
           msg("system/0/Dc/Battery/Temperature", 21), completed() })
    local b
    for _ = 1, 5 do
        for _ = 1, 11 do b = poll({ battery_power() }, 10000) end
        poll({ msg("system/0/Dc/Battery/Soc", 100), msg("system/0/Dc/Battery/Temperature", 21) }, 10000)
        b = poll({ battery_power(), completed() }, 1000)
        if b.SoC_nom_fract ~= 1 then fail("dropped a SoC the republish resent") end
        if b.temperature_C ~= 21 then fail("dropped a temperature the republish resent") end
    end

elseif scenario == "idle_poll_emits_nothing" then
    -- A keep-alive is not telemetry.
    poll({ serial(), battery_power() })
    for _ = 1, 40 do
        poll({})
        if next(host._emitted) then fail("an idle poll emitted telemetry") end
    end

else
    error("unknown scenario: " .. tostring(scenario))
end

driver_cleanup()
