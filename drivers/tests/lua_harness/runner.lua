-- runner.lua -- Test runner for individual Lua drivers
--
-- Usage: lua runner.lua <driver_file>
-- Output: JSON to stdout with test results
--
-- Loads host_mock.lua, executes a driver through its full lifecycle
-- (init -> poll -> cleanup), and reports results.

-- Determine our own directory for locating host_mock.lua
local script_dir = arg[0]:match("(.*/)")
if not script_dir then script_dir = "./" end

-- Load the host mock
dofile(script_dir .. "host_mock.lua")

---------------------------------------------------------------------------
-- Argument parsing
---------------------------------------------------------------------------

local driver_file = arg[1]
if not driver_file then
    io.stderr:write("Usage: lua runner.lua <driver_file> [mock_data_file]\n")
    os.exit(1)
end

-- Optional: load external mock data setup
local mock_data_file = arg[2]

-- Extract driver name from filename
local driver_name = driver_file:match("([^/]+)%.lua$") or driver_file

---------------------------------------------------------------------------
-- Mock data setup helpers
---------------------------------------------------------------------------

-- Fill modbus registers with generic default values across a wide range.
-- This gives every driver something reasonable to read.
local function setup_default_modbus_data()
    local holding = {}
    local input   = {}

    -- Fill a large range with sensible defaults
    -- U16 default value = 2300 (230V at 0.1V scale, or a reasonable power value)
    -- This covers voltage, power, current, etc. registers
    for addr = 0, 65535 do
        -- Vary the default value based on address range to give some diversity
        -- Low addresses (0-999): charger/simple devices
        -- 1000-9999: general inverter
        -- 10000-19999: status/energy
        -- 20000-39999: rated/config
        -- 40000+: SunSpec
        local val = 2300  -- default: 230V at 0.1 scale
        local mod = addr % 20
        if mod < 5 then
            val = 2300     -- ~230V at 0.1V scale
        elseif mod < 8 then
            val = 50       -- ~5A at 0.01A scale, or 50% SoC
        elseif mod < 11 then
            val = 1000     -- ~1000W
        elseif mod < 14 then
            val = 5000     -- ~50Hz at 0.01Hz scale, or 5000Wh
        elseif mod < 17 then
            val = 100      -- energy/counters
        else
            val = 250      -- temperature (25.0C at 0.1 scale)
        end
        holding[addr] = val
        input[addr]   = val
    end

    host._modbus_registers.holding = holding
    host._modbus_registers.input   = input
end

