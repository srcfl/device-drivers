-- Telemetry-only VAG / EU Data Act vehicle driver.
-- Args: stored.zip deflated.zip streamed.zip oversized.zip nosoc.zip large.zip

dofile("drivers/tests/lua_harness/host_mock.lua")

-- FTW runs gopher-lua, whose table.concat puts every item of the range on a
-- value stack of about 5,000 slots. C Lua has no such limit, so refuse long
-- ranges here too, or a driver that needs them passes this test and fails
-- on a box with "registry overflow".
local c_concat = table.concat
table.concat = function(t, sep, i, j)
    i = i or 1
    j = j or #t
    assert(j - i < 2000, "table.concat over " .. (j - i + 1) .. " items overflows gopher-lua")
    return c_concat(t, sep, i, j)
end

local stored_path, deflated_path, streamed_path, oversized_path, nosoc_path, large_path =
    arg[1], arg[2], arg[3], arg[4], arg[5], arg[6]
assert(stored_path and deflated_path and streamed_path and oversized_path and nosoc_path and large_path,
    "usage: test_vag_vehicle.lua stored.zip deflated.zip streamed.zip oversized.zip nosoc.zip large.zip")

local function read_bin(path)
    local f = assert(io.open(path, "rb"))
    local data = f:read("*a")
    f:close()
    return data
end

