-- go-e Charger HTTP Driver (community, untested)
-- Emits: V2X Charger
-- HTTP API v2, port 80
-- Endpoint: GET /api/status
-- Returns JSON with:
--   nrg: array [V_L1, V_L2, V_L3, V_N, A_L1, A_L2, A_L3, W_L1, W_L2, W_L3, W_N, W_total, PF_L1, PF_L2, PF_L3, PF_N]
--   wh:  session energy in Wh
--   car: 1=ready, 2=charging, 3=waiting, 4=complete
--   amp: max current in A
-- Note: HTTP alternative to the Modbus go-e driver

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

-- Safe array access: Lua arrays are 1-based
local function nrg_val(nrg, index)
    if not nrg then return 0 end
    -- API nrg array is 0-indexed, Lua tables are 1-indexed
    local val = nrg[index + 1]
    return tonumber(val) or 0
end

-- Map go-e car state to standard numeric: 0=idle, 1=connected, 2=charging, 3=error
local function map_state(car)
    if car == 1 then
        return 0      -- ready (no vehicle) -> idle
    elseif car == 2 then
        return 2      -- charging -> charging
    elseif car == 3 then
        return 1      -- waiting -> connected
    elseif car == 4 then
        return 0      -- complete -> idle
    else
        return 0
    end
end

----------------------------------------------------------------------------
-- Driver interface
----------------------------------------------------------------------------

function driver_init(config)
    local port = config.port or 80
    base_url = "http://" .. config.host .. ":" .. port
    host.set_make("go-e")
end

function driver_poll()
    local data = http_get_json("/api/status")
    if not data then return 5000 end

    local nrg = data.nrg
    local session_wh = tonumber(data.wh) or 0
    local car = tonumber(data.car) or 0
    local max_a = tonumber(data.amp) or 0

    -- Extract values from nrg array
    -- Indices: 0=V_L1, 1=V_L2, 2=V_L3, 3=V_N
    --          4=A_L1, 5=A_L2, 6=A_L3
    --          7=W_L1, 8=W_L2, 9=W_L3, 10=W_N, 11=W_total
    --          12=PF_L1, 13=PF_L2, 14=PF_L3, 15=PF_N
    local l1_v = nrg_val(nrg, 0)
    local l2_v = nrg_val(nrg, 1)
    local l3_v = nrg_val(nrg, 2)

    local l1_a = nrg_val(nrg, 4)
    local l2_a = nrg_val(nrg, 5)
    local l3_a = nrg_val(nrg, 6)

    local l1_w = nrg_val(nrg, 7)
    local l2_w = nrg_val(nrg, 8)
    local l3_w = nrg_val(nrg, 9)
    local power_w = nrg_val(nrg, 11)

    local state = map_state(car)

    -- Emit V2X charger telemetry
    host.emit("v2x_charger", {
        w                = power_w,
        session_charge_wh = session_wh,
        l1_v             = l1_v,
        l2_v             = l2_v,
        l3_v             = l3_v,
        l1_a             = l1_a,
        l2_a             = l2_a,
        l3_a             = l3_a,
        l1_w             = l1_w,
        l2_w             = l2_w,
        l3_w             = l3_w,
    })

    return 5000
end

function driver_cleanup()
    base_url = nil
end