-- Provide HTTP responses based on the driver being tested.
-- Drivers that share the same endpoint URL (e.g., goe_http and hardybarth both
-- use /api/status) are disambiguated by driver name.
local function setup_default_http_data(driver_name)
    -- Always provide Shelly endpoints (used by shelly driver)
    host._http_responses["http://127.0.0.1:80/rpc/Shelly.GetDeviceInfo"] =
        '{"id":"shellyem3-test","mac":"AABBCCDDEEFF","model":"SHEM-3","gen":2,"fw_id":"20231107","app":"Pro3EM","ver":"1.0.0"}'
    host._http_responses["http://127.0.0.1:80/rpc/EM.GetStatus?id=0"] =
        '{"id":0,"a_act_power":1500.0,"a_aprt_power":1600.0,"a_current":6.5,"a_voltage":230.1,"a_freq":50.01,' ..
        '"b_act_power":800.0,"b_aprt_power":850.0,"b_current":3.5,"b_voltage":229.8,' ..
        '"c_act_power":-200.0,"c_aprt_power":250.0,"c_current":1.1,"c_voltage":230.5,' ..
        '"a_aenergy":{"total":150000},"b_aenergy":{"total":80000},"c_aenergy":{"total":10000},' ..
        '"a_ret_aenergy":{"total":5000},"b_ret_aenergy":{"total":2000},"c_ret_aenergy":{"total":50000}}'
    host._http_responses["http://127.0.0.1:80/rpc/EM1.GetStatus?id=0"] =
        '{"id":0,"act_power":1200.0,"current":5.2,"voltage":230.0,"freq":50.0,' ..
        '"aenergy":{"total":100000},"ret_aenergy":{"total":5000}}'
    host._http_responses["http://127.0.0.1:80/rpc/EM1.GetStatus?id=1"] =
        '{"id":1,"act_power":800.0,"current":3.5,"voltage":229.5,"freq":50.0,' ..
        '"aenergy":{"total":60000},"ret_aenergy":{"total":3000}}'
    host._http_responses["http://127.0.0.1:80/rpc/PM1.GetStatus?id=0"] =
        '{"id":0,"apower":500.0,"current":2.2,"voltage":230.0,"freq":50.0,' ..
        '"aenergy":{"total":50000},"ret_aenergy":{"total":1000}}'
    host._http_responses["http://127.0.0.1:80/rpc/Switch.GetStatus?id=0"] =
        '{"id":0,"apower":350.0,"current":1.5,"voltage":230.0,"freq":50.0,' ..
        '"aenergy":{"total":30000},"ret_aenergy":{"total":500},"output":true}'

    -- Fronius API
    host._http_responses["http://127.0.0.1:80/solar_api/v1/GetPowerFlowRealtimeData.fcgi"] =
        '{"Body":{"Data":{"Site":{"P_PV":5000,"P_Grid":-1200,"P_Load":-3800,"E_Total":15000000}}}}'

    -- OpenDTU API
    host._http_responses["http://127.0.0.1:80/api/livedata/status"] =
        '{"inverters":[{"serial":"1234","reachable":true,' ..
        '"AC":{"0":{"Power":{"v":4500},"Voltage":{"v":230},"Current":{"v":19.5},"Frequency":{"v":50.01}}},' ..
        '"DC":{"0":{"Power":{"v":2500},"Voltage":{"v":35},"Current":{"v":71.4}},"1":{"Power":{"v":2200},"Voltage":{"v":34},"Current":{"v":64.7}}},' ..
        '"INV":{"0":{"YieldTotal":{"v":12500}}}}]}'

    -- Sonnen API
    host._http_responses["http://127.0.0.1:8080/api/v2/status"] =
        '{"Pac_total_W":1500,"USOC":75,"GridFeedIn_W":-800,"Consumption_W":3000,"Production_W":5000,"Uac":230,"Fac":50.0}'

    -- OpenEVSE
    host._http_responses["http://127.0.0.1:80/status"] =
        '{"amp":16,"voltage":230,"state":3,"watt_seconds":7200000,"pilot":32,"temp1":350}'

    -- Zaptec
    host._http_responses["http://127.0.0.1:80/api/charger/state"] =
        '{"ChargingPower":7200,"TotalChargingEnergy":3500,"ChargingCurrent":31.3,"Voltage":230,"ChargerState":"charging"}'

    -- /api/status is shared by goe_http and hardybarth -- pick based on driver name
    if driver_name == "goe_http" then
        host._http_responses["http://127.0.0.1:80/api/status"] =
            '{"nrg":[230,229,231,0,5.2,4.8,5.0,1196,1099,1155,0,3450,0.98,0.97,0.99,0],"wh":5000,"car":2,"amp":16}'
    else
        -- Default: hardybarth-style response (also works for generic testing)
        host._http_responses["http://127.0.0.1:80/api/status"] =
            '{"power":3500,"energy":2500,"current":15.2,"voltage":230,"state":"charging"}'
    end
end

