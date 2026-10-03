-- VAG / EU Data Act driver: email sign-in through host.http_request, session
-- renewal, back-off, and reading age from the portal's Date header.
-- Args: deflated.zip (SoC point measured 2026-09-26T07:00:00Z)

dofile("drivers/tests/lua_harness/host_mock.lua")

local zip_path = arg[1]
assert(zip_path, "usage: test_vag_vehicle_login.lua deflated.zip")
local f = assert(io.open(zip_path, "rb"))
local dataset_zip = f:read("*a")
f:close()

local VIN = "WVWZZZTESTVIN0001"
local REQ = "req-continuous-1"
local FILE = "2026-09-26T07-00-00_partial.zip"
local NEXT = "2026-09-26T07-15-00_partial.zip"
local CID = "9b58543e-1c15-4193-91d5-8a14145bebb0@apps_vw-dilab_com"
local ID = "https://identity.vwgroup.io"
local PORTAL = "https://eu-data-act.drivesomethinggreater.com"
local SIGNIN = ID .. "/signin-service/v1/" .. CID
local PASSWORD = "correct horse"

-- A fake VW sign-in and portal. `session` stands for the cookies the host
-- jar would hold; http_cookies_clear drops it.
local fake

local function reset_fake()
    fake = {
        session = false,
        password = PASSWORD,
        date = "Sat, 26 Sep 2026 07:05:00 GMT",
        files = { { name = FILE, createdOn = "2026-09-26T07:00:00Z" } },
        downloads = { [FILE] = dataset_zip },
        requests = {},
        posts = {},
        logins = 0,
        expire_next = false,
        off_host = false,
    }
end

local function resp(status, extra)
    local r = { status = status, headers = { date = fake.date }, body = "" }
    for k, v in pairs(extra or {}) do r[k] = v end
    return r
end

local function redirect(location)
    return resp(302, { location = location })
end

local LOGIN_PAGE = [[<html><body>
<form method="POST" id="emailPasswordForm" name="emailPasswordForm" action="/signin-service/v1/]] .. CID .. [[/login/identifier">
<input type="hidden" id="csrf" name="_csrf" value="c1"/>
<input type="hidden" name="relayState" value="r1"/>
<input type="hidden" name="hmac" value="h&amp;1"/>
<input type="email" name="email" value=""/>
</form></body></html>]]

local function password_page(err)
    return [[<html><script>
window._IDK = {
  templateModel: {"hmac":"h2","relayState":"r2","postAction":"login/authenticate","identifierUrl":"login/identifier","error":]]
        .. (err and ('"' .. err .. '"') or "null") .. [[},
  csrf_parameterName: '_csrf',
  csrf_token: 'c2',
  currentLocale: 'en'
};
</script></html>]]
end

local function has(body, pair)
    return body and string.find("&" .. body .. "&", "&" .. pair .. "&", 1, true) ~= nil
end

function host.http_cookies_clear()
    fake.session = false
end

function host.http_request(opts)
    local method = opts.method or "GET"
    local url = opts.url
    table.insert(fake.requests, method .. " " .. url)
    if method == "POST" then table.insert(fake.posts, opts.body or "") end
    local path = url:match("^https://[^/]+([^?]*)") or ""

    if url:find(ID .. "/oidc/v1/authorize?", 1, true) == 1 then
        assert(url:find("client_id=" .. CID:gsub("@", "%%40"), 1, true), "brand client id")
        assert(url:find("redirect_uri=https%3A%2F%2Feu-data-act", 1, true), "portal redirect uri")
        return redirect(SIGNIN .. "/login?relayState=r0")
    end
    if url == SIGNIN .. "/login?relayState=r0" then
        return resp(200, { body = LOGIN_PAGE })
    end
    if method == "POST" and url == SIGNIN .. "/login/identifier" then
        assert(has(opts.body, "_csrf=c1") and has(opts.body, "relayState=r1"), "identifier form state")
        assert(has(opts.body, "hmac=h%261"), "entities decoded, then encoded: " .. opts.body)
        assert(has(opts.body, "email=owner%40example.com"), "email")
        assert(not opts.body:find("password", 1, true), "no password at the identifier step")
        return resp(303, { location = SIGNIN .. "/login/authenticate?relayState=r1" })
    end
    if method == "GET" and url == SIGNIN .. "/login/authenticate?relayState=r1" then
        return resp(200, { body = password_page(nil) })
    end
    if method == "POST" and url == SIGNIN .. "/login/authenticate" then
        assert(has(opts.body, "_csrf=c2") and has(opts.body, "hmac=h2") and has(opts.body, "relayState=r2"),
            "password form state from window._IDK")
        if not has(opts.body, "password=correct%20horse") or fake.password ~= PASSWORD then
            return resp(200, { body = password_page("login.errors.password_invalid") })
        end
        if fake.off_host then
            return redirect("https://evil.example/steal")
        end
        return redirect(ID .. "/oidc/v1/oauth/sso?x=1")
    end
    if url == ID .. "/oidc/v1/oauth/sso?x=1" then
        return redirect(ID .. "/consent/marketing/abc?callback="
            .. "https%3A%2F%2Fidentity.vwgroup.io%2Foidc%2Fv1%2Foauth%2Fclient%2Fcallback%3Fscope%3Dopenid+cars")
    end
    if url == ID .. "/oidc/v1/oauth/client/callback?scope=openid%20cars" then
        return redirect(PORTAL .. "/login?code=xyz")
    end
    if url == PORTAL .. "/login?code=xyz" then
        fake.session = true
        fake.logins = fake.logins + 1
        return redirect(PORTAL .. "/content/euda/en/user.html")
    end

    if url:find(PORTAL .. "/proxy_api/", 1, true) == 1 then
        assert(method == "GET", "portal reads are GETs")
        assert(not (opts.headers or {}).Cookie, "sign-in mode leaves cookies to the host jar")
        if fake.expire_next then
            fake.expire_next = false
            fake.session = false
        end
        if not fake.session then return resp(401, { body = "unauthorized" }) end
        if path:find("/metadata/partial", 1, true) then
            return resp(200, { body = host.json_encode({ Identifier = REQ }) })
        end
        if path:find("/list", 1, true) then
            return resp(200, { body = host.json_encode(fake.files) })
        end
        if path:find("/download", 1, true) then
            local body = fake.downloads[opts.headers.filename]
            if not body then return resp(404) end
            return resp(200, { body = body })
        end
    end
    error("unexpected request " .. method .. " " .. url)
