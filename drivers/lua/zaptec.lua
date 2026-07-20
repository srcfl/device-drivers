-- Zaptec EV Charger HTTP Driver (community, untested)
-- Emits: V2X Charger
-- HTTP REST API, port 80
-- Endpoint: GET /api/charger/state
-- Returns JSON with ChargingPower, TotalChargingEnergy, ChargingCurrent,
--   Voltage, ChargerState

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

-- Map Zaptec state strings to standard numeric: 0=idle, 1=connected, 2=charging, 3=error
local function map_state(charger_state)
    if not charger_state then return 0 end
    local s = string.lower(tostring(charger_state))
    if s == "charging" then
        return 2
    elseif s == "connected" or s == "waiting" or s == "ready" then
        return 1
    elseif s == "error" or s == "fault" then
        return 3
    else
        return 0   -- disconnected, completed, unknown -> idle
    end
end

----------------------------------------------------------------------------
-- Driver interface
----------------------------------------------------------------------------

function driver_init(config)
    local port = config.port or 80
    base_url = "http://" .. config.host .. ":" .. port
    host.set_make("Zaptec")
end

function driver_poll()
    local data = http_get_json("/api/charger/state")
    if not data then return 5000 end

    local power_w = tonumber(data.ChargingPower) or 0
    local session_wh = tonumber(data.TotalChargingEnergy) or 0
    local current_a = tonumber(data.ChargingCurrent) or 0
    local voltage_v = tonumber(data.Voltage) or 0
    local state = map_state(data.ChargerState)

    -- Emit V2X charger telemetry
    host.emit("v2x_charger", {
        w                = power_w,
        session_charge_wh = session_wh,
        l1_a             = current_a,
        l1_v             = voltage_v,
    })

    return 5000
end

function driver_cleanup()
    base_url = nil
end
