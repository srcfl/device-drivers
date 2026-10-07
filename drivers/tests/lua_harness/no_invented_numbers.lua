-- no_invented_numbers.lua -- "null, never 0": a driver must not invent numbers.
--
-- Usage: lua55 no_invented_numbers.lua <harness_dir> <driver_path>
-- Prints one JSON object (see `result` below) on stdout.
--
-- The rule: once the device stops answering, every measurement a driver
-- emits must be nil. A number the driver emits anyway can only come from
-- one of three inputs -- an earlier reading, the driver config, or the
-- clock -- or it is invented (0 W, 50 Hz, a hard-coded SoC ...).
--
-- How it is measured. The driver runs twice, A and B. The runs differ in
-- every input a driver can legitimately use:
--   * register values (every register answers FILL_A / FILL_B in phase 1),
--   * numeric config values (CONFIG_A / CONFIG_B),
--   * the clock (host.now_ms / host.millis start at different bases).
-- Each run: driver_init(config), one healthy poll (phase 1: reads answer),
-- then POLLS_FAILING polls where every read fails (phase 2: modbus_read,
-- http_get, writes raise; MQTT, serial and P1 deliver nothing), then
-- POLLS_FAILING polls where every Modbus reply is short (phase 3: half of
-- the requested registers, so a decode of a missing register is nil and a
-- `decode(...) or 0` default shows up as a number that did not change).
--
-- "Emitting a number" means: a finite Lua number anywhere inside a table
-- passed to host.emit(der_type, payload) during phase 2 or 3, including nested
-- tables and arrays (e.g. mppts[1].V). Strings, booleans, nil, NaN and
-- infinities are not numbers here. host.set_rated_w / set_make / set_sn
-- and logs are not emits and are not checked.
--
-- A phase-2 number at a payload path is
--   * INVENTED (a violation) when the same value appears at that path in
--     phase 2 (or 3) of both runs and the driver did not read it in phase 1:
--     it changed with none of the inputs, so it came from none of them;
--   * a STALE replay (phase 2 only; reported, not a violation) when it
--     equals what that path carried in phase 1 of the same run and that
--     phase-1 value differed between the runs: read once, now repeated;
--   * DERIVED otherwise (it differs between the runs: config, clock, or
--     the registers a short reply did deliver).
-- Allowed constants: the data model's default SoC window
-- (min_soc_fract 0.05, max_soc_fract 1.0, srcful-data-models 2.2.0), which
-- a battery reports when it cannot read its own.
--
-- A driver whose driver_init fails in this probe is NOT MEASURED (it would
-- not be polled by a host either); the result says so.

local harness_dir = arg[1]
local driver_path = arg[2]
if not harness_dir or not driver_path then
    io.stderr:write("usage: lua55 no_invented_numbers.lua <harness_dir> <driver_path>\n")
    os.exit(2)
end

dofile(harness_dir .. "/host_mock.lua")  -- global `host`: decoders, json, logging

local POLLS_FAILING = 3

local FILL_A, FILL_B = 37, 61            -- register value every read returns in phase 1
local CLOCK_A, CLOCK_B = 1767225600000, 1767312000000   -- now_ms bases (one day apart)
local MILLIS_A, MILLIS_B = 1000, 7777000                -- millis bases

local function config_for(run)
    local a = (run == "A")
    return {
        -- strings and connection parameters: the same in both runs
        sn = "PROBE-001", type = "lua", host = "127.0.0.1", port = 502,
        unit_id = 1, slave_id = 1, serial = "PROBE123", gateway_serial = "GW-PROBE",
        url = "http://127.0.0.1", topic = "probe", serial_port = "/dev/ttyUSB0",
        baud_rate = 9600, encryption_key = "00112233445566778899aabbccddeeff",
        auth_key = "00112233445566778899aabbccddeeff", ders = {},
        -- numeric config the registry drivers read: different per run
        battery_rated_w = a and 10000 or 7300,
        battery_capacity_wh = a and 13500 or 9100,
        battery_max_c_rate = a and 0.5 or 0.7,
        ffr_slew_rate_pct_per_s = a and 10 or 17,
        power_scale = a and 1 or 2,
        nominal_w = a and 10000 or 7300,
        rated_w = a and 10000 or 7300,
    }
end

---------------------------------------------------------------------------
-- Probe host: failure model, clock, and the functions host_mock lacks
---------------------------------------------------------------------------

local state = { phase = 0, poll = 0, fill = 0, clock = 0, millis = 0, emits = {} }
local unknown_host = {}

