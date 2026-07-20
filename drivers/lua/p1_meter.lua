-- P1/HAN Smart Meter Driver — Full Protocol Parser
-- Emits: Meter
-- Protocol: Serial
--
-- Reads raw serial bytes via host.serial_read() and parses all supported
-- European smart meter protocols in Lua:
--
--   DSMR v2.2/v4/v5    (NL, BE, SE, DK)  — IEC 62056-21 ASCII
--   HDLC/DLMS/COSEM    (NO, SE, AT, CH)  — IEC 62056-7-5 binary
--   M-Bus + DLMS       (AT, some CH)     — EN 13757-2 framing
--   GCM encryption     (BE, AT, LU)      — AES-128-GCM (via host.aes_gcm_decrypt)
--
-- Host provides only raw I/O:
--   host.serial_read(max_bytes, timeout_ms) → raw byte string
--   host.aes_gcm_decrypt(key, iv, ct, aad, tag) → plaintext

PROTOCOL = "serial"

----------------------------------------------------------------------------
-- OBIS code table — DSMR v2 through v5, Belgian, Nordic
-- Key: "C.D.E" (A-B prefix stripped during matching)
----------------------------------------------------------------------------

local OBIS = {
    -- Instantaneous active power (kW)
    ["1.7.0"]  = "import_kw",
    ["2.7.0"]  = "export_kw",
    -- Reactive power (kVAR)
    ["3.7.0"]  = "reactive_import_kvar",
    ["4.7.0"]  = "reactive_export_kvar",
    -- Energy counters (kWh)
    ["1.8.0"]  = "total_import_kwh",
    ["1.8.1"]  = "import_t1_kwh",
    ["1.8.2"]  = "import_t2_kwh",
    ["1.8.3"]  = "import_t3_kwh",
    ["1.8.4"]  = "import_t4_kwh",
    ["2.8.0"]  = "total_export_kwh",
    ["2.8.1"]  = "export_t1_kwh",
    ["2.8.2"]  = "export_t2_kwh",
    ["2.8.3"]  = "export_t3_kwh",
    ["2.8.4"]  = "export_t4_kwh",
    -- Reactive energy (kVARh)
    ["3.8.0"]  = "reactive_import_kvarh",
    ["4.8.0"]  = "reactive_export_kvarh",
    -- Per-phase power (kW)
    ["21.7.0"] = "l1_import_kw",
    ["22.7.0"] = "l1_export_kw",
    ["41.7.0"] = "l2_import_kw",
    ["42.7.0"] = "l2_export_kw",
    ["61.7.0"] = "l3_import_kw",
    ["62.7.0"] = "l3_export_kw",
    -- Phase voltage (V)
    ["32.7.0"] = "l1_v",
    ["52.7.0"] = "l2_v",
    ["72.7.0"] = "l3_v",
    -- Phase current (A)
    ["31.7.0"] = "l1_a",
    ["51.7.0"] = "l2_a",
    ["71.7.0"] = "l3_a",
    -- Power factor
    ["13.7.0"] = "power_factor",
    ["33.7.0"] = "l1_pf",
    ["53.7.0"] = "l2_pf",
    ["73.7.0"] = "l3_pf",
    -- Frequency
    ["14.7.0"] = "hz",
    -- Equipment identifier (meter serial number)
    ["96.1.0"] = "equipment_id",
    ["96.1.1"] = "equipment_id",
}

-- DLMS OBIS C-code → field for binary protocol
local DLMS_OBIS = {
    [1]  = { [7] = "import_w",    [8] = "total_import_wh" },
    [2]  = { [7] = "export_w",    [8] = "total_export_wh" },
    [21] = { [7] = "l1_import_w" },
    [22] = { [7] = "l1_export_w" },
    [41] = { [7] = "l2_import_w" },
    [42] = { [7] = "l2_export_w" },
    [61] = { [7] = "l3_import_w" },
    [62] = { [7] = "l3_export_w" },
    [32] = { [7] = "l1_v_raw" },
    [52] = { [7] = "l2_v_raw" },
    [72] = { [7] = "l3_v_raw" },
    [31] = { [7] = "l1_a_raw" },
    [51] = { [7] = "l2_a_raw" },
    [71] = { [7] = "l3_a_raw" },
    [13] = { [7] = "power_factor" },
}

