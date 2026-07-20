-- HardyBarth cPH/Salia EV Charger HTTP Driver (community, untested)
-- Emits: V2X Charger
-- HTTP REST API, port 80
-- Endpoint: GET /api/status
-- Returns JSON with power, energy, current, voltage, state

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

-- Map HardyBarth state strings to standard numeric: 0=idle, 1=connected, 2=charging, 3=error
local function map_state(raw_state)
    if not raw_state then return 0 end
    local s = string.lower(tostring(raw_state))
    if s == "charging" then
        return 2
    elseif s == "connected" or s == "waiting" or s == "ready" then
        return 1
    elseif s == "error" or s == "fault" then
        return 3
    else
        return 0   -- idle, disconnected, unknown -> idle
    end
end

----------------------------------------------------------------------------
-- Driver interface
----------------------------------------------------------------------------

function driver_init(config)
    local port = config.port or 80
    base_url = "http://" .. config.host .. ":" .. port
    host.set_make("HardyBarth")
end

function driver_poll()
    local data = http_get_json("/api/status")
    if not data then return 5000 end

    local power_w = tonumber(data.power) or 0
    local energy_wh = tonumber(data.energy) or 0
    local current_a = tonumber(data.current) or 0
    local voltage_v = tonumber(data.voltage) or 0
    local state = map_state(data.state)

    -- Emit V2X charger telemetry
    host.emit("v2x_charger", {
        w                = power_w,
        session_charge_wh = energy_wh,
        l1_a             = current_a,
        l1_v             = voltage_v,
    })

    return 5000
end

function driver_cleanup()
    base_url = nil
end
