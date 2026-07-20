-- P1 HDLC/DLMS Smart Meter Driver
-- Emits: Meter
-- Protocol: Serial (UART)
--
-- Parses HDLC (IEC 62056-7-5) binary frames with DLMS/COSEM data.
-- Used in: Norway, some Sweden, Austria, Switzerland.
--
-- Config:
--   rx_pin:    GPIO for RX (default 20 on Zap)
--   baud_rate: 2400 or 115200 depending on meter model
--   invert_rx: true if signal is inverted
--   parity:    "none" or "even" depending on meter
--
-- Frame format:
--   0x7E [HDLC header] [LLC] [DLMS APDU with OBIS codes] [FCS] 0x7E

PROTOCOL = "serial"
DRIVER_NAME = "P1 HDLC"

----------------------------------------------------------------------------
-- DLMS OBIS C-code → field mapping for binary protocol
----------------------------------------------------------------------------

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
-- Byte helpers
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

local function n(v)
    return (v == nil) and 0 or (tonumber(v) or 0)
end

----------------------------------------------------------------------------
-- HDLC frame parser
----------------------------------------------------------------------------

local function parse_hdlc_frame(frame)
    local flen = string.len(frame)
    if flen < 9 then return nil end
    if byte(frame, 1) ~= 0x7E or byte(frame, flen) ~= 0x7E then return nil end
    if math.floor(byte(frame, 2) / 16) ~= 0x0A then return nil end

    -- Skip variable-length destination address
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
-- COSEM type decoder
----------------------------------------------------------------------------

local function decode_cosem(data, pos)
    if pos > string.len(data) then return nil, pos end
    local tag = byte(data, pos)
    pos = pos + 1

    if tag == 0x00 then return nil, pos
    elseif tag == 0x01 or tag == 0x02 then
        local count = byte(data, pos); pos = pos + 1
        local arr = {}
        for i = 1, count do arr[i], pos = decode_cosem(data, pos) end
        return arr, pos
    elseif tag == 0x05 then return i32be(data, pos), pos + 4
    elseif tag == 0x06 then return u32be(data, pos), pos + 4
    elseif tag == 0x09 or tag == 0x0A then
        local slen = byte(data, pos); pos = pos + 1
        return string.sub(data, pos, pos + slen - 1), pos + slen
    elseif tag == 0x0F then
        local v = byte(data, pos); if v >= 128 then v = v - 256 end
        return v, pos + 1
    elseif tag == 0x10 then return i16be(data, pos), pos + 2
    elseif tag == 0x11 then return byte(data, pos), pos + 1
    elseif tag == 0x12 then return u16be(data, pos), pos + 2
    elseif tag == 0x16 then return byte(data, pos), pos + 1
    elseif tag == 0x19 then return string.sub(data, pos, pos + 11), pos + 12
    else return nil, pos end
end

----------------------------------------------------------------------------
-- DLMS APDU parser
----------------------------------------------------------------------------

local function parse_dlms_apdu(apdu)
    local values = {}
    local alen = string.len(apdu)
    local pos = 1

    while pos <= alen - 8 do
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
                    if group and group[d] then values[group[d]] = val end
                    if c == 1 and d == 8 and e == 0 then values.total_import_wh = val end
                    if c == 2 and d == 8 and e == 0 then values.total_export_wh = val end
                end
                if c == 96 and d == 1 and type(val) == "string" then
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
-- Emit meter telemetry
----------------------------------------------------------------------------

local sn_set = false

local function emit_meter(values)
    if not sn_set and values.equipment_id then
        local raw = values.equipment_id
        local sn = ""
        local printable = true
        for i = 1, string.len(raw) do
            local b = string.byte(raw, i)
            if b < 32 or b > 126 then printable = false; break end
        end
        sn = printable and raw or ""
        if not printable then
            for i = 1, string.len(raw) do
                sn = sn .. string.format("%02X", string.byte(raw, i))
            end
        end
        if string.len(sn) > 0 then
            host.set_sn(sn)
            sn_set = true
        end
    end

    local iw = n(values.import_w)
    local ew = n(values.export_w)
    local l1w = n(values.l1_import_w) - n(values.l1_export_w)
    local l2w = n(values.l2_import_w) - n(values.l2_export_w)
    local l3w = n(values.l3_import_w) - n(values.l3_export_w)

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
        import_wh = n(values.total_import_wh),
        export_wh = n(values.total_export_wh),
    })
end

----------------------------------------------------------------------------
-- Driver interface
----------------------------------------------------------------------------

local serial_buf = ""

function driver_init(config)
    host.set_make("P1 HDLC")
    serial_buf = ""
end

function driver_poll()
    local ok, data = pcall(host.serial_read, 256, 500)
    if ok and data and string.len(data) > 0 then
        serial_buf = serial_buf .. data
    end

    -- Look for HDLC frame: 0x7E ... 0x7E
    local blen = string.len(serial_buf)
    for i = 1, blen do
        if byte(serial_buf, i) == 0x7E then
            for j = i + 6, blen do
                if byte(serial_buf, j) == 0x7E then
                    local frame = string.sub(serial_buf, i, j)
                    serial_buf = string.sub(serial_buf, j + 1)

                    local payload = parse_hdlc_frame(frame)
                    if payload then
                        local values = parse_dlms_apdu(payload)
                        if values then emit_meter(values) end
                    end
                    return 200
                end
            end
            -- Found start but no end — trim before start, keep buffering
            if i > 1 then serial_buf = string.sub(serial_buf, i) end
            break
        end
    end

    if blen > 8192 then serial_buf = string.sub(serial_buf, blen - 4096) end
    return 200
end

function driver_cleanup()
    serial_buf = ""
end