----------------------------------------------------------------------------
-- Byte helpers (Lua 5.1 — no bitwise ops)
----------------------------------------------------------------------------

local function byte(s, i)
    return string.byte(s, i) or 0
end

local function u16be(s, i)
    return byte(s, i) * 256 + byte(s, i + 1)
end

local function u32be(s, i)
    return byte(s, i) * 16777216 + byte(s, i + 1) * 65536
         + byte(s, i + 2) * 256 + byte(s, i + 3)
end

local function i32be(s, i)
    local v = u32be(s, i)
    if v >= 2147483648 then v = v - 4294967296 end
    return v
end

local function i16be(s, i)
    local v = u16be(s, i)
    if v >= 32768 then v = v - 65536 end
    return v
end

local function xor16(a, b)
    local r, bit = 0, 1
    for _ = 1, 16 do
        if math.floor(a / bit) % 2 ~= math.floor(b / bit) % 2 then
            r = r + bit
        end
        bit = bit * 2
    end
    return r
end

local function n(v)
    if v == nil then return 0 end
    return tonumber(v) or 0
end

----------------------------------------------------------------------------
-- CRC
----------------------------------------------------------------------------

local function crc16_dsmr(data, from, to)
    local crc = 0
    for i = from, to do
        crc = xor16(crc, byte(data, i))
        for _ = 1, 8 do
            if crc % 2 == 1 then
                crc = xor16(math.floor(crc / 2), 0xA001)
            else
                crc = math.floor(crc / 2)
            end
        end
    end
    return crc
end

local function crc16_x25(data, from, to)
    local crc = 0xFFFF
    for i = from, to do
        crc = xor16(crc, byte(data, i))
        for _ = 1, 8 do
            if crc % 2 == 1 then
                crc = xor16(math.floor(crc / 2), 0x8408)
            else
                crc = math.floor(crc / 2)
            end
        end
    end
    return xor16(crc, 0xFFFF)
end

----------------------------------------------------------------------------
-- DSMR ASCII parser
----------------------------------------------------------------------------

local function parse_dsmr(telegram)
    local values = {}
    for line in string.gmatch(telegram, "[^\r\n]+") do
        local ch1 = string.sub(line, 1, 1)
        if ch1 ~= "/" and ch1 ~= "!" then
            local full_obis, val_str = string.match(line, "^([%d%-:%.]+)%(([^%)]+)%)")
            if full_obis and val_str then
                local cde = string.match(full_obis, ":(.+)$") or full_obis
                local field = OBIS[cde]
                if field then
                    local num_str = string.match(val_str, "^([^%*]+)")
                    if field == "equipment_id" then
                        -- Equipment ID is a string (hex-encoded or plain), not a number
                        values[field] = num_str or val_str
                    else
                        local val = num_str and tonumber(num_str)
                        if val then values[field] = val end
                    end
                end
            end
        end
    end
    return values
end

----------------------------------------------------------------------------
-- HDLC frame parser
----------------------------------------------------------------------------

local function parse_hdlc_frame(frame)
    local flen = string.len(frame)
    if flen < 9 then return nil end
    if byte(frame, 1) ~= 0x7E or byte(frame, flen) ~= 0x7E then return nil end

    -- Format type 3: upper nibble 0xA
    if math.floor(byte(frame, 2) / 16) ~= 0x0A then return nil end

    -- Skip variable-length destination address (LSB bit 0 = 1 marks end)
    local pos = 4
    while pos <= flen and byte(frame, pos) % 2 == 0 do pos = pos + 1 end
    pos = pos + 1
    -- Skip source address
    while pos <= flen and byte(frame, pos) % 2 == 0 do pos = pos + 1 end
    pos = pos + 1
    -- Control + HCS
    pos = pos + 3

    -- LLC header (0xE6 DSAP)
    if pos + 2 <= flen and byte(frame, pos) == 0xE6 then pos = pos + 3 end

    local payload_end = flen - 3
    if payload_end < pos then return nil end
    return string.sub(frame, pos, payload_end)
