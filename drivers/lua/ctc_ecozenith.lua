-- CTC EcoZenith i250/i255 heat pump controller — Modbus TCP, read-only.
--
-- Emits: metrics only, via host.emit_metric. A heat pump is a load, and this
-- driver never emits a meter, so it does no sign conversion and cannot
-- double-count against the site's grid meter.
-- Control: none. New drivers start read-only. The 1000-series registers
-- CTC documents for control are listed at the end of this file so the next
-- step does not have to rediscover them.
--
-- SOURCE
--   CTC "BMS via TCP/IP" register list, Swedish and English editions, the
--   manifest's upstream_docs. Read with function code 3 (holding), offset 0:
--   the register number in the list is the address on the wire, no -1.
--   Every value is a signed 16-bit integer; the list gives each one's factor
--   (0.1 for temperatures, kW and RPS; 1 for codes).
--
--   The list has one column per controller family. A register is read here
--   only when the EcoZenith i250 column is marked; the i255 is that
--   controller's successor and the list names it explicitly in its
--   control-register notes.
--
-- WHAT THE DEVICE DOES THAT THE LIST DOES NOT SAY
--   Measured on an EcoZenith i255, display software 2024-07-19, on
--   2026-11-10:
--   - A request for an address the controller does not have gets NO reply:
--     no Modbus exception, the request just times out, and the next
--     connection may be reset. That is why every read here is a documented
--     i250 register, and why each one is bounded by probe_read below.
--   - A documented register whose sensor is not fitted answers 0, not an
--     error. Room temperature 1 (62203) read 0 on a pump with no room
--     sensor; an unconnected sensor elsewhere read -999.9. Both are treated
--     as absent for the temperatures where 0 cannot be a real reading.
--   - One open connection served 18 reads in 0.16 s. It is a normal Modbus
--     TCP server once it is only asked about registers it has.
--
-- POWER
--   The controller does not report the compressor's electrical input. The
--   current registers (62171-62173) are the house's incoming phases, read
--   from the controller's own current transformers when they are fitted,
--   not the pump's draw, and they read 0 when they are not. So this driver
--   emits no hp_power_w. Inventing one from RPS would be a guess.
--
-- SETUP ON THE PUMP
--   Display menu Installer/Define/Remote control: define "Modbus TCP". CTC
--   says only displays with three connection ports can do BMS over TCP/IP.
--
-- Config example (config.yaml):
--   drivers:
--     - name: ctc
--       lua: drivers/ctc_ecozenith.lua
--       capabilities:
--         modbus:
--           host: <pump-ip>
--           port: 502
--           unit_id: 1

PROTOCOL = "modbus"

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "ctc_ecozenith",
  name         = "CTC EcoZenith i250/i255",
  manufacturer = "CTC",
  version      = "0.1.0",
  protocols    = { "modbus" },
  capabilities = { "heatpump" },
  read_only    = true,
  description  = "CTC EcoZenith i250/i255 heat pump controller via Modbus TCP (BMS). Read-only: temperatures, compressor speed and status, immersion heater power, heat curve settings.",
  homepage     = "https://www.ctc.se",
  authors      = { "hannesb90", "Claude (Anthropic)" },
  tested_models = { "EcoZenith i255" },
  verification_status = "experimental",
  verification_notes  = "Register reads checked against one EcoZenith i255 (display software 2024-07-19) over Modbus TCP on 2026-11-10. Not yet run as an FTW driver on that pump.",
  connection_defaults = {
    port    = 502,
    unit_id = 1,
  },
}

