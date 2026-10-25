-- myuplink: one slow request must not leave a 60 s gap, and a rotated
-- refresh_token must reach the host's store even when the first write fails.
--
-- Usage: lua55 drivers/tests/lua_harness/test_myuplink_poll_timing.lua

local script_dir = arg[0]:match("(.*/)") or "./"
dofile(script_dir .. "host_mock.lua")

local ROOT = script_dir .. "../../../"
local failed = 0

local function fail(msg)
    failed = failed + 1
    io.stderr:write("FAIL " .. msg .. "\n")
end

local function expect(cond, msg)
    if not cond then fail(msg) end
end

local TOKEN_URL  = "https://api.myuplink.com/oauth/token"
local POINTS_URL = "https://api.myuplink.com/v2/devices/DEV1/points"
local POINTS = [[
[
  {"parameterId": 10012, "value": 1.5, "parameterUnit": "kW", "parameterName": "Compressor"},
  {"parameterId": 40004, "value": 5, "parameterUnit": "°C", "parameterName": "Outdoor"}
]
]]
local BUSY = "database is locked (5) (SQLITE_BUSY)"
local TIMEOUT = "context deadline exceeded (Client.Timeout exceeded while awaiting headers)"

-- A fake myUplink. `points_fail` makes the next reads fail; each refresh
-- issues a new refresh_token, as myUplink does.
local fake

local function start(opts)
    if driver_cleanup then driver_cleanup() end
    host.reset()
    fake = {
        points_fail = 0,
        token_fail = 0,
        refreshes = 0,
        persist_fail = 0,
        persisted = {},
        expires_in = 3600,
    }
    function host.http_get(url, headers)
        assert(url == POINTS_URL, "unexpected GET " .. tostring(url))
        if fake.points_fail > 0 then
            fake.points_fail = fake.points_fail - 1
            return nil, "Get \"" .. url .. "\": " .. TIMEOUT
        end
        return POINTS
    end
    function host.http_post(url, body, headers)
        assert(url == TOKEN_URL, "unexpected POST " .. tostring(url))
        if fake.token_fail > 0 then
            fake.token_fail = fake.token_fail - 1
            return nil, "Post \"" .. url .. "\": " .. TIMEOUT
        end
        fake.refreshes = fake.refreshes + 1
        return host.json_encode({
            access_token = "access-" .. fake.refreshes,
            expires_in = fake.expires_in,
            refresh_token = "rotated-" .. fake.refreshes,
        })
    end
    function host.persist_secret(key, value)
        assert(key == "refresh_token", "unexpected secret " .. tostring(key))
        if fake.persist_fail > 0 then
            fake.persist_fail = fake.persist_fail - 1
            return false, BUSY
        end
        table.insert(fake.persisted, value)
        return true
    end
    for k, v in pairs(opts or {}) do fake[k] = v end
    dofile(ROOT .. "drivers/lua/myuplink.lua")
    driver_init({
        client_id = "id",
        client_secret = "secret",
        refresh_token = "refresh-0",
        device_id = "DEV1",
        setup_retry_ms = 0,
    })
end

local function count_logs(text)
    local n = 0
    for _, line in ipairs(host._logs) do
        if line:find(text, 1, true) then n = n + 1 end
    end
    return n
end

local function poll()
    local ok, wait = pcall(driver_poll)
    if not ok then
        fail("driver_poll threw: " .. tostring(wait))
        return nil
    end
    return wait
end

---------------------------------------------------------------------------
-- A good poll waits 30 s: Core's ceiling, half its 60 s watchdog window.
---------------------------------------------------------------------------

start()
local wait = poll()
expect(wait == 30000, "good poll waits 30000 ms, got " .. tostring(wait))
expect(host._metrics["hp_power_w"] ~= nil, "good poll emits hp_power_w")

---------------------------------------------------------------------------
-- One failed read is retried after 2 s; a second failure in a row waits the
-- full poll; a good read resets it, so the next outage gets one quick retry.
---------------------------------------------------------------------------