end

----------------------------------------------------------------------------
-- M-Bus frame parser
----------------------------------------------------------------------------

local function parse_mbus_frame(frame)
    local flen = string.len(frame)
    if flen < 9 then return nil end
    if byte(frame, 1) ~= 0x68 or byte(frame, flen) ~= 0x16 then return nil end
    if byte(frame, 2) ~= byte(frame, 3) then return nil end
    if byte(frame, 4) ~= 0x68 then return nil end

    local payload_end = flen - 2
    if payload_end < 8 then return nil end
    return string.sub(frame, 8, payload_end)
end

----------------------------------------------------------------------------
-- COSEM type decoder
----------------------------------------------------------------------------

local function decode_cosem(data, pos)
    if pos > string.len(data) then return nil, pos end
    local tag = byte(data, pos)
    pos = pos + 1

    if tag == 0x00 then return nil, pos
    elseif tag == 0x01 or tag == 0x02 then
        -- Array / Structure
        local count = byte(data, pos); pos = pos + 1
        local arr = {}
        for i = 1, count do
            arr[i], pos = decode_cosem(data, pos)
        end
        return arr, pos
    elseif tag == 0x05 then return i32be(data, pos), pos + 4
    elseif tag == 0x06 then return u32be(data, pos), pos + 4
    elseif tag == 0x09 then
        local slen = byte(data, pos); pos = pos + 1
        return string.sub(data, pos, pos + slen - 1), pos + slen
    elseif tag == 0x0A then
        local slen = byte(data, pos); pos = pos + 1
        return string.sub(data, pos, pos + slen - 1), pos + slen
    elseif tag == 0x0F then
        local v = byte(data, pos)
        if v >= 128 then v = v - 256 end
        return v, pos + 1
    elseif tag == 0x10 then return i16be(data, pos), pos + 2
    elseif tag == 0x11 then return byte(data, pos), pos + 1
    elseif tag == 0x12 then return u16be(data, pos), pos + 2
    elseif tag == 0x16 then return byte(data, pos), pos + 1
    elseif tag == 0x19 then
        return string.sub(data, pos, pos + 11), pos + 12
    else return nil, pos end
end

----------------------------------------------------------------------------
-- DLMS APDU parser — scan for OBIS octet-strings and decode values
----------------------------------------------------------------------------

local function parse_dlms_apdu(apdu)
    local values = {}
    local alen = string.len(apdu)
    local pos = 1

    while pos <= alen - 8 do
        -- Look for OBIS: type 0x09, length 0x06, then 6 bytes
        if byte(apdu, pos) == 0x09 and byte(apdu, pos + 1) == 0x06 then
            local c = byte(apdu, pos + 4)
            local d = byte(apdu, pos + 5)
            local e = byte(apdu, pos + 6)
            pos = pos + 8

            local val
            val, pos = decode_cosem(apdu, pos)

            if val then
                if type(val) == "number" then
                    local group = DLMS_OBIS[c]
                    if group and group[d] then
                        values[group[d]] = val
                    end
                    -- Energy counters (separate because group 1/2 already has power)
                    if c == 1 and d == 8 and e == 0 then values.total_import_wh = val end
                    if c == 2 and d == 8 and e == 0 then values.total_export_wh = val end
                end
                -- Equipment ID: OBIS 0.0.96.1.0 or 0.0.96.1.1 (string value)
                if c == 96 and (d == 1) and type(val) == "string" then
                    values.equipment_id = val
                end
            end
        else
            pos = pos + 1
        end
    end

    -- Scale COSEM raw values: voltage /10, current /100
    if values.l1_v_raw then values.l1_v = values.l1_v_raw / 10 end
    if values.l2_v_raw then values.l2_v = values.l2_v_raw / 10 end
    if values.l3_v_raw then values.l3_v = values.l3_v_raw / 10 end
    if values.l1_a_raw then values.l1_a = values.l1_a_raw / 100 end
    if values.l2_a_raw then values.l2_a = values.l2_a_raw / 100 end
    if values.l3_a_raw then values.l3_a = values.l3_a_raw / 100 end

    return values
