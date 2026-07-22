-- host_mock.lua -- Comprehensive mock of the host API for driver testing
--
-- Creates a global `host` table that records all calls, provides configurable
-- mock responses, and implements REAL decode/scale functions so that driver
-- decode logic is genuinely exercised.
--
-- Usage:
--   dofile("host_mock.lua")
--   host._modbus_registers = { holding = { [100] = {2300, 50} } }
--   -- then load and run a driver

host = {}

---------------------------------------------------------------------------
-- Polyfills for Lua 5.5+ (math.frexp and math.ldexp removed)
---------------------------------------------------------------------------

local frexp = math.frexp or function(x)
    if x == 0 then return 0, 0 end
    local e = math.floor(math.log(math.abs(x)) / math.log(2)) + 1
    return x / (2 ^ e), e
end

local ldexp = math.ldexp or function(x, e)
    return x * (2 ^ e)
end

---------------------------------------------------------------------------
-- Internal state
---------------------------------------------------------------------------

host._calls   = {}          -- ordered list of {func, args}
host._emitted = {}          -- map: der_type -> list of data tables
host._make    = nil         -- brand name set via set_make
host._logs    = {}          -- list of logged messages
host._errors  = {}          -- list of error messages for test reporting
host._faulted = false       -- current device fault state
host._fault_reason = ""     -- current device fault reason

-- Configurable mock data
host._modbus_registers = {  -- { holding = {[addr]={reg1,...}}, input = {[addr]={reg1,...}} }
    holding = {},
    input   = {},
}
host._http_responses = {}   -- { [full_url] = response_body_string }
host._mqtt_buffer    = {}   -- list of {topic=..., payload=...}
host._p1_data        = nil  -- P1 telegram table or nil
host._modbus_write_error = nil
host._modbus_write_fail_at = nil
host._modbus_write_attempts = 0
host._modbus_read_error = nil
host._modbus_read_fail_addresses = {}
host._modbus_read_short_counts = {}

-- Internal counters
host._millis_counter = 0
host._millis_step    = 100  -- ms per call to host.millis()

---------------------------------------------------------------------------
-- Call recording helper
---------------------------------------------------------------------------

local function record_call(func_name, ...)
    local args = {...}
    table.insert(host._calls, {func = func_name, args = args})
end

---------------------------------------------------------------------------
-- Reset (for running multiple drivers in sequence)
---------------------------------------------------------------------------

function host.reset()
    host._calls   = {}
    host._emitted = {}
    host._make    = nil
    host._sn      = nil
    host._logs    = {}
    host._errors  = {}
    host._faulted = false
    host._fault_reason = ""
    host._modbus_registers = { holding = {}, input = {} }
    host._http_responses = {}
    host._mqtt_buffer    = {}
    host._p1_data        = nil
    host._modbus_write_error = nil
    host._modbus_write_fail_at = nil
    host._modbus_write_attempts = 0
    host._modbus_read_error = nil
    host._modbus_read_fail_addresses = {}
    host._modbus_read_short_counts = {}
    host._serial_buffer  = ""
    host._millis_counter = 0
end

---------------------------------------------------------------------------
-- Basic host functions
---------------------------------------------------------------------------

function host.log(level, message)
    local value = message or level
    record_call("log", level, message)
    table.insert(host._logs, tostring(value))
end

function host.millis()
    record_call("millis")
    host._millis_counter = host._millis_counter + host._millis_step
    return host._millis_counter
end

function host.set_make(name)
    record_call("set_make", name)
    host._make = name
end

function host.set_sn(serial_number)
    record_call("set_sn", serial_number)
    host._sn = serial_number
end

function host.set_device_fault(faulted, reason)
    record_call("set_device_fault", faulted, reason)
    host._faulted = faulted == true
    host._fault_reason = reason or ""
end

function host.emit(der_type, data)
    record_call("emit", der_type, data)
    if not host._emitted[der_type] then
        host._emitted[der_type] = {}
    end
    -- Deep copy the data table to prevent aliasing issues
    local copy = {}
    if type(data) == "table" then
        for k, v in pairs(data) do
            copy[k] = v
        end
    end
    table.insert(host._emitted[der_type], copy)
    return true
end

---------------------------------------------------------------------------
-- Modbus functions
---------------------------------------------------------------------------

