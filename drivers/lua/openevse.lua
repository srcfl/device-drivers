-- OpenEVSE HTTP Driver (community, untested)
-- Emits: V2X Charger
-- REST API on port 80
-- Reads /status endpoint for charger state and measurements

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
    host.set_make("OpenEVSE")
end

function driver_poll()
    local data = http_get_json("/status")
    if not data then return 5000 end

    -- Current: amp (A)
    local current_a = data.amp or 0

    -- Voltage: voltage (V)
    local voltage_v = data.voltage or 0

    -- Power: compute from V * A (OpenEVSE doesn't always report power directly)
    local power_w = voltage_v * current_a

    -- Max current: pilot (A)
    local max_a = data.pilot or 0

    -- Session energy: watt_seconds (Ws -> Wh)
    local session_wh = (data.watt_seconds or 0) / 3600

    -- State: 1=not connected, 2=connected, 3=charging, 4=vent required, 5=error
    local raw_state = data.state or 1
    local state = 0
    -- Map OpenEVSE states to standard: 0=idle, 1=connected, 2=charging, 3=error
    if raw_state == 1 then
        state = 0      -- not connected -> idle
    elseif raw_state == 2 then
        state = 1      -- connected -> connected
    elseif raw_state == 3 then
        state = 2      -- charging -> charging
    elseif raw_state == 4 then
        state = 3      -- vent required -> error
    elseif raw_state == 5 then
        state = 3      -- error -> error
    end

    -- Emit V2X charger telemetry
    host.emit("v2x_charger", {
        w                = power_w,
        session_charge_wh = session_wh,
        l1_v             = voltage_v,
        l1_a             = current_a,
    })

    return 5000
end

function driver_cleanup()
    base_url = nil
end