end

----------------------------------------------------------------------------
-- GCM decryption
----------------------------------------------------------------------------

local encryption_key = nil
local auth_key = nil

local function decrypt_gcm(data)
    if not encryption_key then return nil end

    local dlen = string.len(data)
    if dlen < 20 then return nil end
    local pos = 1

    local sec_byte = byte(data, pos); pos = pos + 1
    local sys_title = string.sub(data, pos, pos + 7); pos = pos + 8

    -- Variable-length payload size
    local plen = byte(data, pos); pos = pos + 1
    if plen == 0x81 then plen = byte(data, pos); pos = pos + 1
    elseif plen == 0x82 then plen = u16be(data, pos); pos = pos + 2 end

    -- Security sub-byte
    if byte(data, pos) == 0x30 or byte(data, pos) == 0x20 then pos = pos + 1 end

    local fc = string.sub(data, pos, pos + 3); pos = pos + 4
    local iv = sys_title .. fc

    local ct_end = dlen - 12
    if ct_end < pos then return nil end
    local ciphertext = string.sub(data, pos, ct_end)
    local tag = string.sub(data, ct_end + 1)
    local aad = string.char(sec_byte) .. (auth_key or "")

    local ok, plaintext = pcall(host.aes_gcm_decrypt,
        encryption_key, iv, ciphertext, aad, tag)
    if not ok or not plaintext then
        host.log("GCM decryption failed")
        return nil
    end
    return plaintext
end

----------------------------------------------------------------------------
-- Frame detection from serial buffer
----------------------------------------------------------------------------

local serial_buf = ""
local protocol = nil  -- "dsmr", "hdlc", "mbus"

local function detect_frame()
    local buf = serial_buf
    local blen = string.len(buf)

    -- DSMR: "/" ... "!" CRC \r\n
    if not protocol or protocol == "dsmr" then
        local s = string.find(buf, "/", 1, true)
        if s then
            local e = string.find(buf, "!", s, true)
            if e then
                local nl = string.find(buf, "\n", e, true)
                if nl then
                    local telegram = string.sub(buf, s, nl)
                    serial_buf = string.sub(buf, nl + 1)
                    protocol = "dsmr"
                    return "dsmr", telegram
                end
            end
        end
    end

    -- HDLC: 0x7E ... 0x7E
    if not protocol or protocol == "hdlc" then
        for i = 1, blen do
            if byte(buf, i) == 0x7E then
                for j = i + 6, blen do
                    if byte(buf, j) == 0x7E then
                        local frame = string.sub(buf, i, j)
                        serial_buf = string.sub(buf, j + 1)
                        protocol = "hdlc"
                        return "hdlc", frame
                    end
                end
                break
            end
        end
    end

    -- M-Bus: 0x68 len len 0x68 ... checksum 0x16
    if not protocol or protocol == "mbus" then
        for i = 1, blen do
            if byte(buf, i) == 0x68 and i + 3 <= blen then
                local mlen = byte(buf, i + 1)
                local fe = i + 3 + mlen + 2
                if fe <= blen and byte(buf, fe) == 0x16 and byte(buf, i + 2) == mlen and byte(buf, i + 3) == 0x68 then
                    local frame = string.sub(buf, i, fe)
                    serial_buf = string.sub(buf, fe + 1)
                    protocol = "mbus"
                    return "mbus", frame
                end
                break
            end
        end
    end

    -- Prevent unbounded buffer growth
    if blen > 8192 then serial_buf = string.sub(buf, blen - 4096) end
    return nil, nil
end

----------------------------------------------------------------------------
-- Emit meter telemetry from parsed values
----------------------------------------------------------------------------

local sn_set = false