-- Provide generic MQTT messages for MQTT drivers
local function setup_default_mqtt_data(protocol_hint)
    -- Ferroamp EnergyHub
    host._mqtt_buffer = {}

    -- Add Ferroamp messages
    table.insert(host._mqtt_buffer, {
        topic = "extapi/data/ehub",
        payload = '{"pext":{"val":[1500,800,-200]},"ppv":{"val":[3000,2000]},' ..
                  '"pbat":{"val":[-500]},"gridfreq":{"val":50.01},' ..
                  '"ul":{"val":[230.1,229.8,230.5]},"il":{"val":[6.5,3.5,1.1]},' ..
                  '"wextconsq":{"val":150},"wextprodq":{"val":50}}'
    })
    table.insert(host._mqtt_buffer, {
        topic = "extapi/data/eso",
        payload = '{"soc":{"val":75}}'
    })
    table.insert(host._mqtt_buffer, {
        topic = "extapi/data/sso",
        payload = '{"ppv":{"val":5000}}'
    })

    -- Ambibox V2X messages
    table.insert(host._mqtt_buffer, {
        topic = "device/evCharger/0/powerAc",
        payload = "3500"
    })
    table.insert(host._mqtt_buffer, {
        topic = "device/evCharger/0/currentAc",
        payload = "15.2"
    })
    table.insert(host._mqtt_buffer, {
        topic = "device/evCharger/0/voltageAc",
        payload = "230"
    })
    table.insert(host._mqtt_buffer, {
        topic = "device/evCharger/0/frequency",
        payload = "50.0"
    })
    table.insert(host._mqtt_buffer, {
        topic = "device/evCharger/0/powerDc",
        payload = "3200"
    })
    table.insert(host._mqtt_buffer, {
        topic = "device/evCharger/0/currentDc",
        payload = "10"
    })
    table.insert(host._mqtt_buffer, {
        topic = "device/evCharger/0/voltageDc",
        payload = "320"
    })
    table.insert(host._mqtt_buffer, {
        topic = "device/evCharger/0/soc",
        payload = "65"
    })
    table.insert(host._mqtt_buffer, {
        topic = "device/evCharger/0/currentAc1",
        payload = "5.1"
    })
    table.insert(host._mqtt_buffer, {
        topic = "device/evCharger/0/currentAc2",
        payload = "5.0"
    })
    table.insert(host._mqtt_buffer, {
        topic = "device/evCharger/0/currentAc3",
        payload = "5.1"
    })
    table.insert(host._mqtt_buffer, {
        topic = "device/evCharger/0/voltageAc1",
        payload = "230"
    })
    table.insert(host._mqtt_buffer, {
        topic = "device/evCharger/0/voltageAc2",
        payload = "229"
    })
    table.insert(host._mqtt_buffer, {
        topic = "device/evCharger/0/voltageAc3",
        payload = "231"
    })
    table.insert(host._mqtt_buffer, {
        topic = "device/evCharger/0/energyAcImport",
        payload = "50000"
    })
    table.insert(host._mqtt_buffer, {
        topic = "device/evCharger/0/energyAcExport",
        payload = "10000"
    })
    table.insert(host._mqtt_buffer, {
        topic = "device/evCharger/0/evConnected",
        payload = "true"
    })

    -- Victron MQTT
    table.insert(host._mqtt_buffer, {
        topic = "N/abc123/system/0/Ac/Grid/L1/Power",
        payload = '{"value": 1500}'
    })
    table.insert(host._mqtt_buffer, {
        topic = "N/abc123/system/0/Ac/Grid/L2/Power",
        payload = '{"value": 800}'
    })
    table.insert(host._mqtt_buffer, {
        topic = "N/abc123/system/0/Ac/Grid/L3/Power",
        payload = '{"value": -200}'
    })
    table.insert(host._mqtt_buffer, {
        topic = "N/abc123/system/0/Ac/PvOnOutput/L1/Power",
        payload = '{"value": 2000}'
    })
    table.insert(host._mqtt_buffer, {
        topic = "N/abc123/system/0/Ac/PvOnOutput/L2/Power",
        payload = '{"value": 1500}'
    })
    table.insert(host._mqtt_buffer, {
        topic = "N/abc123/system/0/Ac/PvOnOutput/L3/Power",
        payload = '{"value": 1000}'
    })
    table.insert(host._mqtt_buffer, {
        topic = "N/abc123/system/0/Dc/Pv/Power",
        payload = '{"value": 500}'
    })
    table.insert(host._mqtt_buffer, {
        topic = "N/abc123/system/0/Dc/Battery/Power",
        payload = '{"value": 1000}'
    })
    table.insert(host._mqtt_buffer, {
        topic = "N/abc123/system/0/Dc/Battery/Soc",
        payload = '{"value": 80}'
    })
    table.insert(host._mqtt_buffer, {
        topic = "N/abc123/system/0/Dc/Battery/Voltage",
        payload = '{"value": 48.5}'
    })
    table.insert(host._mqtt_buffer, {
        topic = "N/abc123/system/0/Dc/Battery/Current",
        payload = '{"value": 20.6}'
    })
    table.insert(host._mqtt_buffer, {
        topic = "N/abc123/system/0/Dc/Battery/Temperature",
        payload = '{"value": 28}'
    })

    -- OpenDTU MQTT
    table.insert(host._mqtt_buffer, {
        topic = "solar/inv001/status/AC/Power",
        payload = "4500"
    })
    table.insert(host._mqtt_buffer, {
        topic = "solar/inv001/status/AC/Voltage",
        payload = "230"
    })
    table.insert(host._mqtt_buffer, {
        topic = "solar/inv001/status/AC/Current",
        payload = "19.5"
    })
    table.insert(host._mqtt_buffer, {
        topic = "solar/inv001/status/AC/Frequency",
        payload = "50.01"
    })
    table.insert(host._mqtt_buffer, {
        topic = "solar/inv001/status/DC/0/Power",
        payload = "2500"
    })
    table.insert(host._mqtt_buffer, {
        topic = "solar/inv001/status/DC/0/Voltage",
        payload = "35"
    })
    table.insert(host._mqtt_buffer, {
        topic = "solar/inv001/status/DC/0/Current",
        payload = "71.4"
    })
    table.insert(host._mqtt_buffer, {
        topic = "solar/inv001/status/DC/1/Power",
        payload = "2200"
    })
    table.insert(host._mqtt_buffer, {
        topic = "solar/inv001/status/INV/YieldTotal",
        payload = "12500"
    })