start()
expect(poll() == 30000, "first poll is good")
host._metrics = {}
fake.points_fail = 2
wait = poll()
expect(wait == 2000, "first failure retries after 2000 ms, got " .. tostring(wait))
expect(host._metrics["hp_power_w"] == nil, "a failed read emits nothing")
wait = poll()
expect(wait == 30000, "second failure in a row waits 30000 ms, got " .. tostring(wait))
wait = poll()
expect(wait == 30000, "recovery waits 30000 ms, got " .. tostring(wait))
expect(host._metrics["hp_power_w"] ~= nil, "recovery emits again")
fake.points_fail = 1
wait = poll()
expect(wait == 2000, "a new outage gets a quick retry again, got " .. tostring(wait))
expect(count_logs("next try in 2 s") == 2, "each quick retry is logged")
expect(count_logs("next try in 30 s") == 1, "the slow retry is logged")

---------------------------------------------------------------------------
-- A failed token refresh follows the same rule and emits nothing.
---------------------------------------------------------------------------

start({ token_fail = 2 })
host._metrics = {}
wait = poll()
expect(wait == 2000, "failed sign-in retries after 2000 ms, got " .. tostring(wait))
expect(host._metrics["hp_power_w"] == nil, "failed sign-in emits nothing")
wait = poll()
expect(wait == 30000, "second failed sign-in waits 30000 ms, got " .. tostring(wait))
wait = poll()
expect(wait == 30000 and host._metrics["hp_power_w"] ~= nil, "sign-in recovers")

---------------------------------------------------------------------------
-- The watchdog: Core marks the driver offline after 60 s without a reading.
-- Model the run loop: the next poll starts `wait` after the last one ended,
-- held within the 1–30 s Core allows a returned wait. A read takes 0.3 s, or
-- 15 s when it times out.
---------------------------------------------------------------------------

local function longest_gap(outcomes)
    start()
    local t, last_emit, gap = 0, nil, 0
    for _, outcome in ipairs(outcomes) do
        host._metrics = {}
        if outcome == "timeout" then fake.points_fail = 1 end
        local w = math.min(math.max(poll() or 30000, 1000), 30000)
        t = t + (outcome == "timeout" and 15 or 0.3)
        if host._metrics["hp_power_w"] then
            if last_emit then gap = math.max(gap, t - last_emit) end
            last_emit = t
        end
        t = t + w / 1000
    end
    return gap
end

local gap = longest_gap({ "ok", "timeout", "ok", "ok" })
expect(gap < 60, "one timed-out read keeps the gap under 60 s, got " .. gap)
gap = longest_gap({ "ok", "timeout", "timeout", "ok" })
expect(gap > 60, "two timed-out reads in a row still show as offline, got " .. gap)

---------------------------------------------------------------------------
-- A rotated refresh_token that the host could not store is stored on a
-- later poll. Reading carries on meanwhile; the warning appears once.
---------------------------------------------------------------------------

