-- Fronius Solar API HTTP Driver (community, untested)
-- Emits: PV, Meter
-- REST API on port 80
-- Uses GetPowerFlowRealtimeData for site-level data
-- Sign convention:
--   PV W: negative (generation)
--   Meter W: positive = import from grid (P_Grid positive = import)

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
    local port = config.port or 80
    base_url = "http://" .. config.host .. ":" .. port
    host.set_make("Fronius")
end

function driver_poll()
    -- Get power flow data
    local data = http_get_json("/solar_api/v1/GetPowerFlowRealtimeData.fcgi")
    if not data then return 5000 end

    local site = nil
    if data.Body and data.Body.Data and data.Body.Data.Site then
        site = data.Body.Data.Site
    end

    if not site then return 5000 end

    -- PV power: P_PV (W, always positive from Fronius, nil when no production)
    local pv_w = site.P_PV or 0

    -- Total PV energy: E_Total (Wh, cumulative)
    local pv_total_wh = site.E_Total or 0

    -- Emit PV telemetry (negative for generation)
    host.emit("pv", {
        w           = -pv_w,
        lifetime_wh = pv_total_wh,
    })

    -- Grid power: P_Grid (W, positive = import, negative = export)
    local grid_w = site.P_Grid or 0

    -- Emit Meter telemetry
    host.emit("meter", {
        w = grid_w,
    })

    return 5000
end

function driver_cleanup()
    base_url = nil
end