-- Registers, as numbered in CTC's list. Each is in the i250 column.
local REG_BLOCK_START   = 62000 -- 62000..62015 in one read
local BLOCK_COUNT       = 16
local REG_OUTDOOR       = 62000 -- Outdoor temperature, 0.1 °C
local REG_STATUS        = 62005 -- Status code, see STATUS below
local REG_RADIATOR      = 62006 -- Radiator water, 0.1 °C
local REG_HS1_FLOW      = 62011 -- Heating system 1: primary flow, 0.1 °C
local REG_RETURN        = 62015 -- Return temp, 0.1 °C
local REG_HP1_STATUS    = 62017 -- Heat pump 1 (A1) status code
local REG_HP1_IN        = 62027 -- Heat pump 1 (A1) HP in, 0.1 °C
local REG_HP1_OUT       = 62037 -- Heat pump 1 (A1) HP out, 0.1 °C
local REG_HP1_SW        = 62157 -- Heat pump 1 (A1) software version
local REG_IMMERSION     = 62168 -- 62168 upper, 62169 lower: 0.1 kW
local REG_HP1_RPS       = 62193 -- Heat pump 1 (A1) current RPS, 0.1
local REG_ROOM1         = 62203 -- Current room temp 1, 0.1 °C
local REG_DISPLAY_SW    = 62244 -- 62244 month*100+day, 62245 year
local REG_PRODUCT_TYPE  = 62253 -- Product type code
local REG_LOWER_TANK_SET = 62274 -- Lower tank setpoint, 0.1 °C
-- 62275 (DHW lower) sits between these two but is not in the i250 column,
-- so the two are read singly: a controller without it would not answer a
-- read that spans it, and the DHW top temperature would go with it.
local REG_HW_TOP         = 62276 -- DHW top temperature, 0.1 °C
local REG_HS1_ROOM_SET  = 61509 -- Heating system 1: room setting, 0.1 °C
local REG_HS1_INCLINE   = 61513 -- Heating system 1: curve inclination, 0.1
local REG_HS1_ADJUST    = 61517 -- Room 1: curve adjustment, 0.1 °C

-- An unconnected sensor. CTC uses -999.9 for it.
local SENSOR_OPEN = -9990

local POLL_MS = 30000

-------------------------------------------------------------------------------
-- Bounded reads. A register that does not answer three polls in a row is
-- left alone until restart: on this controller a missing register costs a
-- full timeout, and paying it every poll would be an outage arriving slowly.
-------------------------------------------------------------------------------

local GIVE_UP_AFTER = 3
local read_failures = {}