local function deepcopy(v, seen)
    if type(v) ~= "table" then return v end
    seen = seen or {}
    if seen[v] then return seen[v] end
    local out = {}
    seen[v] = out
    for k, x in pairs(v) do out[deepcopy(k, seen)] = deepcopy(x, seen) end
    return out
end

local function fail(what)
    error(what .. ": timeout (probe: the device does not answer)", 2)
end

host.emit = function(der_type, data)
    table.insert(state.emits, {
        phase = state.phase, poll = state.poll,
        der = tostring(der_type), data = deepcopy(data),
    })
    return true
end

host.modbus_read = function(addr, count, kind)
    if state.phase == 2 then fail("modbus_read") end
    local n = count or 1
    if state.phase == 3 then n = n // 2 end  -- a short reply: half the registers
    local regs = {}
    for i = 0, n - 1 do
        local a = addr + i
        if a == 40000 then regs[i + 1] = 0x5375      -- SunSpec "Su"
        elseif a == 40001 then regs[i + 1] = 0x6e53  -- SunSpec "nS"
        else regs[i + 1] = state.fill end
    end
    return regs
end

local function write_ok() if state.phase == 2 then fail("write") end return true end
host.modbus_write = write_ok
host.modbus_write_multiple = write_ok
host.modbus_write_multi = write_ok
host.write = write_ok
host.write_fc06 = write_ok
host.write_registers = write_ok

host.http_get = function() fail("http_get") end
host.http_post = function() fail("http_post") end
host.http_patch = function() fail("http_patch") end
host.mqtt_messages = function() return {} end
host.serial_read = function() return nil end
host.serial_available = function() return 0 end
host.p1_telegram = function() return nil end