end

local function rows()
    return host._emitted.vehicle or {}
end

local function last_row()
    local r = rows()
    return r[#r]
end

local function count(prefix)
    local n = 0
    for _, r in ipairs(fake.requests) do
        if r:find(prefix, 1, true) == 1 then n = n + 1 end
    end
    return n
end

local function logged(needle)
    for _, line in ipairs(host._logs) do
        if string.find(line, needle, 1, true) then return true end
    end
    return false
end

local function boot(cfg)
    host.reset()
    reset_fake()
    dofile("drivers/lua/vag_vehicle.lua")
    driver_init(cfg or {
        vin = VIN, brand = "volkswagen",
        email = "owner@example.com", password = PASSWORD,
    })
end

-- Sign in, then read. The first file after start is fresh when the car
-- measured it 5 minutes ago, and the age comes from VW's clocks.
boot()
local interval = driver_poll()
assert(fake.logins == 1, "signed in once")
assert(logged("signed in"), "sign-in is logged")
assert(#rows() == 1, "first poll emits")
assert(last_row().soc == 63, "soc read after sign-in")
assert(last_row().soc_fresh == true, "a 5-minute-old reading is fresh")
assert(last_row().stale == false, "and not stale")
local age = host._metrics.vehicle_soc_age_s
assert(age and math.abs(age.value - 300) < 2, "age from Date header, got " .. tostring(age and age.value))
assert(interval == 300000, "normal poll interval")
assert(count("POST " .. SIGNIN .. "/login/identifier") == 1 and count("POST " .. SIGNIN .. "/login/authenticate") == 1,
    "two form posts")
assert(count("GET " .. PORTAL .. "/content/euda/") == 0, "landing page is not fetched")

-- The replay of the same file keeps counting its age.
host._millis_counter = host._millis_counter + 60000
driver_poll()
assert(last_row().soc_fresh == false, "replay is not fresh")
assert(host._metrics.vehicle_soc_age_s.value > 359, "replay age grows")

-- The session ends after about an hour: the driver signs in again.
fake.expire_next = true
fake.files[2] = { name = NEXT, createdOn = "2026-09-26T07:15:00Z" }
fake.downloads[NEXT] = dataset_zip
fake.date = "Sat, 26 Sep 2026 07:20:00 GMT"
interval = driver_poll()
assert(interval == 1000, "an ended session retries promptly, got " .. tostring(interval))
assert(logged("session ended"), "session end is logged")
driver_poll()
assert(fake.logins == 2, "signed in again")
-- The car measured this file at 07:00, now 07:20: 20 minutes, at the limit.
assert(last_row().soc == 63, "reading after renewal")

-- A new file whose SoC point is two hours old is not a fresh reading.
boot()
fake.date = "Sat, 26 Sep 2026 09:00:00 GMT"
driver_poll()
assert(last_row().soc_fresh == false, "a two-hour-old reading is not fresh")
assert(last_row().stale == true, "and is stale")
assert(host._metrics.vehicle_soc_age_s.value >= 7200, "old age reported")

-- A wrong password waits 15 minutes before the next try.
boot()
fake.password = "changed"
driver_poll()
assert(#rows() == 0, "no reading without a session")
assert(logged("sign-in failed, next try in 15 min"), "failure is logged")
assert(logged("login.errors.password_invalid"), "VW's reason is logged")
host._millis_counter = host._millis_counter + 300000
driver_poll()
assert(count("POST " .. SIGNIN .. "/login/authenticate") == 1, "no retry inside the back-off")
fake.password = PASSWORD
host._millis_counter = host._millis_counter + 900000
driver_poll()
assert(fake.logins == 1 and #rows() == 1, "retries after the back-off and reads")

-- A redirect off the VW hosts ends the sign-in.
boot()
fake.off_host = true
driver_poll()
assert(fake.logins == 0 and #rows() == 0, "off-host redirect is refused")
assert(count("GET https://evil.example") == 0, "the off-host URL is never requested")

-- The password never reaches a log line.
for _, line in ipairs(host._logs) do
    assert(not line:find(PASSWORD, 1, true) and not line:find("correct%20horse", 1, true),
        "password logged: " .. line)
end

-- Without host.http_request (an older FTW) a pasted cookie still works, and
-- email/password alone explains what is missing.
local saved_request, saved_clear = host.http_request, host.http_cookies_clear
host.http_request, host.http_cookies_clear = nil, nil
boot()
assert(logged("cannot sign in with email and password"), "old host is explained")
driver_poll()
assert(#rows() == 0, "no reading without a way to sign in")
host.http_request, host.http_cookies_clear = saved_request, saved_clear

print("vag_vehicle login: ok")