local stored_zip = read_bin(stored_path)
local deflated_zip = read_bin(deflated_path)
local streamed_zip = read_bin(streamed_path)
local oversized_zip = read_bin(oversized_path)
local nosoc_zip = read_bin(nosoc_path)
local large_zip = read_bin(large_path)
assert(#stored_zip > 0 and #deflated_zip > 0 and #streamed_zip > 0, "empty zip fixture")

local VIN = "WVWZZZTESTVIN0001"
local REQ = "req-continuous-1"
local OLD = "2026-09-26T06-45-00_partial.zip"
local FILE = "2026-09-26T07-00-00_partial.zip"
local NEXT = "2026-09-26T07-15-00_partial.zip"
local META = "/datarequest/vehicles/" .. VIN .. "/metadata/partial"
local LIST = "/datadelivery/vehicles/" .. VIN .. "/" .. REQ .. "/list"
local DL = "/datadelivery/vehicles/" .. VIN .. "/" .. REQ .. "/download"
local POLL_MS = 300000

-- Downloads are served by the filename header, as the portal does.
local orig_http_get = host.http_get
function host.http_get(url, headers)
    if host._http_errors then
        for pattern, err in pairs(host._http_errors) do
            if string.find(url, pattern, 1, true) then
                return nil, err
            end
        end
    end
    if string.find(url, DL, 1, true) then
        local fn = headers and headers.filename
        table.insert(host._download_log, fn)
        local body = host._downloads[fn]
        if body == nil then
            return nil, "HTTP 404: no file " .. tostring(fn)
        end
        return body
    end
    return orig_http_get(url, headers)
end

local function boot(cfg)
    host.reset()
    host._http_errors = {}
    host._downloads = {}
    host._download_log = {}
    dofile("drivers/lua/vag_vehicle.lua")
    driver_init(cfg or {
        vin = VIN,
        brand = "volkswagen",
        cookie = "SESSION=test; Path=/",
    })
end

local function listing(files)
    host._http_responses[META] = host.json_encode({ Identifier = REQ })
    host._http_responses[LIST] = host.json_encode(files)
end

local function file(name, created)
    return { name = name, createdOn = created }
end

local function rows()
    return host._emitted.vehicle or {}
end

local function last_row()
    local r = rows()
    return r[#r]
end

local function last_poll_interval()
    local ms = nil
    for _, call in ipairs(host._calls) do
        if call.func == "set_poll_interval" then ms = call.args[1] end
    end
    return ms
end

local function logged(needle)
    for _, line in ipairs(host._logs) do
        if string.find(line, needle, 1, true) then return true end
    end
    return false
end

-- Porsche is not on this portal.
boot({ brand = "porsche", vin = VIN, cookie = "x=1" })
assert(host._make == nil, "Porsche must not bind identity")
driver_poll()
assert(#rows() == 0, "Porsche must not emit")

-- Identity binds without a cookie; nothing is emitted, and the poll
-- interval is still set (the host keeps the last one set).
boot({ brand = "audi", vin = VIN })
assert(host._make == "Audi" and host._sn == VIN, "identity binds before cookie")
driver_poll()
assert(#rows() == 0, "missing cookie must not emit")
assert(last_poll_interval() == POLL_MS, "missing cookie left the poll interval unset")

-- The newest file at the first listing may be hours old: it is reported,
-- but stale and not fresh. A file that appears after it is fresh.
boot()
assert(host._make == "Volkswagen", "set_make from brand")
assert(host._sn == VIN, "set_sn from VIN")
listing({ file(FILE, "2026-09-26T07:00:00Z") })
host._downloads[FILE] = stored_zip
driver_poll()
assert(#rows() == 1, "first file emits once")
local first = rows()[1]
assert(first.soc == 63, "soc from battery_level_HV.value, got " .. tostring(first.soc))
assert(first.soc_fresh == false, "first file after start is not a fresh observation")
assert(first.stale == true, "first file after start has unknown age")

driver_poll()
assert(#host._download_log == 1, "the same file is not downloaded again")
assert(#rows() == 2 and last_row().stale == true, "replay keeps the unknown age")

listing({ file(FILE, "2026-09-26T07:00:00Z"), file(NEXT, "2026-09-26T07:15:00Z") })
host._downloads[NEXT] = deflated_zip
driver_poll()
local fresh = last_row()
assert(fresh.soc == 63, "deflate extract soc")
assert(fresh.soc_fresh == true, "a file that appeared after start is fresh")
assert(fresh.stale == false, "fresh file is not stale")
assert(fresh.charge_limit_pct == 80, "target soc")
assert(fresh.charging_state == "Charging", "charging_state mapped")
assert(fresh.time_to_full_min == 42, "remaining_charging_time")

driver_poll()
assert(last_row().soc_fresh == false, "same file again is a replay")
assert(last_row().stale == false, "young replay is not stale")

host._millis_counter = host._millis_counter + 2700001
host._http_errors[LIST] = "HTTP 404: no files"
local before = #rows()
driver_poll()
assert(#rows() == before, "stale last reading must stop emitting")

-- A zip written by a streaming writer: sizes in a data descriptor.
boot()
listing({ file(FILE, "2026-09-26T07:00:00Z") })
host._downloads[FILE] = streamed_zip
driver_poll()
assert(last_row() and last_row().soc == 63, "streamed zip entry decodes")

-- A dataset over the size cap is refused, once.
boot()
listing({ file(FILE, "2026-09-26T07:00:00Z") })
host._downloads[FILE] = oversized_zip
driver_poll()
assert(#rows() == 0, "oversized dataset must not emit")
assert(logged("dataset too large"), "oversized dataset is logged")
driver_poll()
assert(#host._download_log == 1, "a refused file is not downloaded again")

-- A few hundred kB of data points: the unzip flushes chunks, and every join
-- stays short enough for gopher-lua.
boot()
listing({ file(OLD, "2026-09-26T06:45:00Z") })
host._downloads[OLD] = stored_zip
driver_poll()
listing({ file(OLD, "2026-09-26T06:45:00Z"), file(FILE, "2026-09-26T07:00:00Z") })
host._downloads[FILE] = large_zip
driver_poll()
assert(last_row().soc == 71, "large dataset decodes, got " .. tostring(last_row().soc))
assert(last_row().soc_fresh == true, "large dataset is a fresh reading")

-- A new file without SoC is read once and replays the last reading.
boot()
listing({ file(OLD, "2026-09-26T06:45:00Z") })
host._downloads[OLD] = stored_zip
driver_poll()
listing({ file(OLD, "2026-09-26T06:45:00Z"), file(FILE, "2026-09-26T07:00:00Z") })
host._downloads[FILE] = nosoc_zip
driver_poll()
assert(last_row().soc_fresh == false, "a file without SoC is not a fresh reading")
driver_poll()
assert(#host._download_log == 2, "a file without SoC is not downloaded again")

-- 401 before the first reading emits nothing.
boot()
host._http_errors[META] = "HTTP 401: unauthorized"
driver_poll()
assert(#rows() == 0, "401 before first reading emits nothing")

-- An expired session replays the last reading.
boot()
listing({ file(FILE, "2026-09-26T07:00:00Z") })
host._downloads[FILE] = stored_zip
driver_poll()
assert(#rows() == 1, "seed reading")
host._http_errors[LIST] = "HTTP 403: forbidden"
driver_poll()
assert(#rows() == 2, "expired session may replay last")
assert(rows()[2].soc_fresh == false, "401/403 replay is cached")

-- Asleep at start: no content file. The first content file after that is
-- a new observation.
boot()
listing({ file("2026-09-26T06-00-00_no_content_found.zip", "2026-09-26T06:00:00Z") })
driver_poll()
assert(#rows() == 0, "asleep placeholder must not invent SoC")
listing({
    file("2026-09-26T06-00-00_no_content_found.zip", "2026-09-26T06:00:00Z"),
    file(FILE, "2026-09-26T07:00:00Z"),
})
host._downloads[FILE] = stored_zip
driver_poll()
assert(last_row() and last_row().soc_fresh == true, "content after an asleep start is fresh")

-- Portal order is not a contract: the newest createdOn wins.
boot()
listing({
    file(FILE, "2026-09-26T07:00:00Z"),
    file("2026-09-26T06-00-00_partial.zip", "2026-09-26T06:00:00Z"),
})
host._downloads[FILE] = stored_zip
driver_poll()
assert(host._download_log[1] == FILE, "newest createdOn is downloaded")
assert(last_row() and last_row().soc == 63, "newest createdOn wins even when it is not last")

-- Several candidate fields: the newest point wins, as in evcc. Battery care
-- mode's threshold counts as the limit only while the mode is active.
boot()
listing({ file(OLD, "2026-09-26T06:45:00Z") })
host._downloads[OLD] = stored_zip
driver_poll()
listing({ file(OLD, "2026-09-26T06:45:00Z"), file(FILE, "2026-09-26T07:00:00Z") })
host._downloads[FILE] = host.json_encode({ vin = VIN, Data = {
    { key = "162c2a75-edf4-3990-b8ed-7c600b3dbc40", dataFieldName = "battery_level_HV.value", value = "50" },
    { key = "f89ed652-d104-3fa6-b7e2-ab7543309e7b", dataFieldName = "hv_soc", value = "55" },
    { key = "76acaa98-37ef-3466-b013-21c77ed343ae", dataFieldName = "settings.target_soc", value = "90" },
    { dataFieldName = "setting.bcam_activation", value = "BCAM_ACTIVATION_ACTIVATED" },
    { dataFieldName = "battery_care_mode.charge_bcam_threshold", value = "80" },
} })
driver_poll()
assert(last_row().soc == 55, "newest SoC point wins, got " .. tostring(last_row().soc))
assert(last_row().charge_limit_pct == 80, "active care mode threshold is the newest limit")
assert(last_row().soc_fresh == true, "new file is fresh")

print("vag_vehicle: ok")