host.now_ms = function() state.clock = state.clock + 50; return state.clock end
host.millis = function() state.millis = state.millis + 50; return state.millis end
host.sleep = function() end
host.control_mode = function() return "" end
host.bus_parked = function() return false end
host.set_model = function() end
host.set_rated_w = function() end
host.set_warmup_s = function() end
host.aes_gcm_decrypt = function() return nil, "probe: no key material" end
host.decode_f32_be = host.decode_f32_be or host.decode_f32
host.decode_string = host.decode_string or function(regs)
    if type(regs) ~= "table" then return "" end
    local chars = {}
    for _, r in ipairs(regs) do
        chars[#chars + 1] = string.char((r >> 8) & 0xFF, r & 0xFF)
    end
    return (table.concat(chars):gsub("%z+$", ""))
end

-- Any other host function: record it and return nil, so an unknown helper
-- does not abort the probe.
setmetatable(host, { __index = function(_, k)
    if type(k) == "string" and k:sub(1, 1) == "_" then return nil end  -- host_mock internals
    unknown_host[tostring(k)] = true
    return function() return nil end
end })

---------------------------------------------------------------------------
-- Running a driver in a sandbox
---------------------------------------------------------------------------

local function read_file(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("a")
    f:close()
    return s
end

local SOURCE = read_file(driver_path)

local function sandbox()
    local env = {
        host = host, string = string, table = table, math = math, utf8 = utf8,
        pairs = pairs, ipairs = ipairs, next = next, select = select,
        type = type, tostring = tostring, tonumber = tonumber,
        pcall = pcall, xpcall = xpcall, error = error, assert = assert,
        rawget = rawget, rawset = rawset, rawequal = rawequal, rawlen = rawlen,
        setmetatable = setmetatable, getmetatable = getmetatable,
        unpack = table.unpack, print = function() end,
    }
    env._G = env
    return env
end

local function run(name)
    state.fill = (name == "A") and FILL_A or FILL_B
    state.clock = (name == "A") and CLOCK_A or CLOCK_B
    state.millis = (name == "A") and MILLIS_A or MILLIS_B
    state.emits = {}
    state.phase, state.poll = 0, 0
    host._emitted, host._calls, host._logs = {}, {}, {}

    local env = sandbox()
    local chunk, err = load(SOURCE, "=driver", "t", env)
    if not chunk then return { ok = false, reason = "load: " .. tostring(err) } end
    local ok, lerr = pcall(chunk)
    if not ok then return { ok = false, reason = "load: " .. tostring(lerr) } end
    if type(env.driver_init) ~= "function" or type(env.driver_poll) ~= "function" then
        return { ok = false, reason = "driver_init/driver_poll not defined" }
    end

    state.phase = 1
    local iok, iret = pcall(env.driver_init, config_for(name))
    if not iok then return { ok = false, reason = "driver_init failed: " .. tostring(iret) } end
    if iret == false then return { ok = false, reason = "driver_init returned false" } end

    local errors = {}
    state.poll = 1
    local pok, perr = pcall(env.driver_poll)
    if not pok then errors[#errors + 1] = "healthy poll: " .. tostring(perr) end

    for _, phase in ipairs({ 2, 3 }) do
        state.phase = phase
        for i = 1, POLLS_FAILING do
            state.poll = i
            local fok, ferr = pcall(env.driver_poll)
            if not fok then
                errors[#errors + 1] = "phase " .. phase .. " poll " .. i .. ": " .. tostring(ferr)
            end
        end
    end
    return { ok = true, emits = state.emits, errors = errors }
end

---------------------------------------------------------------------------
-- Collect numbers per payload path and classify
---------------------------------------------------------------------------

local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function walk(prefix, v, out)
    if type(v) == "table" then
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(x, y) return tostring(x) < tostring(y) end)
        for _, k in ipairs(keys) do
            local seg = (type(k) == "number") and ("[" .. k .. "]") or ("." .. tostring(k))
            walk(prefix .. seg, v[k], out)
        end
    elseif finite(v) then
        out[#out + 1] = { path = prefix, value = v }
    end
end

-- numbers[phase][path] = { [value] = first poll it appeared in }
local function numbers(emits)
    local by = { [1] = {}, [2] = {}, [3] = {} }
    for _, e in ipairs(emits) do
        local leaves = {}
        walk(e.der, e.data, leaves)
        for _, l in ipairs(leaves) do
            local t = by[e.phase]
            if t then
                t[l.path] = t[l.path] or {}
                if t[l.path][l.value] == nil then t[l.path][l.value] = e.poll end
            end
        end
    end
    return by
end

local result = {
    measured = false, reason = nil,
    invented = {}, stale = {},
    unknown_host_functions = {}, errors = {},
}

local A = run("A")
local B = run("B")

if not A.ok or not B.ok then
    result.reason = (not A.ok) and A.reason or B.reason
else
    result.measured = true
    for _, e in ipairs(A.errors) do result.errors[#result.errors + 1] = "A " .. e end
    for _, e in ipairs(B.errors) do result.errors[#result.errors + 1] = "B " .. e end
    local na, nb = numbers(A.emits), numbers(B.emits)
    local DEFAULTS = { min_soc_fract = 0.05, max_soc_fract = 1.0 }
    local function is_default(field, v)
        local d = DEFAULTS[field]
        return d ~= nil and math.abs(v - d) < 1e-6
    end
    local function split(p)
        local i = p:find("[%.%[]")
        if not i then return p, "" end
        local field = p:sub(i)
        if field:sub(1, 1) == "." then field = field:sub(2) end
        return p:sub(1, i - 1), field
    end
    local seen = {}
    for _, phase in ipairs({ 2, 3 }) do
        local paths = {}
        for p in pairs(na[phase]) do paths[#paths + 1] = p end
        table.sort(paths)
        for _, p in ipairs(paths) do
            local vb = nb[phase][p] or {}
            local healthyA, healthyB = na[1][p] or {}, nb[1][p] or {}
            -- phase-1 values that changed with the register fill were read
            local healthy_was_read = next(healthyA) ~= nil and next(healthyB) ~= nil
            if healthy_was_read then
                for v in pairs(healthyA) do
                    if healthyB[v] ~= nil then healthy_was_read = false end
                end
            end
            local der, field = split(p)
            for v, poll in pairs(na[phase][p]) do
                local key = phase .. "|" .. p .. "|" .. tostring(v)
                if not seen[key] and not is_default(field, v) then
                    seen[key] = true
                    local row = { der = der, field = field, value = v, poll = poll, phase = phase }
                    -- phase 3 re-reads the delivered half: a phase-1 value there
                    -- is a fresh read, not a replay, so only phase 2 is stale
                    if vb[v] ~= nil then
                        if healthy_was_read and healthyA[v] ~= nil then
                            if phase == 2 then result.stale[#result.stale + 1] = row end
                        else
                            result.invented[#result.invented + 1] = row
                        end
                    elseif phase == 2 and healthyA[v] ~= nil then
                        result.stale[#result.stale + 1] = row
                    end
                end
            end
        end
    end
end

for k in pairs(unknown_host) do
    result.unknown_host_functions[#result.unknown_host_functions + 1] = k
end
table.sort(result.unknown_host_functions)

io.write(host.json_encode(result), "\n")