local function probe_read(addr, count)
    if (read_failures[addr] or 0) >= GIVE_UP_AFTER then return nil end
    local ok, regs = pcall(host.modbus_read, addr, count, "holding")
    if ok and regs then
        for i = 1, count do
            if regs[i] == nil then ok = false break end
        end
    end
    if ok and regs then
        read_failures[addr] = nil
        return regs
    end
    local failures = (read_failures[addr] or 0) + 1
    read_failures[addr] = failures
    if failures == GIVE_UP_AFTER then
        host.log("info", string.format(
            "CTC: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

local function s16(raw)
    if raw == nil then return nil end
    return host.decode_i16(raw)
end

-- A temperature in 0.1 °C, or nil when the sensor is open.
local function temp(raw)
    local v = s16(raw)
    if v == nil or v <= SENSOR_OPEN then return nil end
    return v / 10
end

-- The same, for a sensor that reads exactly 0 when it is not fitted. Only
-- for places where 0.0 °C is not a real reading in operation: a room, a
-- hot-water tank.
local function fitted_temp(raw)
    local v = s16(raw)
    if v == nil or v == 0 then return nil end
    return temp(raw)
end

local function emit(name, value, unit)
    if value ~= nil then host.emit_metric(name, value, unit) end
end

-------------------------------------------------------------------------------
-- Identity, read once and bounded.
-------------------------------------------------------------------------------

local identity_tries = 0
local identity_done = false
local IDENTITY_ATTEMPTS = 3

local function read_identity()
    if identity_done or identity_tries >= IDENTITY_ATTEMPTS then return end
    identity_tries = identity_tries + 1
    local product = probe_read(REG_PRODUCT_TYPE, 1)
    local sw = probe_read(REG_DISPLAY_SW, 2)
    local hp_sw = probe_read(REG_HP1_SW, 1)
    if product then
        -- CTC's list gives no table for this code; it is reported as the
        -- number so two controllers can at least be told apart.
        host.set_model(string.format("EcoZenith (product type %d)", product[1]))
        emit("hp_ctc_product_type", product[1], "")
    end
    if sw then
        local md, year = sw[1], sw[2]
        host.log("info", string.format("CTC: display software %04d-%02d-%02d",
            year, math.floor(md / 100), md % 100))
    end
    if hp_sw then
        emit("hp_ctc_hp1_software", hp_sw[1], "")
    end
    identity_done = product ~= nil
end

-------------------------------------------------------------------------------
-- Entry points
-------------------------------------------------------------------------------

function driver_init(config)
    host.set_make("CTC")
end

function driver_poll()
    read_identity()

    local block = probe_read(REG_BLOCK_START, BLOCK_COUNT)
    if block then
        local function at(reg) return block[reg - REG_BLOCK_START + 1] end
        -- Outdoor 0.0 °C is a real reading, so only the open-sensor value
        -- counts as absent here.
        emit("hp_outdoor_temp_c", temp(at(REG_OUTDOOR)), "°C")
        emit("hp_ctc_status", s16(at(REG_STATUS)), "")
        emit("hp_radiator_temp_c", temp(at(REG_RADIATOR)), "°C")
        emit("hp_flow_temp_c", temp(at(REG_HS1_FLOW)), "°C")
        emit("hp_return_temp_c", temp(at(REG_RETURN)), "°C")
    end

    local hp_status = probe_read(REG_HP1_STATUS, 1)
    if hp_status then emit("hp_ctc_compressor_status", s16(hp_status[1]), "") end

    local hp_in = probe_read(REG_HP1_IN, 1)
    if hp_in then emit("hp_inlet_temp_c", temp(hp_in[1]), "°C") end

    local hp_out = probe_read(REG_HP1_OUT, 1)
    if hp_out then emit("hp_outlet_temp_c", temp(hp_out[1]), "°C") end

    local rps = probe_read(REG_HP1_RPS, 1)
    if rps then emit("hp_compressor_rps", s16(rps[1]) / 10, "rps") end

    -- The controller reports kW; the host contract is W.
    local immersion = probe_read(REG_IMMERSION, 2)
    if immersion then
        emit("hp_immersion_upper_w", s16(immersion[1]) * 100, "W")
        emit("hp_immersion_lower_w", s16(immersion[2]) * 100, "W")
    end

    local room = probe_read(REG_ROOM1, 1)
    if room then emit("hp_indoor_temp_c", fitted_temp(room[1]), "°C") end

    local lower_set = probe_read(REG_LOWER_TANK_SET, 1)
    if lower_set then emit("hp_lower_tank_setpoint_c", fitted_temp(lower_set[1]), "°C") end

    local hw_top = probe_read(REG_HW_TOP, 1)
    if hw_top then emit("hp_hw_top_temp_c", fitted_temp(hw_top[1]), "°C") end

    local room_set = probe_read(REG_HS1_ROOM_SET, 1)
    if room_set then emit("hp_room_setpoint_c", temp(room_set[1]), "°C") end

    local incline = probe_read(REG_HS1_INCLINE, 1)
    if incline then emit("hp_curve_inclination", s16(incline[1]) / 10, "") end

    local adjust = probe_read(REG_HS1_ADJUST, 1)
    if adjust then emit("hp_curve_adjustment_c", s16(adjust[1]) / 10, "°C") end

    host.emit_metric("hp_poll_ok", block and 1 or 0, "")
    return POLL_MS
end

function driver_cleanup()
end

-- Not used by this read-only driver. Kept as the map for the control step.
--
-- CTC's 1000-series registers are written with function code 16 and "must
-- be updated every 5 minutes, otherwise they are reset", and they also reset
-- on restart. The controller itself therefore hands the device back within
-- five minutes of the last write: a device-side hold, declared later as
-- device_hold_max_s = 300 (docs/adr/0012 in srcfl/ftw).
--   1005  ElPriceMode, 1 low, 2 normal, 3 high
--   1006  Extra DHW
--   1007  DHW mode, 0 economy, 1 normal, 2 comfort
--   1010  Setpoint heat HC1
--   1023  Setpoint offset heat HC1
--   1029  Setpoint flow temp HC1
-- All are in the i250 column. None has been written to a pump yet.
