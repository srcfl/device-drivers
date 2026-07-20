-- P1 DSMR Smart Meter Driver
-- Emits: Meter
-- Protocol: Serial (UART)
--
-- Parses IEC 62056-21 ASCII telegrams from DSMR v2.2/v4/v5 meters.
-- Used in: Netherlands, Belgium, Sweden (Aydon/Ellevio), Denmark.
--
-- Config:
--   rx_pin:    GPIO for RX (default 20 on Zap)
--   baud_rate: 115200 for DSMR v5/Nordic, 9600 for DSMR v2/v4
--   invert_rx: true if signal is inverted (common on Zap hardware)
--   parity:    "none" (default), "even" for some v2/v4 meters
--
-- Telegram format:
--   /ISk5\2MT382-1000         ← header (manufacturer ID)
--   0-0:96.1.1(453030...)     ← meter serial (hex-encoded)
--   1-0:1.7.0(0003.222*kW)   ← import power
--   1-0:21.7.0(0001.100*kW)  ← L1 import power
--   ...
--   !CRC\r\n                  ← end marker + CRC16

PROTOCOL = "serial"
DRIVER_NAME = "P1 DSMR"

----------------------------------------------------------------------------
-- OBIS code table — maps "C.D.E" to field names
----------------------------------------------------------------------------

local OBIS = {
    -- Instantaneous active power (kW)
    ["1.7.0"]  = "import_kw",
    ["2.7.0"]  = "export_kw",
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
    -- Frequency
    ["14.7.0"] = "hz",
    -- Equipment identifier (meter serial number)
    ["96.1.0"] = "equipment_id",
    ["96.1.1"] = "equipment_id",
}

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

local function n(v)
    if v == nil then return 0 end
    return tonumber(v) or 0
end

----------------------------------------------------------------------------
-- DSMR ASCII parser
----------------------------------------------------------------------------

local function parse_telegram(telegram)
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
-- Emit meter telemetry
----------------------------------------------------------------------------

local sn_set = false

local function emit_meter(values)
    -- Set meter serial from equipment_id on first telegram
    if not sn_set and values.equipment_id then
        local sn = tostring(values.equipment_id)
        if string.len(sn) > 0 then
            host.set_sn(sn)
            sn_set = true
        end
    end

    -- Power: DSMR uses kW, convert to W
    local iw = n(values.import_kw) * 1000
    local ew = n(values.export_kw) * 1000

    -- Per-phase power
    local l1w = (n(values.l1_import_kw) - n(values.l1_export_kw)) * 1000
    local l2w = (n(values.l2_import_kw) - n(values.l2_export_kw)) * 1000
    local l3w = (n(values.l3_import_kw) - n(values.l3_export_kw)) * 1000

    -- Energy counters
    local imp_wh = 0
    if values.total_import_kwh then
        imp_wh = n(values.total_import_kwh) * 1000
    else
        imp_wh = (n(values.import_t1_kwh) + n(values.import_t2_kwh)
                + n(values.import_t3_kwh) + n(values.import_t4_kwh)) * 1000
    end

    local exp_wh = 0
    if values.total_export_kwh then
        exp_wh = n(values.total_export_kwh) * 1000
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

local chunks = {}
local chunk_len = 0

function driver_init(config)
    host.set_make("P1 DSMR")
    chunks = {}
    chunk_len = 0
end

function driver_poll()
    local ok, data = pcall(host.serial_read, 256, 500)
    if ok and data and string.len(data) > 0 then
        chunks[#chunks + 1] = data
        chunk_len = chunk_len + string.len(data)
    end

    -- Only concat when we have enough data for a potential frame
    if chunk_len < 50 then return 200 end

    local serial_buf = table.concat(chunks)
    chunks = {}
    chunk_len = 0

    -- Look for complete DSMR telegram: "/" start ... "!" end + CRC + newline
    local s = string.find(serial_buf, "/", 1, true)
    if not s then
        -- No start marker — discard
        return 200
    end

    local e = string.find(serial_buf, "!", s, true)
    if not e then
        -- Start found but no end yet — keep leftover from start marker
        chunks[1] = string.sub(serial_buf, s)
        chunk_len = string.len(chunks[1])
        return 200
    end

    local nl = string.find(serial_buf, "\n", e, true)
    if not nl then
        chunks[1] = serial_buf
        chunk_len = string.len(serial_buf)
        return 200
    end

    -- Extract complete telegram
    local telegram = string.sub(serial_buf, s, nl)
    -- Keep any leftover after the telegram
    local leftover = string.sub(serial_buf, nl + 1)
    if string.len(leftover) > 0 then
        chunks[1] = leftover
        chunk_len = string.len(leftover)
    end

    -- Parse and emit
    local values = parse_telegram(telegram)
    if values then
        emit_meter(values)
    end

    return 200
end

function driver_cleanup()
    chunks = {}
    chunk_len = 0
end
