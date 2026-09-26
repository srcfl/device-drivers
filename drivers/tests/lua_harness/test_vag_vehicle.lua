-- Telemetry-only VAG / EU Data Act vehicle driver.
-- Args: stored.zip deflated.zip

dofile("drivers/tests/lua_harness/host_mock.lua")

local stored_path, deflated_path = arg[1], arg[2]
assert(stored_path and deflated_path, "usage: test_vag_vehicle.lua stored.zip deflated.zip")

local function read_bin(path)
    local f = assert(io.open(path, "rb"))
    local data = f:read("*a")
    f:close()
    return data
end

local stored_zip = read_bin(stored_path)
local deflated_zip = read_bin(deflated_path)
assert(#stored_zip > 0 and #deflated_zip > 0, "empty zip fixture")

local VIN = "WVWZZZTESTVIN0001"
local REQ = "req-continuous-1"
local FILE = "2026-09-26T07-00-00_partial.zip"
local META = "/datarequest/vehicles/" .. VIN .. "/metadata/partial"
local LIST = "/datadelivery/vehicles/" .. VIN .. "/" .. REQ .. "/list"
local DL = "/datadelivery/vehicles/" .. VIN .. "/" .. REQ .. "/download"

local orig_http_get = host.http_get
function host.http_get(url, headers)
    if host._http_errors then
        for pattern, err in pairs(host._http_errors) do
            if string.find(url, pattern, 1, true) then
                return nil, err
            end
        end
    end
    if host._download_only and string.find(url, DL, 1, true) then
        local fn = headers and headers.filename
        if fn ~= host._download_only then
            return nil, "HTTP 404: wrong file " .. tostring(fn)
        end
    end
    return orig_http_get(url, headers)
end

local function boot(cfg)
    host.reset()
    host._http_errors = {}
    host._download_only = nil
    dofile("drivers/lua/vag_vehicle.lua")
    driver_init(cfg or {
        vin = VIN,
        brand = "volkswagen",
        cookie = "SESSION=test; Path=/",
    })
end

local function prime(zip_body, file_name)
    host._http_responses[META] = host.json_encode({ Identifier = REQ })
    host._http_responses[LIST] = host.json_encode({
        { name = file_name or FILE, createdOn = "2026-09-26T07:00:00Z" },
    })
    host._http_responses[DL] = zip_body
end

boot({ brand = "porsche", vin = VIN, cookie = "x=1" })
assert(host._make == nil, "Porsche must not bind identity")
driver_poll()
assert(not host._emitted.vehicle, "Porsche must not emit")

boot({ brand = "audi", vin = VIN })
assert(host._make == "Audi" and host._sn == VIN, "identity binds before cookie")
driver_poll()
assert(not host._emitted.vehicle, "missing cookie must not emit")

boot()
assert(host._make == "Volkswagen", "set_make from brand")
assert(host._sn == VIN, "set_sn from VIN")

prime(stored_zip)
driver_poll()
local rows = host._emitted.vehicle
assert(rows and #rows == 1, "stored zip should emit once")
local first = rows[1]
assert(first.soc == 63, "soc from battery_level_HV.value, got " .. tostring(first.soc))
assert(first.charge_limit_pct == 80, "target soc")
assert(first.charging_state == "Charging", "charging_state mapped")
assert(first.time_to_full_min == 42, "remaining_charging_time")
assert(first.stale == false, "fresh dataset is not stale")
assert(first.soc_fresh == true, "new file is a fresh observation")

local before = #rows
driver_poll()
assert(#host._emitted.vehicle == before + 1, "same file still reports last reading")
local replay = host._emitted.vehicle[#host._emitted.vehicle]
assert(replay.soc == 63, "replay keeps soc")
assert(replay.soc_fresh == false, "same zip is not a new observation")

boot()
prime(deflated_zip)
driver_poll()
rows = host._emitted.vehicle
assert(rows and #rows == 1, "deflated zip should emit")
assert(rows[1].soc == 63, "deflate extract soc")
assert(rows[1].charging_state == "Charging", "deflate extract state")

boot()
host._http_errors[META] = "HTTP 401: unauthorized"
driver_poll()
assert(not host._emitted.vehicle, "401 before first reading emits nothing")

boot()
prime(stored_zip)
driver_poll()
assert(#host._emitted.vehicle == 1, "seed reading")
host._http_errors[LIST] = "HTTP 403: forbidden"
driver_poll()
assert(#host._emitted.vehicle == 2, "expired session may replay last")
assert(host._emitted.vehicle[2].soc_fresh == false, "401/403 replay is cached")

boot()
prime(stored_zip)
driver_poll()
host._millis_counter = host._millis_counter + 2700001
host._http_errors[LIST] = "HTTP 404: no files"
driver_poll()
assert(#host._emitted.vehicle == 1, "stale last reading must stop emitting")

boot()
host._http_responses[META] = host.json_encode({ Identifier = REQ })
host._http_responses[LIST] = host.json_encode({
    { name = "2026-09-26T06-00-00_no_content_found.zip", createdOn = "2026-09-26T06:00:00Z" },
})
driver_poll()
assert(not host._emitted.vehicle, "asleep placeholder must not invent SoC")

boot()
prime(stored_zip)
-- Older file last: a naive "last array element" pick would request it and fail.
host._download_only = FILE
host._http_responses[LIST] = host.json_encode({
    { name = FILE, createdOn = "2026-09-26T07:00:00Z" },
    { name = "2026-09-26T06-00-00_partial.zip", createdOn = "2026-09-26T06:00:00Z" },
})
driver_poll()
assert(host._emitted.vehicle and host._emitted.vehicle[1].soc == 63,
    "newest createdOn wins even when it is not last")

print("vag_vehicle: ok")
