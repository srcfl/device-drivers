-- Hoymiles via OpenDTU HTTP Driver (community, untested)
-- Emits: PV, Meter
-- REST API on port 80
-- Reads /api/livedata/status and sums all inverters
-- Sign convention: PV W is negative (generation)

PROTOCOL = "http"

-- Module state
local base_url = nil

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

-- HTTP GET + JSON decode with error handling
local function http_get_json(path)
    local ok, body = pcall(host.http_get, base_url .. path)
    if not ok or not body then return nil end
    local ok2, data = pcall(host.json_decode, body)
    if not ok2 or not data then return nil end
    return data
end

-- Safely extract a nested value field from OpenDTU's {v: value, u: unit, d: digits} objects
local function field_val(obj, key)
    if not obj then return 0 end
    local field = obj[key]
    if not field then return 0 end
    if type(field) == "table" and field.v ~= nil then
        return tonumber(field.v) or 0
    end
    return tonumber(field) or 0
end

----------------------------------------------------------------------------
-- Driver interface
----------------------------------------------------------------------------

function driver_init(config)
    local port = config.port or 80
    base_url = "http://" .. config.host .. ":" .. port
    host.set_make("Hoymiles")
end

function driver_poll()
    local data = http_get_json("/api/livedata/status")
    if not data or not data.inverters then return 5000 end

    local total_ac_w = 0
    local total_dc_w = 0
    local total_yield_wh = 0
    local ac_voltage = 0
    local ac_frequency = 0
    local ac_current = 0
    local inverter_count = 0

    for _, inv in ipairs(data.inverters) do
        if inv.reachable then
            inverter_count = inverter_count + 1

            -- AC values
            if inv.AC then
                -- OpenDTU AC structure: AC["0"] has Power, Voltage, Current, Frequency
                local ac = inv.AC["0"] or inv.AC[0]
                if ac then
                    local ac_p = field_val(ac, "Power")
                    local ac_v = field_val(ac, "Voltage")
                    local ac_a = field_val(ac, "Current")
                    local ac_f = field_val(ac, "Frequency")

                    total_ac_w = total_ac_w + ac_p
                    if ac_v > 0 then ac_voltage = ac_v end
                    if ac_f > 0 then ac_frequency = ac_f end
                    ac_current = ac_current + ac_a
                end
            end

            -- DC values: sum all MPPT channels
            if inv.DC then
                -- DC channels can be keyed as "0", "1", etc.
                for k, ch in pairs(inv.DC) do
                    if type(ch) == "table" then
                        local dc_p = field_val(ch, "Power")
                        total_dc_w = total_dc_w + dc_p
                    end
                end
            end

            -- Yield total (kWh -> Wh)
            if inv.INV then
                local inv_data = inv.INV["0"] or inv.INV[0]
                if inv_data then
                    local yield_kwh = field_val(inv_data, "YieldTotal")
                    total_yield_wh = total_yield_wh + (yield_kwh * 1000)
                end
            end
        end
    end

    -- Emit PV telemetry (negative for generation)
    host.emit("pv", {
        w           = -total_dc_w,
        lifetime_wh = total_yield_wh,
    })

    -- Emit Meter telemetry (AC output)
    host.emit("meter", {
        w    = total_ac_w,
        l1_v = ac_voltage,
        l1_a = ac_current,
        hz   = ac_frequency,
    })

    return 5000
end

function driver_cleanup()
    base_url = nil
end