function host.modbus_read(addr, count, kind)
    record_call("modbus_read", addr, count, kind)

    -- Validate kind
    if kind ~= "holding" and kind ~= "input" then
        error("modbus_read: invalid kind '" .. tostring(kind) .. "', must be 'holding' or 'input'")
    end

    -- Validate arguments
    if type(addr) ~= "number" then
        error("modbus_read: addr must be a number, got " .. type(addr))
    end
    if type(count) ~= "number" or count < 1 then
        error("modbus_read: count must be a positive number, got " .. tostring(count))
    end

    local read_error = host._modbus_read_fail_addresses[addr] or host._modbus_read_error
    if read_error then
        error(tostring(read_error))
    end

    local short_count = host._modbus_read_short_counts[addr]
    if short_count ~= nil and short_count >= 0 and short_count < count then
        count = short_count
    end

    local reg_map = host._modbus_registers[kind]
    if not reg_map then
        error("modbus_read: no register data for kind '" .. kind .. "'")
    end

    -- Look up registers: try exact address match first, then build from
    -- individual addresses
    local result = {}
    for i = 0, count - 1 do
        local a = addr + i
        local entry = reg_map[a]
        if entry then
            -- entry can be a single number or a table
            if type(entry) == "table" then
                -- If this is the base address and the table has count values,
                -- return them directly
                if i == 0 and #entry >= count then
                    local r = {}
                    for j = 1, count do
                        r[j] = entry[j]
                    end
                    return r
                end
                -- Otherwise take the first element
                result[i + 1] = entry[1] or 0
            else
                result[i + 1] = entry
            end
        else
            -- Default: return 0 for unmapped registers
            result[i + 1] = 0
        end
    end

    return result
end

function host.modbus_write(addr, value)
    record_call("modbus_write", addr, value)
    host._modbus_write_attempts = host._modbus_write_attempts + 1
    if host._modbus_write_error or
       host._modbus_write_attempts == host._modbus_write_fail_at then
        return host._modbus_write_error or "simulated write failure"
    end
    host._modbus_registers.holding[addr] = value
    return nil
end

function host.modbus_write_multiple(addr, values)
    record_call("modbus_write_multiple", addr, values)
    host._modbus_write_attempts = host._modbus_write_attempts + 1
    if host._modbus_write_error or
       host._modbus_write_attempts == host._modbus_write_fail_at then
        return host._modbus_write_error or "simulated write failure"
    end
    for i, value in ipairs(values) do
        host._modbus_registers.holding[addr + i - 1] = value
    end
    return nil
end


function host.modbus_write_multi(addr, values)
    return host.modbus_write_multiple(addr, values)
end

---------------------------------------------------------------------------
-- MQTT functions
---------------------------------------------------------------------------

function host.mqtt_subscribe(topic)
    record_call("mqtt_subscribe", topic)
    return true
end

function host.mqtt_messages()
    record_call("mqtt_messages")
    if #host._mqtt_buffer == 0 then
        return {}
    end
    -- Drain the buffer
    local msgs = host._mqtt_buffer
    host._mqtt_buffer = {}
    return msgs
end

function host.mqtt_publish(topic, payload)
    record_call("mqtt_publish", topic, payload)
    return true
end

---------------------------------------------------------------------------
-- HTTP functions
---------------------------------------------------------------------------

function host.http_get(url)
    record_call("http_get", url)
    local resp = host._http_responses[url]
    if resp then
        return resp
    end
    -- Try prefix matching: check if any key is a suffix of the URL
    for pattern_url, body in pairs(host._http_responses) do
        if string.find(url, pattern_url, 1, true) then
            return body
        end
    end
    error("http_get: no mock response for URL: " .. tostring(url))
end

---------------------------------------------------------------------------
-- Serial functions
---------------------------------------------------------------------------

host._serial_buffer = ""  -- raw bytes to return from serial_read

function host.serial_read(max_bytes, timeout_ms)
    record_call("serial_read", max_bytes, timeout_ms)
    if host._serial_buffer == "" then return nil end
    local chunk = string.sub(host._serial_buffer, 1, max_bytes)
    host._serial_buffer = string.sub(host._serial_buffer, max_bytes + 1)
    return chunk
end

function host.serial_available()
    record_call("serial_available")
    return string.len(host._serial_buffer)
end

---------------------------------------------------------------------------
-- P1 functions (legacy, kept for backward compat in tests)
---------------------------------------------------------------------------

function host.p1_telegram()
    record_call("p1_telegram")
    return host._p1_data
end

---------------------------------------------------------------------------
-- REAL decode implementations
-- These are actual implementations, not mocks, so driver decode logic
-- is genuinely tested.
---------------------------------------------------------------------------