local function emit_meter(values)
    -- Set meter serial from equipment_id (OBIS 96.1.0/96.1.1) on first telegram
    if not sn_set and values.equipment_id then
        local raw = values.equipment_id
        -- Convert to printable string: if it contains non-printable bytes, hex-encode it
        local sn = ""
        local is_printable = true
        for i = 1, string.len(raw) do
            local b = string.byte(raw, i)
            if b < 32 or b > 126 then is_printable = false; break end
        end
        if is_printable and string.len(raw) > 0 then
            sn = raw
        else
            -- Hex-encode binary equipment ID
            for i = 1, string.len(raw) do
                sn = sn .. string.format("%02X", string.byte(raw, i))
            end
        end
        if string.len(sn) > 0 then
            host.set_sn(sn)
            sn_set = true
        end
    end

    local iw, ew
    if values.import_kw then
        iw = n(values.import_kw) * 1000
        ew = n(values.export_kw) * 1000
    else
        iw = n(values.import_w)
        ew = n(values.export_w)
    end

    local l1w, l2w, l3w
    if values.l1_import_kw then
        l1w = (n(values.l1_import_kw) - n(values.l1_export_kw)) * 1000
        l2w = (n(values.l2_import_kw) - n(values.l2_export_kw)) * 1000
        l3w = (n(values.l3_import_kw) - n(values.l3_export_kw)) * 1000
    else
        l1w = n(values.l1_import_w) - n(values.l1_export_w)
        l2w = n(values.l2_import_w) - n(values.l2_export_w)
        l3w = n(values.l3_import_w) - n(values.l3_export_w)
    end

    local imp_wh = 0
    if values.total_import_kwh then
        imp_wh = n(values.total_import_kwh) * 1000
    elseif values.total_import_wh then
        imp_wh = n(values.total_import_wh)
    else
        imp_wh = (n(values.import_t1_kwh) + n(values.import_t2_kwh)
                + n(values.import_t3_kwh) + n(values.import_t4_kwh)) * 1000
    end

    local exp_wh = 0
    if values.total_export_kwh then
        exp_wh = n(values.total_export_kwh) * 1000
    elseif values.total_export_wh then
        exp_wh = n(values.total_export_wh)
    else
        exp_wh = (n(values.export_t1_kwh) + n(values.export_t2_kwh)
                + n(values.export_t3_kwh) + n(values.export_t4_kwh)) * 1000
    end

    host.emit("meter", {
        w         = iw - ew,
        l1_w      = l1w,
        l2_w      = l2w,
        l3_w      = l3w,
        l1_v      = n(values.l1_v),
        l2_v      = n(values.l2_v),
        l3_v      = n(values.l3_v),
        l1_a      = n(values.l1_a),
        l2_a      = n(values.l2_a),
        l3_a      = n(values.l3_a),
        hz        = n(values.hz),
        import_wh = imp_wh,
        export_wh = exp_wh,
    })
end

----------------------------------------------------------------------------
-- Driver interface
----------------------------------------------------------------------------

function driver_init(config)
    host.set_make("P1 Meter")
    serial_buf = ""
    protocol = nil
    if config.encryption_key then encryption_key = config.encryption_key end
    if config.auth_key then auth_key = config.auth_key end
end

function driver_poll()
    local ok, data = pcall(host.serial_read, 2048, 500)
    if ok and data and string.len(data) > 0 then
        serial_buf = serial_buf .. data
    end

    local proto, frame = detect_frame()
    if not proto then return 200 end

    local values

    if proto == "dsmr" then
        values = parse_dsmr(frame)

    elseif proto == "hdlc" then
        local payload = parse_hdlc_frame(frame)
        if payload then
            local first = byte(payload, 1)
            if first == 0xDB or first == 0xDC then
                payload = decrypt_gcm(string.sub(payload, 2))
            end
            if payload then values = parse_dlms_apdu(payload) end
        end

    elseif proto == "mbus" then
        local payload = parse_mbus_frame(frame)
        if payload then values = parse_dlms_apdu(payload) end
    end

    if values then emit_meter(values) end
    return 200
end

function driver_cleanup()
    serial_buf = ""
    protocol = nil
    encryption_key = nil
    auth_key = nil
end
