-- hello.lua — Phase 0 hello-world Lua driver
--
-- Demonstrates the driver contract and host API.
-- This driver emits a test meter metric every 5 seconds.
--
-- Driver contract (compatible with both Blaxt and Zap):
--   driver_init(config)   — called once at startup
--   driver_poll()         — called periodically, returns interval_ms
--   driver_cleanup()      — called on shutdown

PROTOCOL = "standalone"

local poll_count = 0
local config = {}

function driver_init(cfg)
    config = cfg or {}
    host.log("Hello driver initialized!")
    host.log("  SN: " .. tostring(config.sn or "unknown"))
    host.log("  Gateway: " .. tostring(config.gateway_serial or "unknown"))
    host.log("  Uptime: " .. tostring(host.millis()) .. " ms")
end

function driver_poll()
    poll_count = poll_count + 1

    -- Emit a test meter reading
    local ok = host.emit("meter", {
        W = 42.0 + poll_count,
        Hz = 50.0,
        L1_V = 230.0,
    })

    if ok then
        host.log("Poll #" .. tostring(poll_count) .. ": emitted meter W=" .. tostring(42.0 + poll_count))
    else
        host.log("Poll #" .. tostring(poll_count) .. ": emit failed")
    end

    -- Return poll interval in milliseconds (5 seconds)
    return 5000
end

function driver_cleanup()
    host.log("Hello driver shutting down after " .. tostring(poll_count) .. " polls")
end