end

-- Provide generic P1 telegram data
local function setup_default_p1_data()
    host._p1_data = {
        import_w        = 1.5,     -- 1.5 kW import
        export_w        = 0,       -- 0 kW export
        l1_import_w     = 0.8,
        l1_export_w     = 0,
        l2_import_w     = 0.5,
        l2_export_w     = 0,
        l3_import_w     = 0.2,
        l3_export_w     = 0,
        total_import_t1 = 5000,    -- kWh
        total_import_t2 = 3000,    -- kWh
        total_export_t1 = 1000,    -- kWh
        total_export_t2 = 500,     -- kWh
        l1_v            = 230.1,
        l2_v            = 229.8,
        l3_v            = 230.5,
        l1_a            = 3.5,
        l2_a            = 2.2,
        l3_a            = 0.9,
    }
end

---------------------------------------------------------------------------
-- Driver execution
---------------------------------------------------------------------------

local result = {
    driver         = driver_name,
    protocol       = "unknown",
    make           = nil,
    init_ok        = false,
    poll_ok        = false,
    poll_interval_ms = nil,
    cleanup_ok     = false,
    emitted        = {},
    host_calls     = 0,
    logs           = {},
    errors         = {},
}

-- Set up all mock data
setup_default_modbus_data()
setup_default_http_data(driver_name)
setup_default_mqtt_data()
setup_default_p1_data()

-- Load external mock data if provided
if mock_data_file then
    local ok, err = pcall(dofile, mock_data_file)
    if not ok then
        table.insert(result.errors, "Failed to load mock data: " .. tostring(err))
    end
end

-- Load the driver
local ok, err = pcall(dofile, driver_file)
if not ok then
    table.insert(result.errors, "Failed to load driver: " .. tostring(err))
    io.write(host.json_encode(result) .. "\n")
    os.exit(1)
end

-- Read PROTOCOL global
if PROTOCOL then
    result.protocol = PROTOCOL
end

-- Build test config
local config = {
    sn             = "TEST-001",
    type           = "lua",
    profile        = driver_name,
    host           = "127.0.0.1",
    port           = 502,
    unit_id        = 1,
    serial_port    = "/dev/ttyUSB0",
    baud_rate      = 9600,
    gateway_serial = "GW-TEST-001",
    ders           = {},
}

-- Adjust port for HTTP drivers
if result.protocol == "http" then
    config.port = 80
    -- Special port for sonnen
    if driver_name == "sonnen" then
        config.port = 8080
    end
end

-- Run driver_init
if type(driver_init) == "function" then
    local init_ok, init_err = pcall(driver_init, config)
    if init_ok then
        result.init_ok = true
    else
        table.insert(result.errors, "driver_init failed: " .. tostring(init_err))
    end
else
    table.insert(result.errors, "driver_init not defined")
end

-- For MQTT drivers, re-inject messages before poll since init may have drained them
if result.protocol == "mqtt" then
    setup_default_mqtt_data()
end

-- Run driver_poll
if type(driver_poll) == "function" then
    local poll_ok, poll_result = pcall(driver_poll)
    if poll_ok then
        result.poll_ok = true
        if type(poll_result) == "number" then
            result.poll_interval_ms = poll_result
        end
    else
        table.insert(result.errors, "driver_poll failed: " .. tostring(poll_result))
    end
else
    table.insert(result.errors, "driver_poll not defined")
end

-- Run driver_cleanup
if type(driver_cleanup) == "function" then
    local cleanup_ok, cleanup_err = pcall(driver_cleanup)
    if cleanup_ok then
        result.cleanup_ok = true
    else
        table.insert(result.errors, "driver_cleanup failed: " .. tostring(cleanup_err))
    end
else
    -- driver_cleanup is optional
    result.cleanup_ok = true
end

-- Collect results
result.make       = host._make
result.emitted    = host._emitted
result.host_calls = #host._calls
result.logs       = host._logs

-- Merge any errors from host
for _, e in ipairs(host._errors) do
    table.insert(result.errors, e)
end

-- Output JSON
io.write(host.json_encode(result) .. "\n")