start({ persist_fail = 3 })
-- device_id is configured, so the first sign-in happens on the first poll.
expect(poll() == 30000, "poll works when the first store fails")
expect(host._metrics["hp_power_w"] ~= nil, "readings flow while the token is unsaved")
expect(#fake.persisted == 0, "first store failed")
expect(count_logs("could not persist rotated refresh_token") == 1, "first failure warns")
expect(poll() == 30000, "poll works while the token is unsaved")
expect(poll() == 30000, "poll works while the token is unsaved")
expect(#fake.persisted == 0, "store still failing after two retries")
expect(count_logs("could not persist rotated refresh_token") == 1, "warns once, not on every poll")
poll()
expect(#fake.persisted == 1 and fake.persisted[1] == "rotated-1",
    "the rotated token is stored once the host accepts it")
expect(count_logs("persisted after 3 failed attempt(s)") == 1, "recovery is logged")
poll()
expect(#fake.persisted == 1, "a stored token is not written again")

-- The next rotation is stored in the same poll and replaces the old one.
start({ expires_in = 0 })
poll()
expect(fake.persisted[#fake.persisted] == "rotated-" .. fake.refreshes,
    "each rotation is stored: " .. tostring(fake.persisted[#fake.persisted]))

-- Rotations while the host keeps refusing: once it accepts, the newest token
-- is stored, never an older one, and never an older one after a newer one.
start({ expires_in = 0, persist_fail = 100 })
poll(); poll(); poll()
expect(fake.refreshes == 3, "three polls, three rotations, got " .. fake.refreshes)
expect(#fake.persisted == 0, "nothing stored while the host refuses")
fake.persist_fail = 0
poll()
local newest = 0
for _, v in ipairs(fake.persisted) do
    local n = tonumber(v:match("^rotated%-(%d+)$")) or -1
    expect(n >= newest, "older token " .. v .. " stored after a newer one")
    newest = math.max(newest, n)
end
expect(fake.persisted[#fake.persisted] == "rotated-" .. fake.refreshes,
    "the last stored token is the latest, got " .. tostring(fake.persisted[#fake.persisted]))

---------------------------------------------------------------------------
-- A store comes after the reading. Once Core waits out a busy database, one
-- store can take 5 s; it must not hold back the reading of that poll.
---------------------------------------------------------------------------

start({ expires_in = 0 })
local emitted_before_store = nil
function host.persist_secret(key, value)
    if emitted_before_store == nil then
        emitted_before_store = host._metrics["hp_power_w"] ~= nil
    end
    return true
end
host._metrics = {}
poll()
expect(emitted_before_store == true, "the reading is emitted before the rotated token is stored")

start({ expires_in = 0, persist_fail = 1 })
host._metrics = {}
fake.points_fail = 1
poll()
expect(#fake.persisted == 0 and fake.persist_fail == 0,
    "a poll whose read failed still tries the store")
poll()
expect(#fake.persisted >= 1, "and stores on the next poll")

-- The same run loop as above, with a clock: every store blocks 5 s and
-- fails, and every poll signs in again. One timed-out read must still keep
-- the gap between readings under the 60 s watchdog.
local function gap_with_slow_store(outcomes)
    start({ expires_in = 0 })
    local now = 0
    function host.millis() return now end
    function host.persist_secret() now = now + 5000; return false, BUSY end
    local get = host.http_get
    local post = host.http_post
    local timeout_next = false
    function host.http_get(url, headers)
        if timeout_next then now = now + 15000; timeout_next = false; return nil, TIMEOUT end
        now = now + 300
        return get(url, headers)
    end
    function host.http_post(url, body, headers)
        now = now + 300
        return post(url, body, headers)
    end
    local last_emit, longest = nil, 0
    for _, outcome in ipairs(outcomes) do
        host._metrics = {}
        timeout_next = outcome == "timeout"
        local w = math.min(math.max(poll() or 30000, 1000), 30000)
        local emit_at = host._metrics["hp_power_w"] and host._metrics["hp_power_w"].at
        if emit_at then
            if last_emit then longest = math.max(longest, emit_at - last_emit) end
            last_emit = emit_at
        end
        now = now + w
    end
    return longest / 1000
end
local mock_emit_metric, mock_millis = host.emit_metric, host.millis
function host.emit_metric(name, value, unit)
    mock_emit_metric(name, value, unit)
    host._metrics[name].at = host.millis()
end
local slow_gap = gap_with_slow_store({ "ok", "ok", "timeout", "ok", "ok" })
expect(slow_gap < 60, "a 5 s store and one timed-out read stay under 60 s, got " .. slow_gap)
host.emit_metric, host.millis = mock_emit_metric, mock_millis

---------------------------------------------------------------------------
-- driver_cleanup never stores: a reconnect may just have stored a fresh
-- token, and this older one must not replace it.
---------------------------------------------------------------------------

start({ persist_fail = 1 })
poll()
local stored_before = #fake.persisted
expect(stored_before == 0, "token unsaved before cleanup")
driver_cleanup()
expect(#fake.persisted == stored_before, "cleanup does not store the unsaved token")

if failed > 0 then
    io.stderr:write(failed .. " checks failed\n")
    os.exit(1)
end
print("PASS")