-- Decode a U16 value (identity, but ensures 16-bit range)
function host.decode_u16(val)
    record_call("decode_u16", val)
    return val & 0xFFFF
end

-- Decode a U16 value as signed I16 (two's complement)
function host.decode_i16(val)
    record_call("decode_i16", val)
    val = val & 0xFFFF  -- ensure 16-bit
    if val >= 0x8000 then
        return val - 0x10000
    end
    return val
end

-- Decode two U16 registers as unsigned U32, big-endian (hi, lo)
function host.decode_u32(hi, lo)
    record_call("decode_u32", hi, lo)
    return (hi & 0xFFFF) * 65536 + (lo & 0xFFFF)
end

function host.decode_u32_be(hi, lo)
    return host.decode_u32(hi, lo)
end

-- Decode two U16 registers as signed I32, big-endian (hi, lo)
function host.decode_i32(hi, lo)
    record_call("decode_i32", hi, lo)
    local val = (hi & 0xFFFF) * 65536 + (lo & 0xFFFF)
    if val & 0x80000000 ~= 0 then
        return val - 0x100000000
    end
    return val
end

function host.decode_i32_be(hi, lo)
    return host.decode_i32(hi, lo)
end

-- Decode two U16 registers as unsigned U32, little-endian (lo, hi)
function host.decode_u32_le(lo, hi)
    record_call("decode_u32_le", lo, hi)
    return (hi & 0xFFFF) * 65536 + (lo & 0xFFFF)
end

-- Decode two U16 registers as signed I32, little-endian (lo, hi)
function host.decode_i32_le(lo, hi)
    record_call("decode_i32_le", lo, hi)
    local val = (hi & 0xFFFF) * 65536 + (lo & 0xFFFF)
    if val >= 0x80000000 then
        return val - 0x100000000
    end
    return val
end

-- Decode two U16 registers as IEEE 754 float32, big-endian (hi, lo)
function host.decode_f32(hi, lo)
    record_call("decode_f32", hi, lo)
    local raw = (hi & 0xFFFF) * 65536 + (lo & 0xFFFF)

    -- Handle special cases
    if raw == 0 then return 0.0 end
    if raw == 0x80000000 then return -0.0 end

    local sign = 1
    if raw & 0x80000000 ~= 0 then
        sign = -1
        raw = raw & 0x7FFFFFFF
    end

    local exponent = (raw >> 23) & 0xFF
    local mantissa = raw & 0x7FFFFF

    if exponent == 0 then
        -- Denormalized number
        return sign * ldexp(mantissa / 0x800000, -126)
    elseif exponent == 255 then
        if mantissa == 0 then
            return sign * math.huge
        else
            return 0/0  -- NaN
        end
    end

    -- Normalized number
    local frac = 1.0 + mantissa / 0x800000
    return sign * ldexp(frac, exponent - 127)
end

-- Decode four U16 registers as unsigned U64
function host.decode_u64(w1, w2, w3, w4)
    record_call("decode_u64", w1, w2, w3, w4)
    -- Use floating point for large values (Lua integers are 64-bit in 5.3+)
    return ((w1 & 0xFFFF) << 48) | ((w2 & 0xFFFF) << 32) |
           ((w3 & 0xFFFF) << 16) | (w4 & 0xFFFF)
end

-- Scale a value by a SunSpec scale factor: value * 10^sf
function host.scale(value, sf)
    record_call("scale", value, sf)
    if sf == 0 then return value end
    return value * (10.0 ^ sf)
end

---------------------------------------------------------------------------
-- JSON decode -- real implementation (no external dependencies)
---------------------------------------------------------------------------

-- A simple but functional JSON parser that handles:
-- objects, arrays, strings, numbers, booleans, null

local function json_skip_ws(str, pos)
    while pos <= #str do
        local c = string.byte(str, pos)
        if c == 32 or c == 9 or c == 10 or c == 13 then  -- space, tab, LF, CR
            pos = pos + 1
        else
            break
        end
    end
    return pos
end

local json_parse_value  -- forward declaration

local function json_parse_string(str, pos)
    -- pos should point to opening quote
    if string.byte(str, pos) ~= 34 then  -- '"'
        return nil, pos
    end
    pos = pos + 1
    local parts = {}
    while pos <= #str do
        local c = string.byte(str, pos)
        if c == 34 then  -- closing '"'
            return table.concat(parts), pos + 1
        elseif c == 92 then  -- '\'
            pos = pos + 1
            if pos > #str then return nil, pos end
            local esc = string.byte(str, pos)
            if esc == 34 then      -- \"
                table.insert(parts, '"')
            elseif esc == 92 then  -- \\
                table.insert(parts, '\\')
            elseif esc == 47 then  -- \/
                table.insert(parts, '/')
            elseif esc == 98 then  -- \b
                table.insert(parts, '\b')
            elseif esc == 102 then -- \f
                table.insert(parts, '\f')
            elseif esc == 110 then -- \n
                table.insert(parts, '\n')
            elseif esc == 114 then -- \r
                table.insert(parts, '\r')
            elseif esc == 116 then -- \t
                table.insert(parts, '\t')
            elseif esc == 117 then -- \uXXXX
                local hex = string.sub(str, pos + 1, pos + 4)
                local cp = tonumber(hex, 16)
                if cp then
                    if cp < 0x80 then
                        table.insert(parts, string.char(cp))
                    elseif cp < 0x800 then
                        table.insert(parts, string.char(
                            0xC0 + ((cp >> 6) & 0x1F),
                            0x80 + (cp & 0x3F)
                        ))
                    else
                        table.insert(parts, string.char(
                            0xE0 + ((cp >> 12) & 0x0F),
                            0x80 + ((cp >> 6) & 0x3F),
                            0x80 + (cp & 0x3F)
                        ))
                    end
                    pos = pos + 4
                else
                    table.insert(parts, '\\u' .. hex)
                    pos = pos + 4
                end
            else
                table.insert(parts, string.char(esc))
            end
            pos = pos + 1
        else
            table.insert(parts, string.char(c))
            pos = pos + 1
        end
    end
    return nil, pos  -- unterminated string
end

local function json_parse_number(str, pos)
    local start = pos
    -- Optional minus
    if string.byte(str, pos) == 45 then  -- '-'
        pos = pos + 1
    end
    -- Integer part
    while pos <= #str do
        local c = string.byte(str, pos)
        if c >= 48 and c <= 57 then  -- '0'-'9'
            pos = pos + 1
        else
            break
        end
    end
    -- Fractional part
    if pos <= #str and string.byte(str, pos) == 46 then  -- '.'
        pos = pos + 1
        while pos <= #str do
            local c = string.byte(str, pos)
            if c >= 48 and c <= 57 then
                pos = pos + 1
            else
                break
            end
        end
    end
    -- Exponent
    if pos <= #str then
        local c = string.byte(str, pos)
        if c == 69 or c == 101 then  -- 'E' or 'e'
            pos = pos + 1
            if pos <= #str then
                c = string.byte(str, pos)
                if c == 43 or c == 45 then  -- '+' or '-'
                    pos = pos + 1
                end
            end
            while pos <= #str do
                c = string.byte(str, pos)
                if c >= 48 and c <= 57 then
                    pos = pos + 1
                else
                    break
                end
            end
        end
    end
    local num_str = string.sub(str, start, pos - 1)
    local val = tonumber(num_str)
    if val then
        return val, pos
    end
    return nil, start
end

local function json_parse_object(str, pos)
    -- pos should point to '{'
    pos = pos + 1
    local obj = {}
    pos = json_skip_ws(str, pos)
    if pos <= #str and string.byte(str, pos) == 125 then  -- '}'
        return obj, pos + 1
    end
    while pos <= #str do
        pos = json_skip_ws(str, pos)
        -- Parse key (must be string)
        local key
        key, pos = json_parse_string(str, pos)
        if not key then return nil, pos end
        -- Skip colon
        pos = json_skip_ws(str, pos)
        if pos > #str or string.byte(str, pos) ~= 58 then  -- ':'
            return nil, pos
        end
        pos = pos + 1
        -- Parse value
        pos = json_skip_ws(str, pos)
        local val
        val, pos = json_parse_value(str, pos)
        if val == nil and type(val) ~= "table" then
            -- Check if it was explicitly null (we use a sentinel)
            -- Actually, nil values are valid from null parsing
        end
        obj[key] = val
        -- Skip comma or end
        pos = json_skip_ws(str, pos)
        if pos > #str then return obj, pos end
        local c = string.byte(str, pos)
        if c == 125 then  -- '}'
            return obj, pos + 1
        elseif c == 44 then  -- ','
            pos = pos + 1
        else
            return obj, pos  -- malformed, return what we have
        end
    end
    return obj, pos
end

local function json_parse_array(str, pos)
    -- pos should point to '['
    pos = pos + 1
    local arr = {}
    pos = json_skip_ws(str, pos)
    if pos <= #str and string.byte(str, pos) == 93 then  -- ']'
        return arr, pos + 1
    end
    while pos <= #str do
        pos = json_skip_ws(str, pos)
        local val
        val, pos = json_parse_value(str, pos)
        table.insert(arr, val)
        pos = json_skip_ws(str, pos)
        if pos > #str then return arr, pos end
        local c = string.byte(str, pos)
        if c == 93 then  -- ']'
            return arr, pos + 1
        elseif c == 44 then  -- ','
            pos = pos + 1
        else
            return arr, pos  -- malformed
        end
    end
    return arr, pos
end

json_parse_value = function(str, pos)
    pos = json_skip_ws(str, pos)
    if pos > #str then return nil, pos end
    local c = string.byte(str, pos)
    if c == 34 then  -- '"'
        return json_parse_string(str, pos)
    elseif c == 123 then  -- '{'
        return json_parse_object(str, pos)
    elseif c == 91 then  -- '['
        return json_parse_array(str, pos)
    elseif c == 116 then  -- 't' (true)
        if string.sub(str, pos, pos + 3) == "true" then
            return true, pos + 4
        end
        return nil, pos
    elseif c == 102 then  -- 'f' (false)
        if string.sub(str, pos, pos + 4) == "false" then
            return false, pos + 5
        end
        return nil, pos
    elseif c == 110 then  -- 'n' (null)
        if string.sub(str, pos, pos + 3) == "null" then
            return nil, pos + 4
        end
        return nil, pos
    elseif c == 45 or (c >= 48 and c <= 57) then  -- '-' or '0'-'9'
        return json_parse_number(str, pos)
    end
    return nil, pos
end

function host.json_decode(str)
    record_call("json_decode", str)
    if type(str) ~= "string" then
        error("json_decode: expected string, got " .. type(str))
    end
    local val, pos = json_parse_value(str, 1)
    return val
end

---------------------------------------------------------------------------
-- JSON encode -- helper for test output
---------------------------------------------------------------------------

local json_encode_value  -- forward declaration

local function json_encode_string(s)
    s = string.gsub(s, '\\', '\\\\')
    s = string.gsub(s, '"', '\\"')
    s = string.gsub(s, '\n', '\\n')
    s = string.gsub(s, '\r', '\\r')
    s = string.gsub(s, '\t', '\\t')
    return '"' .. s .. '"'
end

local function is_array(t)
    if type(t) ~= "table" then return false end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    if n == 0 then return true end  -- empty table = array
    for i = 1, n do
        if t[i] == nil then return false end
    end
    return true
end

json_encode_value = function(val)
    if val == nil then
        return "null"
    elseif type(val) == "boolean" then
        return val and "true" or "false"
    elseif type(val) == "number" then
        if val ~= val then return "null" end  -- NaN
        if val == math.huge then return "1e308" end
        if val == -math.huge then return "-1e308" end
        -- Format with enough precision
        local s = string.format("%.10g", val)
        return s
    elseif type(val) == "string" then
        return json_encode_string(val)
    elseif type(val) == "table" then
        if is_array(val) then
            local parts = {}
            for i = 1, #val do
                table.insert(parts, json_encode_value(val[i]))
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            -- Sort keys for deterministic output
            local keys = {}
            for k in pairs(val) do
                table.insert(keys, k)
            end
            table.sort(keys, function(a, b)
                return tostring(a) < tostring(b)
            end)
            for _, k in ipairs(keys) do
                table.insert(parts, json_encode_string(tostring(k)) .. ":" .. json_encode_value(val[k]))
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    else
        return '"' .. tostring(val) .. '"'
    end
end

function host.json_encode(val)
    return json_encode_value(val)
end

---------------------------------------------------------------------------
-- Helpers for encoding F32 into register pairs (for test data setup)
---------------------------------------------------------------------------

-- Encode a float into two U16 registers (big-endian IEEE 754)
function host.encode_f32(value)
    if value == 0 then
        return 0, 0
    end

    local sign = 0
    if value < 0 then
        sign = 1
        value = -value
    end

    local mantissa, exponent = frexp(value)
    -- frexp returns m * 2^e where 0.5 <= m < 1
    -- IEEE 754: 1.f * 2^(e-127), so adjust
    exponent = exponent + 126  -- bias
    mantissa = (mantissa * 2 - 1) * 0x800000  -- remove leading 1, scale to 23 bits

    local raw = (sign << 31) | (exponent << 23) | (math.floor(mantissa) & 0x7FFFFF)
    local hi = (raw >> 16) & 0xFFFF
    local lo = raw & 0xFFFF
    return hi, lo
end

return host
