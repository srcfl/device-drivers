-- Sonnen Battery HTTP Driver (community, untested)
-- Emits: Battery, Meter
-- REST API v2 on port 8080
-- Sign convention:
--   Battery W: positive = charging (Pac_total_W positive), negative = discharging
--   Meter W: positive = import (GridFeedIn_W negative = import from grid)

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

----------------------------------------------------------------------------
-- Driver interface
----------------------------------------------------------------------------

function driver_init(config)
    local port = config.port or 8080
    base_url = "http://" .. config.host .. ":" .. port
    host.set_make("Sonnen")
end

function driver_poll()
    local data = http_get_json("/api/v2/status")
    if not data then return 5000 end

    -- Battery telemetry
    -- Pac_total_W: positive = charging, negative = discharging (matches convention)
    local bat_w = data.Pac_total_W or 0
    local bat_soc = (data.USOC or 0) / 100  -- percent to fraction

    host.emit("battery", {
        W   = bat_w,
        SoC_nom_fract = bat_soc,
    })

    -- Meter telemetry
    -- GridFeedIn_W: positive = export to grid, negative = import from grid
    -- Our convention: positive = import, so negate
    local grid_w = -(data.GridFeedIn_W or 0)
    local consumption_w = data.Consumption_W or 0
    local production_w = data.Production_W or 0
    local voltage = data.Uac or 0
    local frequency = data.Fac or 0

    host.emit("meter", {
        W    = grid_w,
        L1_V = voltage,
        Hz   = frequency,
    })

    return 5000
end

function driver_cleanup()
    base_url = nil
end
