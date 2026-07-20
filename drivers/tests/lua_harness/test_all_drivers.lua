-- test_all_drivers.lua -- Comprehensive test for all 53 Lua drivers
--
-- Usage: lua test_all_drivers.lua [drivers_dir]
-- Default drivers_dir: ../../lua (relative to this script)
--
-- For each driver:
--   1. Sets up appropriate mock data based on protocol
--   2. Runs init -> poll -> cleanup
--   3. Verifies expected DER types are emitted
--   4. Verifies sign conventions and value ranges
--   5. Prints PASS/FAIL per driver

-- Determine our own directory
local script_dir = arg[0]:match("(.*/)")
if not script_dir then script_dir = "./" end

-- Load the host mock
dofile(script_dir .. "host_mock.lua")

---------------------------------------------------------------------------
-- Configuration
---------------------------------------------------------------------------

local drivers_dir = arg[1] or (script_dir .. "../../lua")

-- Driver metadata: protocol, expected DER types, and any special config
local DRIVER_SPECS = {
    -- Modbus inverters (PV + Battery + Meter)
    goodwe           = { protocol = "modbus", ders = {"pv", "battery", "meter"} },
    sungrow          = { protocol = "modbus", ders = {"pv", "battery", "meter"} },
    fronius          = { protocol = "modbus", ders = {"pv", "battery", "meter"} },
    huawei           = { protocol = "modbus", ders = {"pv", "battery", "meter"} },
    deye             = { protocol = "modbus", ders = {"pv", "battery", "meter"} },
    solis            = { protocol = "modbus", ders = {"pv", "battery", "meter"} },
    sofar            = { protocol = "modbus", ders = {"pv", "battery", "meter"} },
    growatt          = { protocol = "modbus", ders = {"pv", "battery", "meter"} },
    solax            = { protocol = "modbus", ders = {"pv", "battery", "meter"} },
    foxess           = { protocol = "modbus", ders = {"pv", "battery", "meter"} },
    kostal           = { protocol = "modbus", ders = {"pv", "battery", "meter"} },
    kstar            = { protocol = "modbus", ders = {"pv", "battery", "meter"} },
    alphaess         = { protocol = "modbus", ders = {"pv", "battery", "meter"} },
    saj              = { protocol = "modbus", ders = {"pv", "battery", "meter"} },

    -- Modbus PV + Battery + Meter
    sma              = { protocol = "modbus", ders = {"pv", "battery", "meter"} },
    victron          = { protocol = "modbus", ders = {"pv", "battery", "meter"} },

    -- Modbus inverters (PV + Meter)
    solaredge        = { protocol = "modbus", ders = {"pv", "meter"} },

    -- Modbus battery + meter only (no PV)
    pixii            = { protocol = "modbus", ders = {"battery", "meter"} },
    varta            = { protocol = "modbus", ders = {"battery", "meter"} },

    -- Modbus meters only
    fronius_smart_meter = { protocol = "modbus", ders = {"meter"} },
    sdm630           = { protocol = "modbus", ders = {"meter"} },
    carlo_gavazzi    = { protocol = "modbus", ders = {"meter"} },
    schneider_meter  = { protocol = "modbus", ders = {"meter"} },
    janitza          = { protocol = "modbus", ders = {"meter"} },
    abb_meter        = { protocol = "modbus", ders = {"meter"} },
    siemens_pac      = { protocol = "modbus", ders = {"meter"} },
    socomec          = { protocol = "modbus", ders = {"meter"} },
    acrel            = { protocol = "modbus", ders = {"meter"} },
    circutor         = { protocol = "modbus", ders = {"meter"} },
    chint            = { protocol = "modbus", ders = {"meter"} },

    -- Modbus EV chargers
    alfen            = { protocol = "modbus", ders = {"v2x_charger"} },
    abb_terra        = { protocol = "modbus", ders = {"v2x_charger"} },
    goe              = { protocol = "modbus", ders = {"v2x_charger"} },
    keba             = { protocol = "modbus", ders = {"v2x_charger"} },
    wallbox          = { protocol = "modbus", ders = {"v2x_charger"} },
    easee            = { protocol = "modbus", ders = {"v2x_charger"} },
    mennekes         = { protocol = "modbus", ders = {"v2x_charger"} },
    schrack_ev       = { protocol = "modbus", ders = {"v2x_charger"} },
    etrel            = { protocol = "modbus", ders = {"v2x_charger"} },

    -- HTTP inverters/batteries
    fronius_api      = { protocol = "http", ders = {"pv", "meter"} },
    opendtu          = { protocol = "http", ders = {"pv", "meter"} },
    sonnen           = { protocol = "http", ders = {"battery", "meter"}, port = 8080 },
    shelly           = { protocol = "http", ders = {"meter"} },

    -- HTTP EV chargers
    goe_http         = { protocol = "http", ders = {"v2x_charger"}, port = 8080 },
    openevse         = { protocol = "http", ders = {"v2x_charger"} },
    zaptec           = { protocol = "http", ders = {"v2x_charger"} },
    hardybarth       = { protocol = "http", ders = {"v2x_charger"} },

    -- MQTT drivers
    ferroamp         = { protocol = "mqtt", ders = {"pv", "battery", "meter"} },
    ambibox          = { protocol = "mqtt", ders = {"v2x_charger", "battery", "meter"} },
    victron_mqtt     = { protocol = "mqtt", ders = {"pv", "battery", "meter"} },
    opendtu_mqtt     = { protocol = "mqtt", ders = {"pv", "meter"} },

    -- Serial
    p1_meter         = { protocol = "serial", ders = {"meter"} },

    -- Standalone
    hello            = { protocol = "standalone", ders = {"meter"} },
}

---------------------------------------------------------------------------
-- Mock data setup
---------------------------------------------------------------------------

-- Fill modbus registers with generic default values
-- Then apply driver-specific overrides for SoC, scale factors, etc.
local function setup_modbus_data(driver_name)
    local holding = {}
    local input   = {}

    -- Fill a wide range with sensible defaults
    -- The pattern is designed so most common register addresses get reasonable values
    for addr = 0, 65535 do
        local val = 2300  -- default: 230V at 0.1V scale
        local mod = addr % 20
        if mod < 5 then
            val = 2300     -- ~230V at 0.1V scale
        elseif mod < 8 then
            val = 50       -- ~5A at 0.01A scale, or 50% SoC
        elseif mod < 11 then
            val = 1000     -- ~1000W
        elseif mod < 14 then
            val = 5000     -- ~50Hz at 0.01Hz scale
        elseif mod < 17 then
            val = 100      -- energy/counters
        else
            val = 250      -- temperature (25.0C at 0.1 scale)
        end
        holding[addr] = val
        input[addr]   = val
    end

    ---------------------------------------------------------------------------
    -- SoC register overrides: each driver reads SoC from a specific register
    -- and applies a specific formula. We set these to produce values in 0-1.
    ---------------------------------------------------------------------------

    -- GoodWe: reg 35182, formula = val / 100 -> set to 50 => 0.50
    holding[35182] = 50
    input[35182]   = 50

    -- Sungrow: reg 13022 (4th of 13019+4), formula = val * 0.1 / 100
    -- bat_regs[4] * 0.1 / 100 -> set to 500 => 0.50
    holding[13022] = 500
    input[13022]   = 500
    -- Sungrow status reg 13000 = 0 (not discharging)
    input[13000] = 0
    holding[13000] = 0

    -- Deye: reg 588, formula = val / 100 -> set to 50 => 0.50
    holding[588] = 50
    -- Deye battery temp: reg 217, formula = (val - 1000) / 10 -> 1250 => 25C
    holding[217] = 1250

    -- Huawei: reg 37004, formula = val * 0.1 / 100 -> set to 500 => 0.50
    holding[37004] = 500

    -- GoodWe, Victron, Fronius SunSpec: reg with /100 formula
    -- Victron modbus: reg 843, formula = val / 100 -> set to 50 => 0.50
    holding[843] = 50
    input[843]   = 50

    -- SMA: reg 30845-30846 as U32 BE / 100 -> set hi=0 lo=50 => decode_u32(0,50)=50 / 100=0.50
    input[30845] = 0
    input[30846] = 50
    holding[30845] = 0
    holding[30846] = 50

    -- Solis, Kostal, FoxESS, Sofar: SoC regs differ per driver
    -- Most use a U16 / 100 or U16 * 0.1 / 100 pattern
    -- We'll set many possible SoC addresses to 50 (=> 0.50 with /100)
    -- or 500 (=> 0.50 with *0.1/100)
    local soc_50_addrs = {
        -- Direct /100 pattern
        35182,  -- GoodWe
        843,    -- Victron
        588,    -- Deye
        1068,   -- VARTA
        -- Various SoC registers for other drivers (we'll set them all to 50)
    }
    local soc_500_addrs = {
        -- *0.1/100 pattern
        13022,  -- Sungrow
        37004,  -- Huawei
    }
    for _, a in ipairs(soc_50_addrs) do
        holding[a] = 50
        input[a]   = 50
    end
    for _, a in ipairs(soc_500_addrs) do
        holding[a] = 500
        input[a]   = 500
    end

    ---------------------------------------------------------------------------
    -- SunSpec scale factors: set ALL known SF registers to 0 (1:1 scaling)
    ---------------------------------------------------------------------------
    local sf_addrs = {
        -- SolarEdge
        40084, 40086, 40095, 40101, 40106, 40123, 40124,
        40194, 40203, 40210, 40242,
        -- Fronius SunSpec
        40135, 40265, 40266, 40331, 40335, 40337, 40338,
        -- Pixii
        40177, 40179, 40180, 40182, 40184, 40240, 40249, 40251, 40256, 40288,
    }
    for _, a in ipairs(sf_addrs) do
        holding[a] = 0
        input[a]   = 0
    end

    -- Fronius SunSpec SoC: reg 40321, SF at 40335 (=0), formula = scale(val, 0) / 100
    -- With SF=0, val stays as-is. Set to 50 => 50 / 100 = 0.50
    holding[40321] = 50

    -- Pixii SoC: reg 40132, SF at 40177 (=0), formula = scale(val, 0) / 100 => same
    holding[40132] = 50

    ---------------------------------------------------------------------------
    -- F32 encoded values for Fronius Modbus and Easee
    ---------------------------------------------------------------------------
    -- Fronius: AC power ~5000W
    local hi, lo = host.encode_f32(5000.0)
    holding[40091] = hi; holding[40092] = lo
    holding[40107] = hi; holding[40108] = lo
    -- Frequency ~50Hz
    hi, lo = host.encode_f32(50.01)
    holding[40093] = hi; holding[40094] = lo
    -- Lifetime energy ~15000000 Wh
    hi, lo = host.encode_f32(15000000.0)
    holding[40101] = hi; holding[40102] = lo
    -- Temperature ~35C
    hi, lo = host.encode_f32(35.0)
    holding[40111] = hi; holding[40112] = lo
    -- Per-phase voltage ~230V
    hi, lo = host.encode_f32(230.0)
    for _, a in ipairs({40085, 40087, 40089}) do
        holding[a] = hi; holding[a + 1] = lo
    end
    -- Per-phase current ~5A
    hi, lo = host.encode_f32(5.0)
    for _, a in ipairs({40073, 40075, 40077}) do
        holding[a] = hi; holding[a + 1] = lo
    end

    ---------------------------------------------------------------------------
    -- Per-driver Modbus overrides for special cases
    ---------------------------------------------------------------------------
    if driver_name == "easee" then
        -- Easee uses F32 at low addresses (0-9) and U16 at 10
        hi, lo = host.encode_f32(16.0)
        holding[0] = hi; holding[1] = lo
        hi, lo = host.encode_f32(15.0)
        holding[2] = hi; holding[3] = lo
        hi, lo = host.encode_f32(3500.0)
        holding[4] = hi; holding[5] = lo
        hi, lo = host.encode_f32(5000.0)
        holding[8] = hi; holding[9] = lo
        holding[10] = 3  -- charging state
    elseif driver_name == "goe" then
        -- go-e Modbus: U16 values at low addresses
        holding[0] = 2    -- state: charging
        holding[3] = 160  -- max current 0.1A -> 16A
        holding[6] = 5200; holding[7] = 4800; holding[8] = 5000  -- currents *0.001
        holding[9] = 230; holding[10] = 229; holding[11] = 231  -- voltages
        holding[12] = 0; holding[13] = 5000  -- session energy U32 BE
        holding[14] = 0; holding[15] = 345000  -- power U32 BE * 0.01
    elseif driver_name == "wallbox" then
        holding[0] = 1    -- state: charging
        holding[4] = 0; holding[5] = 3500   -- power U32 BE
        holding[7] = 0; holding[8] = 5000   -- session U32 BE
        holding[9] = 32   -- max current
    end

    ---------------------------------------------------------------------------
    -- SoC register patches: set ALL known SoC addresses to values that
    -- produce 0.50 (fraction) after each driver's specific formula.
    ---------------------------------------------------------------------------

    -- Pattern: val / 100 => set to 50
    local soc_div100 = {
        35182,  -- GoodWe
        843,    -- Victron modbus
        588,    -- Deye
        1068,   -- VARTA
        40321,  -- Fronius SunSpec (with SF=0)
        40132,  -- Pixii SunSpec (with SF=0)
        40137,  -- Kostal SunSpec
        1544,   -- Sofar
        28,     -- SolaX
        33139,  -- Solis
        11038,  -- FoxESS
        54,     -- KSTAR
        36,     -- AlphaESS
        4248,   -- SAJ
        1014,   -- Growatt
    }
    for _, a in ipairs(soc_div100) do
        holding[a] = 50
        input[a]   = 50
    end

    -- Pattern: val * 0.1 / 100 => set to 500
    local soc_01_div100 = {
        13022,  -- Sungrow (4th reg in batch at 13019)
        37004,  -- Huawei
    }
    for _, a in ipairs(soc_01_div100) do
        holding[a] = 500
        input[a]   = 500
    end

    -- SMA: U32 BE at 30845-30846 / 100 => hi=0, lo=50 => 50/100=0.50
    input[30845] = 0; input[30846] = 50
    holding[30845] = 0; holding[30846] = 50

    -- Copy holding to input so drivers reading from either register kind work
    for addr = 0, 65535 do
        if not input[addr] then
            input[addr] = holding[addr]
        end
    end

    host._modbus_registers.holding = holding
    host._modbus_registers.input   = input
end

-- Set up HTTP mock responses for a specific driver
local function setup_http_data(driver_name, port)
    host._http_responses = {}

    local base = "http://127.0.0.1:" .. (port or 80)

    if driver_name == "shelly" then
        host._http_responses[base .. "/rpc/Shelly.GetDeviceInfo"] =
            '{"id":"shellyem3-test","mac":"AABBCCDDEEFF","model":"SHEM-3","gen":2,"fw_id":"20231107","app":"Pro3EM","ver":"1.0.0"}'
        host._http_responses[base .. "/rpc/EM.GetStatus?id=0"] =
            '{"id":0,"a_act_power":1500.0,"a_aprt_power":1600.0,"a_current":6.5,"a_voltage":230.1,"a_freq":50.01,' ..
            '"b_act_power":800.0,"b_aprt_power":850.0,"b_current":3.5,"b_voltage":229.8,' ..
            '"c_act_power":-200.0,"c_aprt_power":250.0,"c_current":1.1,"c_voltage":230.5,' ..
            '"a_aenergy":{"total":150000},"b_aenergy":{"total":80000},"c_aenergy":{"total":10000},' ..
            '"a_ret_aenergy":{"total":5000},"b_ret_aenergy":{"total":2000},"c_ret_aenergy":{"total":50000}}'
    elseif driver_name == "fronius_api" then
        host._http_responses[base .. "/solar_api/v1/GetPowerFlowRealtimeData.fcgi"] =
            '{"Body":{"Data":{"Site":{"P_PV":5000,"P_Grid":-1200,"P_Load":-3800,"E_Total":15000000}}}}'
    elseif driver_name == "opendtu" then
        host._http_responses[base .. "/api/livedata/status"] =
            '{"inverters":[{"serial":"1234","reachable":true,' ..
            '"AC":{"0":{"Power":{"v":4500},"Voltage":{"v":230},"Current":{"v":19.5},"Frequency":{"v":50.01}}},' ..
            '"DC":{"0":{"Power":{"v":2500},"Voltage":{"v":35},"Current":{"v":71.4}},"1":{"Power":{"v":2200},"Voltage":{"v":34},"Current":{"v":64.7}}},' ..
            '"INV":{"0":{"YieldTotal":{"v":12500}}}}]}'
    elseif driver_name == "sonnen" then
        host._http_responses[base .. "/api/v2/status"] =
            '{"Pac_total_W":1500,"USOC":75,"GridFeedIn_W":-800,"Consumption_W":3000,"Production_W":5000,"Uac":230,"Fac":50.0}'
    elseif driver_name == "openevse" then
        host._http_responses[base .. "/status"] =
            '{"amp":16,"voltage":230,"state":3,"watt_seconds":7200000,"pilot":32,"temp1":350}'
    elseif driver_name == "goe_http" then
        host._http_responses[base .. "/api/status"] =
            '{"nrg":[230,229,231,0,5.2,4.8,5.0,1196,1099,1155,0,3450,0.98,0.97,0.99,0],"wh":5000,"car":2,"amp":16}'
    elseif driver_name == "zaptec" then
        host._http_responses[base .. "/api/charger/state"] =
            '{"ChargingPower":7200,"TotalChargingEnergy":3500,"ChargingCurrent":31.3,"Voltage":230,"ChargerState":"charging"}'
    elseif driver_name == "hardybarth" then
        host._http_responses[base .. "/api/status"] =
            '{"power":3500,"energy":2500,"current":15.2,"voltage":230,"state":"charging"}'
    end
end

-- Set up MQTT mock messages for a specific driver
local function setup_mqtt_data(driver_name)
    host._mqtt_buffer = {}

    if driver_name == "ferroamp" then
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
    elseif driver_name == "ambibox" then
        local fields = {
            {"powerAc", "3500"}, {"currentAc", "15.2"}, {"voltageAc", "230"},
            {"frequency", "50.0"}, {"powerDc", "3200"}, {"currentDc", "10"},
            {"voltageDc", "320"}, {"soc", "65"},
            {"currentAc1", "5.1"}, {"currentAc2", "5.0"}, {"currentAc3", "5.1"},
            {"voltageAc1", "230"}, {"voltageAc2", "229"}, {"voltageAc3", "231"},
            {"energyAcImport", "50000"}, {"energyAcExport", "10000"},
            {"evConnected", "true"},
            {"energyAcImportSession", "2000"}, {"energyAcExportSession", "500"},
            {"chargePowerMin", "1400"}, {"chargePowerMax", "22000"},
            {"dischargePowerMin", "1400"}, {"dischargePowerMax", "22000"},
            {"maxEnergyRequest", "50000"}, {"minEnergyRequest", "10000"},
        }
        for _, f in ipairs(fields) do
            table.insert(host._mqtt_buffer, {
                topic = "device/evCharger/0/" .. f[1],
                payload = f[2]
            })
        end
    elseif driver_name == "victron_mqtt" then
        local topics = {
            {"N/abc123/system/0/Ac/Grid/L1/Power", '{"value": 1500}'},
            {"N/abc123/system/0/Ac/Grid/L2/Power", '{"value": 800}'},
            {"N/abc123/system/0/Ac/Grid/L3/Power", '{"value": -200}'},
            {"N/abc123/system/0/Ac/PvOnOutput/L1/Power", '{"value": 2000}'},
            {"N/abc123/system/0/Ac/PvOnOutput/L2/Power", '{"value": 1500}'},
            {"N/abc123/system/0/Ac/PvOnOutput/L3/Power", '{"value": 1000}'},
            {"N/abc123/system/0/Dc/Pv/Power", '{"value": 500}'},
            {"N/abc123/system/0/Dc/Battery/Power", '{"value": 1000}'},
            {"N/abc123/system/0/Dc/Battery/Soc", '{"value": 80}'},
            {"N/abc123/system/0/Dc/Battery/Voltage", '{"value": 48.5}'},
            {"N/abc123/system/0/Dc/Battery/Current", '{"value": 20.6}'},
            {"N/abc123/system/0/Dc/Battery/Temperature", '{"value": 28}'},
        }
        for _, t in ipairs(topics) do
            table.insert(host._mqtt_buffer, {topic = t[1], payload = t[2]})
        end
    elseif driver_name == "opendtu_mqtt" then
        local topics = {
            {"solar/inv001/status/AC/Power", "4500"},
            {"solar/inv001/status/AC/Voltage", "230"},
            {"solar/inv001/status/AC/Current", "19.5"},
            {"solar/inv001/status/AC/Frequency", "50.01"},
            {"solar/inv001/status/DC/0/Power", "2500"},
            {"solar/inv001/status/DC/0/Voltage", "35"},
            {"solar/inv001/status/DC/0/Current", "71.4"},
            {"solar/inv001/status/DC/1/Power", "2200"},
            {"solar/inv001/status/INV/YieldTotal", "12500"},
        }
        for _, t in ipairs(topics) do
            table.insert(host._mqtt_buffer, {topic = t[1], payload = t[2]})
        end
    end
end

-- Set up P1 serial data (raw DSMR telegram)
local function setup_p1_data()
    -- Provide a raw DSMR v5 telegram as serial buffer bytes
    host._serial_buffer =
        "/ISk5\\2MT382-1000\r\n" ..
        "\r\n" ..
        "1-0:1.7.0(01.500*kW)\r\n" ..
        "1-0:2.7.0(00.000*kW)\r\n" ..
        "1-0:1.8.1(005000.000*kWh)\r\n" ..
        "1-0:1.8.2(003000.000*kWh)\r\n" ..
        "1-0:2.8.1(001000.000*kWh)\r\n" ..
        "1-0:2.8.2(000500.000*kWh)\r\n" ..
        "1-0:21.7.0(00.800*kW)\r\n" ..
        "1-0:22.7.0(00.000*kW)\r\n" ..
        "1-0:41.7.0(00.500*kW)\r\n" ..
        "1-0:42.7.0(00.000*kW)\r\n" ..
        "1-0:61.7.0(00.200*kW)\r\n" ..
        "1-0:62.7.0(00.000*kW)\r\n" ..
        "1-0:32.7.0(230.1*V)\r\n" ..
        "1-0:52.7.0(229.8*V)\r\n" ..
        "1-0:72.7.0(230.5*V)\r\n" ..
        "1-0:31.7.0(003.5*A)\r\n" ..
        "1-0:51.7.0(002.2*A)\r\n" ..
        "1-0:71.7.0(000.9*A)\r\n" ..
        "!ABCD\r\n"
end

---------------------------------------------------------------------------
-- Validation helpers
---------------------------------------------------------------------------

-- Check that emitted data for a DER type exists
local function check_der_emitted(emitted, der_type, errors)
    if not emitted[der_type] or #emitted[der_type] == 0 then
        table.insert(errors, "Expected '" .. der_type .. "' emission but got none")
        return false
    end
    return true
end

-- Check PV sign convention: w should be <= 0 (negative = generation)
local function check_pv_sign(emitted, errors)
    if not emitted.pv or #emitted.pv == 0 then return end
    local data = emitted.pv[1]
    local w = data.w or data.W
    if w and w > 0 then
        table.insert(errors, string.format("PV w should be <= 0 (generation), got %s", tostring(w)))
    end
end

-- Check battery SoC: should be 0-1 (fraction)
local function check_battery_soc(emitted, errors)
    if not emitted.battery or #emitted.battery == 0 then return end
    local data = emitted.battery[1]
    local soc = data.soc or data.SoC_nom_fract
    if soc then
        if soc < 0 or soc > 1 then
            table.insert(errors, string.format("Battery SoC should be 0-1 fraction, got %s", tostring(soc)))
        end
    end
end

-- Check that emitted data has at least one non-zero numeric field
local function check_has_data(emitted, der_type, errors)
    if not emitted[der_type] or #emitted[der_type] == 0 then return end
    local data = emitted[der_type][1]
    local has_nonzero = false
    for k, v in pairs(data) do
        if type(v) == "number" and v ~= 0 then
            has_nonzero = true
            break
        end
    end
    if not has_nonzero then
        table.insert(errors, string.format("'%s' emission has all zero values", der_type))
    end
end

---------------------------------------------------------------------------
-- Clear global driver state between runs
---------------------------------------------------------------------------

local function clear_driver_globals()
    driver_init = nil
    driver_poll = nil
    driver_cleanup = nil
    driver_command = nil
    driver_default_mode = nil
    driver_command_v2 = nil
    driver_default_mode_v2 = nil
    DRIVER = nil
    PROTOCOL = nil
end

---------------------------------------------------------------------------
-- Run a single driver test
---------------------------------------------------------------------------

local function test_driver(name, spec)
    -- Reset all state
    host.reset()
    clear_driver_globals()

    local errors = {}
    local warnings = {}

    local port = spec.port or (spec.protocol == "http" and 80 or 502)

    -- Set up mock data based on protocol
    if spec.protocol == "modbus" then
        setup_modbus_data(name)
    elseif spec.protocol == "http" then
        setup_http_data(name, port)
    elseif spec.protocol == "mqtt" then
        setup_mqtt_data(name)
    elseif spec.protocol == "serial" then
        setup_p1_data()
    end

    -- Load the driver file
    local driver_path = drivers_dir .. "/" .. name .. ".lua"
    local load_ok, load_err = pcall(dofile, driver_path)
    if not load_ok then
        return false, {"Failed to load: " .. tostring(load_err)}, warnings
    end

    -- Verify PROTOCOL matches
    if PROTOCOL and PROTOCOL ~= spec.protocol then
        table.insert(warnings, string.format("Expected protocol '%s', got '%s'", spec.protocol, PROTOCOL))
    end

    -- Build config
    local config = {
        sn             = "TEST-001",
        type           = "lua",
        profile        = name,
        host           = "127.0.0.1",
        port           = port,
        unit_id        = 1,
        serial_port    = "/dev/ttyUSB0",
        baud_rate      = 9600,
        gateway_serial = "GW-TEST-001",
        ders           = {},
    }

    -- Run driver_init
    if type(driver_init) ~= "function" then
        return false, {"driver_init not defined"}, warnings
    end
    local init_ok, init_err = pcall(driver_init, config)
    if not init_ok then
        return false, {"driver_init failed: " .. tostring(init_err)}, warnings
    end

    -- For MQTT drivers, re-inject messages since init subscribes and poll drains
    if spec.protocol == "mqtt" then
        setup_mqtt_data(name)
    end

    -- Run driver_poll
    if type(driver_poll) ~= "function" then
        return false, {"driver_poll not defined"}, warnings
    end
    local poll_ok, poll_result = pcall(driver_poll)
    if not poll_ok then
        return false, {"driver_poll failed: " .. tostring(poll_result)}, warnings
    end

    -- Run driver_cleanup (optional)
    if type(driver_cleanup) == "function" then
        local cleanup_ok, cleanup_err = pcall(driver_cleanup)
        if not cleanup_ok then
            table.insert(errors, "driver_cleanup failed: " .. tostring(cleanup_err))
        end
    end

    -- Verify expected DER emissions
    for _, der_type in ipairs(spec.ders) do
        check_der_emitted(host._emitted, der_type, errors)
        check_has_data(host._emitted, der_type, errors)
    end

    -- Check sign conventions
    check_pv_sign(host._emitted, errors)
    check_battery_soc(host._emitted, errors)

    -- Verify set_make was called
    if not host._make then
        table.insert(warnings, "set_make was not called")
    end

    local passed = #errors == 0
    return passed, errors, warnings
end

local function test_sungrow_ftw_v2()
    host.reset()
    clear_driver_globals()
    setup_modbus_data("sungrow")

    local errors = {}
    local driver_path = script_dir .. "../../../packages/v1/sungrow/targets/ftw.lua"
    local load_ok, load_err = pcall(dofile, driver_path)
    if not load_ok then
        return false, {"Failed to load: " .. tostring(load_err)}
    end
    if not DRIVER or DRIVER.version ~= "1.3.1" or
       DRIVER.host_api_min ~= 2 or DRIVER.host_api_max ~= 2 then
        table.insert(errors, "Sungrow FTW v2 metadata is wrong")
    end
    if type(driver_command_v2) ~= "function" or
       type(driver_default_mode_v2) ~= "function" then
        table.insert(errors, "Sungrow FTW v2 entrypoints are missing")
        return false, errors
    end

    driver_init({host = "127.0.0.1", port = 502, unit_id = 1})
    local poll_ok, poll_err = pcall(driver_poll)
    if not poll_ok then
        table.insert(errors, "Sungrow FTW v2 poll failed: " .. tostring(poll_err))
    end

    local applied = driver_command_v2({
        command = "battery.set_power",
        runtime_action = "battery",
        inputs = {power_w = 1250},
    })
    if applied.status ~= "applied" or applied.device_state ~= "controlled" or
       host._modbus_registers.holding[13050] ~= 1250 or
       host._modbus_registers.holding[13049] ~= 1 then
        table.insert(errors, "Sungrow FTW v2 charge did not apply with readback")
    end

    local rejected = driver_command_v2({
        command = "battery.set_power",
        runtime_action = "battery",
        inputs = {power_w = 70000},
    })
    if rejected.status ~= "rejected" or rejected.device_state ~= "unchanged" then
        table.insert(errors, "Sungrow FTW v2 accepted an unsafe register value")
    end

    host._modbus_write_attempts = 0
    host._modbus_write_fail_at = 2
    local failed = driver_command_v2({
        command = "battery.set_power",
        runtime_action = "battery",
        inputs = {power_w = -900},
    })
    host._modbus_write_fail_at = nil
    if failed.status ~= "failed" or host._modbus_registers.holding[13051] ~= 900 then
        table.insert(errors, "Sungrow FTW v2 did not report a partial write failure")
    end

    local defaulted = driver_default_mode_v2({reason = "test"})
    if defaulted.status ~= "defaulted" or defaulted.device_state ~= "default" or
       host._modbus_registers.holding[13049] ~= 0 then
        table.insert(errors, "Sungrow FTW v2 did not restore vendor auto mode")
    end

    return #errors == 0, errors
end

local function test_sungrow_ftw_observe()
    host.reset()
    clear_driver_globals()

    local errors = {}
    local driver_path = script_dir .. "../../../packages/v1/sungrow/targets/ftw-observe.lua"
    local load_ok, load_err = pcall(dofile, driver_path)
    if not load_ok then
        return false, {"Failed to load: " .. tostring(load_err)}
    end
    if not DRIVER or DRIVER.version ~= "1.3.2" or
       DRIVER.host_api_min ~= 1 or DRIVER.host_api_max ~= 1 or
       not DRIVER.legacy_ids or DRIVER.legacy_ids[1] ~= "sungrow-shx" then
        table.insert(errors, "Sungrow observe-only metadata is wrong")
    end
    if type(driver_command) ~= "function" or
       type(driver_default_mode) ~= "function" or
       type(driver_command_v2) == "function" or
       type(driver_default_mode_v2) == "function" then
        table.insert(errors, "Sungrow observe-only entrypoints are wrong")
        return false, errors
    end

    local init_ok, init_err = pcall(driver_init, {
        host = "127.0.0.1",
        port = 502,
        unit_id = 1,
        model = "SH10RT",
        firmware = "unknown",
    })
    if init_ok or not string.find(tostring(init_err), "not approved", 1, true) then
        table.insert(errors, "Sungrow observe-only target did not block an unapproved profile")
    end

    driver_command("battery", 1000, {})
    driver_default_mode()
    driver_cleanup()
    if host._modbus_write_attempts ~= 0 then
        table.insert(errors, "Sungrow observe-only lifecycle attempted a write")
    end

    return #errors == 0, errors
end

local function test_pixii_ftw_v2()
    host.reset()
    clear_driver_globals()
    setup_modbus_data("pixii")

    local errors = {}
    local driver_path = script_dir .. "../../../packages/v1/pixii/targets/ftw.lua"
    local load_ok, load_err = pcall(dofile, driver_path)
    if not load_ok then
        return false, {"Failed to load: " .. tostring(load_err)}
    end
    if not DRIVER or DRIVER.version ~= "1.2.1" or
       DRIVER.host_api_min ~= 2 or DRIVER.host_api_max ~= 2 then
        table.insert(errors, "Pixii FTW v2 metadata is wrong")
    end
    if type(driver_command_v2) ~= "function" or
       type(driver_default_mode_v2) ~= "function" then
        table.insert(errors, "Pixii FTW v2 entrypoints are missing")
        return false, errors
    end

    driver_init({host = "127.0.0.1", port = 502, unit_id = 1})
    host._modbus_registers.holding[40137] = 7
    local writes_before_poll = host._modbus_write_attempts
    local poll_ok, poll_err = pcall(driver_poll)
    if not poll_ok then
        table.insert(errors, "Pixii FTW v2 poll failed: " .. tostring(poll_err))
    end
    if host._modbus_write_attempts ~= writes_before_poll then
        table.insert(errors, "Pixii FTW v2 poll wrote outside the control scope")
    end
    if not host._faulted or host._fault_reason == "" then
        table.insert(errors, "Pixii FTW v2 did not enter a fault during calibration")
    end
    if not host._emitted.battery or not host._emitted.meter then
        table.insert(errors, "Pixii FTW v2 stopped telemetry during calibration")
    end

    local blocked = driver_command_v2({
        command = "battery.set_power",
        runtime_action = "battery",
        inputs = {power_w = 1250},
    })
    if blocked.status ~= "rejected" or blocked.code ~= "device_calibrating" then
        table.insert(errors, "Pixii FTW v2 accepted control during calibration")
    end

    host._modbus_registers.holding[40137] = 6
    local recovery_ok, recovery_err = pcall(driver_poll)
    if not recovery_ok then
        table.insert(errors, "Pixii FTW v2 recovery poll failed: " .. tostring(recovery_err))
    end
    if host._faulted or host._fault_reason ~= "" then
        table.insert(errors, "Pixii FTW v2 did not clear the fault after calibration")
    end

    local applied = driver_command_v2({
        command = "battery.set_power",
        runtime_action = "battery",
        inputs = {power_w = 1250},
    })
    local native_power = host.decode_i32_be(
        host._modbus_registers.holding[39905],
        host._modbus_registers.holding[39906]
    )
    if applied.status ~= "applied" or applied.device_state ~= "controlled" or
       native_power ~= -1250 or host._modbus_registers.holding[39903] == nil then
        table.insert(errors, "Pixii FTW v2 charge did not apply with readback and heartbeat")
    end

    local rejected = driver_command_v2({
        command = "battery.set_power",
        runtime_action = "battery",
        inputs = {power_w = 0 / 0},
    })
    if rejected.status ~= "rejected" or rejected.device_state ~= "unchanged" then
        table.insert(errors, "Pixii FTW v2 accepted an invalid power value")
    end

    local defaulted = driver_default_mode_v2({reason = "test"})
    local default_power = host.decode_i32_be(
        host._modbus_registers.holding[39905],
        host._modbus_registers.holding[39906]
    )
    if defaulted.status ~= "defaulted" or defaulted.device_state ~= "default" or
       default_power ~= 0 then
        table.insert(errors, "Pixii FTW v2 did not restore its safe idle setpoint")
    end

    return #errors == 0, errors
end

---------------------------------------------------------------------------
-- Main execution
---------------------------------------------------------------------------

-- Discover available drivers
local driver_files = {}
local ls_handle = io.popen('ls "' .. drivers_dir .. '"/*.lua 2>/dev/null')
if ls_handle then
    for line in ls_handle:lines() do
        local name = line:match("([^/]+)%.lua$")
        if name then
            table.insert(driver_files, name)
        end
    end
    ls_handle:close()
end

-- Sort for deterministic output
table.sort(driver_files)

-- Stats
local total   = 0
local passed  = 0
local failed  = 0
local skipped = 0

-- ANSI colors
local GREEN  = "\27[32m"
local RED    = "\27[31m"
local YELLOW = "\27[33m"
local RESET  = "\27[0m"
local BOLD   = "\27[1m"

io.write("\n" .. BOLD .. "=== Lua Driver Test Suite ===" .. RESET .. "\n\n")
io.write(string.format("Drivers directory: %s\n", drivers_dir))
io.write(string.format("Drivers found: %d\n", #driver_files))
io.write(string.format("Drivers with specs: %d\n\n", (function()
    local n = 0
    for _ in pairs(DRIVER_SPECS) do n = n + 1 end
    return n
end)()))

-- Width for alignment
local max_name_len = 0
for _, name in ipairs(driver_files) do
    if #name > max_name_len then max_name_len = #name end
end
max_name_len = max_name_len + 2
max_name_len = math.max(max_name_len, #"sungrow-ftw-v2" + 2)
max_name_len = math.max(max_name_len, #"sungrow-ftw-observe" + 2)
max_name_len = math.max(max_name_len, #"pixii-ftw-v2" + 2)

-- Run tests
local results = {}

for _, name in ipairs(driver_files) do
    total = total + 1
    local spec = DRIVER_SPECS[name]

    if not spec then
        skipped = skipped + 1
        local padding = string.rep(" ", max_name_len - #name)
        io.write(string.format("  %s%s%s[SKIP]%s  No test spec defined\n", name, padding, YELLOW, RESET))
        table.insert(results, {name = name, status = "SKIP", errors = {}, warnings = {"No test spec"}})
    else
        local ok, errs, warns = test_driver(name, spec)

        local padding = string.rep(" ", max_name_len - #name)

        if ok then
            passed = passed + 1
            local extra = ""
            if #warns > 0 then
                extra = YELLOW .. " (" .. #warns .. " warning" .. (#warns > 1 and "s" or "") .. ")" .. RESET
            end

            -- Show emitted DER types
            local emitted_types = {}
            for der_type, emissions in pairs(host._emitted) do
                if #emissions > 0 then
                    table.insert(emitted_types, der_type)
                end
            end
            table.sort(emitted_types)
            local ders_str = table.concat(emitted_types, ", ")

            io.write(string.format("  %s%s%s[PASS]%s  %s=%s  ders=[%s]%s\n",
                name, padding, GREEN, RESET,
                host._make or "?", spec.protocol,
                ders_str, extra))

            for _, w in ipairs(warns) do
                io.write(string.format("          %s! %s%s\n", YELLOW, w, RESET))
            end
        else
            failed = failed + 1
            io.write(string.format("  %s%s%s[FAIL]%s  %s\n",
                name, padding, RED, RESET, spec.protocol))
            for _, e in ipairs(errs) do
                io.write(string.format("          %s- %s%s\n", RED, e, RESET))
            end
            for _, w in ipairs(warns) do
                io.write(string.format("          %s! %s%s\n", YELLOW, w, RESET))
            end
        end

        table.insert(results, {name = name, status = ok and "PASS" or "FAIL", errors = errs, warnings = warns})
    end
end

total = total + 1
local ftw_name = "sungrow-ftw-v2"
local ftw_ok, ftw_errors = test_sungrow_ftw_v2()
local ftw_padding = string.rep(" ", max_name_len - #ftw_name)
if ftw_ok then
    passed = passed + 1
    io.write(string.format("  %s%s%s[PASS]%s  staged control adapter\n",
        ftw_name, ftw_padding, GREEN, RESET))
else
    failed = failed + 1
    io.write(string.format("  %s%s%s[FAIL]%s  staged control adapter\n",
        ftw_name, ftw_padding, RED, RESET))
    for _, err in ipairs(ftw_errors) do
        io.write(string.format("          %s- %s%s\n", RED, err, RESET))
    end
end

total = total + 1
local observe_name = "sungrow-ftw-observe"
local observe_ok, observe_errors = test_sungrow_ftw_observe()
local observe_padding = string.rep(" ", max_name_len - #observe_name)
if observe_ok then
    passed = passed + 1
    io.write(string.format("  %s%s%s[PASS]%s  read-only and profile-blocked\n",
        observe_name, observe_padding, GREEN, RESET))
else
    failed = failed + 1
    io.write(string.format("  %s%s%s[FAIL]%s  read-only and profile-blocked\n",
        observe_name, observe_padding, RED, RESET))
    for _, err in ipairs(observe_errors) do
        io.write(string.format("          %s- %s%s\n", RED, err, RESET))
    end
end

total = total + 1
local pixii_ftw_name = "pixii-ftw-v2"
local pixii_ftw_ok, pixii_ftw_errors = test_pixii_ftw_v2()
local pixii_ftw_padding = string.rep(" ", max_name_len - #pixii_ftw_name)
if pixii_ftw_ok then
    passed = passed + 1
    io.write(string.format("  %s%s%s[PASS]%s  calibration fault and staged control adapter\n",
        pixii_ftw_name, pixii_ftw_padding, GREEN, RESET))
else
    failed = failed + 1
    io.write(string.format("  %s%s%s[FAIL]%s  calibration fault and staged control adapter\n",
        pixii_ftw_name, pixii_ftw_padding, RED, RESET))
    for _, err in ipairs(pixii_ftw_errors) do
        io.write(string.format("          %s- %s%s\n", RED, err, RESET))
    end
end

---------------------------------------------------------------------------
-- Summary
---------------------------------------------------------------------------

io.write("\n" .. BOLD .. "=== Summary ===" .. RESET .. "\n\n")
io.write(string.format("  Total:   %d\n", total))
io.write(string.format("  %sPassed:  %d%s\n", GREEN, passed, RESET))
if failed > 0 then
    io.write(string.format("  %sFailed:  %d%s\n", RED, failed, RESET))
else
    io.write(string.format("  Failed:  %d\n", failed))
end
if skipped > 0 then
    io.write(string.format("  %sSkipped: %d%s\n", YELLOW, skipped, RESET))
else
    io.write(string.format("  Skipped: %d\n", skipped))
end
io.write("\n")

-- Exit with failure code if any tests failed
if failed > 0 then
    os.exit(1)
end
