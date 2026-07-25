-- Sungrow SH Hybrid Inverter Driver
-- FTW control-v2 target adapter, based on the read and telemetry logic in
-- drivers/lua/sungrow.lua 1.2.0. Keep target changes here until all hosts use
-- the canonical v2 lifecycle and result contract.
-- Emits: PV, Battery, Meter
-- Register type: INPUT
-- Byte order: Little-Endian for multi-register values

DRIVER = {
    host_api_min = 2,
    host_api_max = 2,
    id = "sungrow",
    name = "Sungrow hybrid and string inverter",
    manufacturer = "Sungrow",
    version = "1.3.3",
    protocols = { "modbus" },
    capabilities = { "pv", "battery", "meter" },
    description = "Sungrow hybrid and string inverters via Modbus.",
    authors = { "Sourceful contributors" },
    verification_status = "experimental",
    verification_notes = "FTW v2 control adapter is staged off until runtime isolation and physical HIL pass.",
    connection_defaults = {
        port = 502,
        unit_id = 1,
    },
}

PROTOCOL = "modbus"

local sn_read = false

-- Sungrow model families do not share one register map. SH hybrids answer the
-- 13xxx block; SG string inverters have no battery and no such block, and a
-- site without a Sungrow meter answers none of the 56xx/57xx meter registers.
-- The host counts every failed Modbus read against the poll, so an SG inverter
-- read with the hybrid map failed the whole poll and went offline instead of
-- reporting the PV it does have.
--
-- The device type code says which family this is, so ask the inverter rather
-- than discovering it through failed reads. Only when that register is
-- unreadable do we fall back on probing.
local REG_DEVICE_TYPE = 4999
local model_family = nil -- "hybrid", "string", or nil while still unknown

-- A register that answers on one model and not on another. Absence has to be
-- proved, not guessed: a single timeout or a busy bus must not silence a
-- register for the rest of the session, so only a run of failures counts.
local MISSES_BEFORE_SKIP = 3
local miss_counts = {}

local function optional_read(address, count, kind)
    if (miss_counts[address] or 0) >= MISSES_BEFORE_SKIP then
        return nil
    end
    local ok, registers = pcall(host.modbus_read, address, count, kind)
    if ok and registers ~= nil and registers[1] ~= nil then
        miss_counts[address] = nil
        return registers
    end
    local misses = (miss_counts[address] or 0) + 1
    miss_counts[address] = misses
    if misses >= MISSES_BEFORE_SKIP then
        host.log("info", "Sungrow: register " .. address
            .. " failed " .. misses .. " reads in a row; treating it as absent")
    end
    return nil
end

-- 0x0D and 0x0E are the SH hybrid device-type families. Any other clean code
-- is a string inverter: PV, an optional meter, and no battery.
local function detect_model_family()
    local ok, regs = pcall(host.modbus_read, REG_DEVICE_TYPE, 1, "input")
    if not ok or regs == nil or regs[1] == nil then
        return nil
    end
    local code = regs[1]
    if code == 0 or code == 0xFFFF then
        return nil -- empty / sentinel read, inconclusive
    end
    local hi = math.floor(code / 256)
    if hi == 0x0D or hi == 0x0E then
        return "hybrid"
    end
    return "string"
end

-- True while the hybrid block is worth reading: on a known string inverter it
-- never is, and on an unknown model we let optional_read decide.
local function hybrid_block_worth_reading()
    return model_family ~= "string"
end

function driver_init(config)
    host.set_make("Sungrow")
end

function driver_poll()
    -- Read serial number once on first successful poll (Modbus connected by now)
    if not sn_read then
        local ok, sn_regs = pcall(host.modbus_read, 4990, 10, "input")
        if ok and sn_regs then
            local sn = ""
            for i = 1, 10 do
                local hi = math.floor(sn_regs[i] / 256)
                local lo = sn_regs[i] % 256
                if hi > 32 and hi < 127 then sn = sn .. string.char(hi) end
                if lo > 32 and lo < 127 then sn = sn .. string.char(lo) end
            end
            if string.len(sn) > 0 then
                host.set_sn(sn)
                sn_read = true
            end
        end
    end

    -- Ask the inverter which family it belongs to before reading a map that
    -- may not apply. Retried while unknown; the code register is cheap.
    if model_family == nil then
        model_family = detect_model_family()
        if model_family then
            host.log("info", "Sungrow: detected a " .. model_family .. " inverter")
        end
    end

    -- Read status flags to determine battery direction. Hybrid only.
    local status = 0
    if hybrid_block_worth_reading() then
        local status_regs = optional_read(13000, 1, "input")
        if status_regs then
            status = status_regs[1]
        end
    end
    -- Lua 5.1 compatible bit check: bit 2 (0x0004) set means discharging
    local is_discharging = (math.floor(status / 4) % 2) == 1

    -- PV power: 5016-5017, U32 LE, watts
    local ok_pv, pv_regs = pcall(host.modbus_read, 5016, 2, "input")
    local pv_w = 0
    if ok_pv and pv_regs then
        pv_w = host.decode_u32_le(pv_regs[1], pv_regs[2])
    end

    -- PV MPPT voltages and currents: 5010-5013
    local ok_mppt, mppt_regs = pcall(host.modbus_read, 5010, 4, "input")
    local mppt1_v, mppt1_a, mppt2_v, mppt2_a = 0, 0, 0, 0
    if ok_mppt and mppt_regs then
        mppt1_v = mppt_regs[1] * 0.1
        mppt1_a = mppt_regs[2] * 0.1
        mppt2_v = mppt_regs[3] * 0.1
        mppt2_a = mppt_regs[4] * 0.1
    end

    -- PV generation energy: 13002-13003, U32 LE × 0.1 kWh. Hybrid only.
    local pv_gen_wh = 0
    if hybrid_block_worth_reading() then
        local pvgen_regs = optional_read(13002, 2, "input")
        if pvgen_regs then
            pv_gen_wh = host.decode_u32_le(pvgen_regs[1], pvgen_regs[2]) * 0.1 * 1000
        end
    end

    -- Rated power: 5000, U16 × 0.1 kW
    local ok_rated, rated_regs = pcall(host.modbus_read, 5000, 1, "input")
    local rated_w = 0
    if ok_rated and rated_regs then
        rated_w = rated_regs[1] * 0.1 * 1000
    end

    -- Heatsink temp: 5007, I16 × 0.1 C
    local ok_temp, temp_regs = pcall(host.modbus_read, 5007, 1, "input")
    local heatsink_c = 0
    if ok_temp and temp_regs then
        heatsink_c = host.decode_i16(temp_regs[1]) * 0.1
    end

    -- Frequency: 5241, U16 × 0.01 Hz
    local ok_hz, hz_regs = pcall(host.modbus_read, 5241, 1, "input")
    local hz = 0
    if ok_hz and hz_regs then
        hz = hz_regs[1] * 0.01
    end

    -- Emit PV telemetry (W always negative for generation)
    host.emit("pv", {
        W           = -pv_w,
        mppt1_v     = mppt1_v,
        mppt1_a     = mppt1_a,
        mppt2_v     = mppt2_v,
        mppt2_a     = mppt2_a,
        total_generation_Wh = pv_gen_wh,
        rated_W     = rated_w,
        temperature_C      = heatsink_c,
    })

    -- Battery registers: 13019-13022. An SG string inverter has no battery and
    -- answers none of these, so probe here and emit the stream only when the
    -- inverter really has one.
    local bat_regs = nil
    if hybrid_block_worth_reading() then
        bat_regs = optional_read(13019, 4, "input")
    end
    if bat_regs then
        local bat_v   = bat_regs[1] * 0.1
        local bat_a   = bat_regs[2] * 0.1
        local bat_w   = bat_regs[3]
        local bat_soc = bat_regs[4] * 0.1 / 100  -- percent to fraction

        -- Negate battery W if discharging
        if is_discharging then
            bat_w = -bat_w
        end

        -- Battery charge energy: 13040-13041, U32 LE × 0.1 kWh
        local bchg_regs = optional_read(13040, 2, "input")
        local bat_charge_wh = 0
        if bchg_regs then
            bat_charge_wh = host.decode_u32_le(bchg_regs[1], bchg_regs[2]) * 0.1 * 1000
        end

        -- Battery discharge energy: 13026-13027, U32 LE × 0.1 kWh
        local bdis_regs = optional_read(13026, 2, "input")
        local bat_discharge_wh = 0
        if bdis_regs then
            bat_discharge_wh = host.decode_u32_le(bdis_regs[1], bdis_regs[2]) * 0.1 * 1000
        end

        -- Emit Battery telemetry
        host.emit("battery", {
            W            = bat_w,
            V            = bat_v,
            A            = bat_a,
            SoC_nom_fract          = bat_soc,
            total_charge_Wh    = bat_charge_wh,
            total_discharge_Wh = bat_discharge_wh,
        })
    end

    -- Meter registers. They exist only when a Sungrow meter is wired to the
    -- inverter, so every read below is optional and the stream is emitted only
    -- when at least one of them answered.
    local meter_present = false

    -- Meter power: 5600-5601, I32 LE, watts
    local mw_regs = optional_read(5600, 2, "input")
    local meter_w = 0
    if mw_regs then
        meter_w = host.decode_i32_le(mw_regs[1], mw_regs[2])
        meter_present = true
    end

    -- Per-phase meter power: 5602-5607, I32 LE each pair
    local mp_regs = optional_read(5602, 6, "input")
    local l1_w, l2_w, l3_w = 0, 0, 0
    if mp_regs then
        l1_w = host.decode_i32_le(mp_regs[1], mp_regs[2])
        l2_w = host.decode_i32_le(mp_regs[3], mp_regs[4])
        l3_w = host.decode_i32_le(mp_regs[5], mp_regs[6])
        meter_present = true
    end

    -- Per-phase voltage: 5740-5742, U16 × 0.1 each
    local mv_regs = optional_read(5740, 3, "input")
    local l1_v, l2_v, l3_v = 0, 0, 0
    if mv_regs then
        l1_v = mv_regs[1] * 0.1
        l2_v = mv_regs[2] * 0.1
        l3_v = mv_regs[3] * 0.1
        meter_present = true
    end

    -- Per-phase current: 5743-5745, U16 × 0.01 each
    local ma_regs = optional_read(5743, 3, "input")
    local l1_a, l2_a, l3_a = 0, 0, 0
    if ma_regs then
        l1_a = ma_regs[1] * 0.01
        l2_a = ma_regs[2] * 0.01
        l3_a = ma_regs[3] * 0.01
        meter_present = true
    end

    -- Import and export energy: 13036-13037 and 13045-13046, U32 LE × 0.1 kWh.
    -- Hybrid only.
    local import_wh, export_wh = 0, 0
    if hybrid_block_worth_reading() then
        local imp_regs = optional_read(13036, 2, "input")
        if imp_regs then
            import_wh = host.decode_u32_le(imp_regs[1], imp_regs[2]) * 0.1 * 1000
        end

        local exp_regs = optional_read(13045, 2, "input")
        if exp_regs then
            export_wh = host.decode_u32_le(exp_regs[1], exp_regs[2]) * 0.1 * 1000
        end
    end

    -- Emit Meter telemetry
    if meter_present then
        host.emit("meter", {
            W         = meter_w,
            L1_W      = l1_w,
            L2_W      = l2_w,
            L3_W      = l3_w,
            L1_V      = l1_v,
            L2_V      = l2_v,
            L3_V      = l3_v,
            L1_A      = l1_a,
            L2_A      = l2_a,
            L3_A      = l3_a,
            Hz        = hz,
            total_import_Wh = import_wh,
            total_export_Wh = export_wh,
        })
    end

    return 5000
end

local function v2_failure(code, message, device_state)
    return {
        status = "failed",
        code = code,
        message = message,
        device_state = device_state or "unknown",
    }
end

local function v2_write_register(address, value)
    local err = host.write(address, value)
    if err then
        return false, tostring(err)
    end
    return true, nil
end

local function v2_read_register(address)
    local registers, err = host.modbus_read(address, 1, "holding")
    if err then
        return nil, tostring(err)
    end
    if type(registers) ~= "table" or type(registers[1]) ~= "number" then
        return nil, "missing register value"
    end
    return registers[1], nil
end

local function v2_power_limit(power_w)
    if type(power_w) ~= "number" then
        return nil, "power_w must be a number"
    end
    local limit = math.floor(math.abs(power_w) + 0.5)
    if limit > 65535 then
        return nil, "power_w exceeds the Sungrow register range"
    end
    return limit, nil
end

local function v2_apply_mode(mode, limit_register, limit, applied_power_w)
    if limit_register then
        local ok, err = v2_write_register(limit_register, limit)
        if not ok then
            return v2_failure("limit_write_failed", err, "unchanged")
        end
    end

    local ok, err = v2_write_register(13049, mode)
    if not ok then
        return v2_failure("mode_write_failed", err)
    end

    local actual_mode, mode_err = v2_read_register(13049)
    if mode_err then
        return v2_failure("mode_readback_failed", mode_err)
    end
    if actual_mode ~= mode then
        return v2_failure("mode_readback_mismatch", "operating mode did not match the request")
    end

    if limit_register then
        local actual_limit, limit_err = v2_read_register(limit_register)
        if limit_err then
            return v2_failure("limit_readback_failed", limit_err)
        end
        if actual_limit ~= limit then
            return v2_failure("limit_readback_mismatch", "power limit did not match the request")
        end
    end

    return {
        status = "applied",
        code = mode == 0 and "default_restored" or "ok",
        device_state = mode == 0 and "default" or "controlled",
        evidence = {"write_ack", "readback"},
        applied = {power_w = applied_power_w},
    }
end

-- FTW control v2 entrypoint. The host validates the command envelope and
-- opens the short write scope before this function runs.
function driver_command_v2(command)
    local action = command.runtime_action
    local inputs = command.inputs or {}

    if action == "battery" then
        -- The inverter identified itself as a string model, so it has no
        -- battery. Refuse rather than write EMS registers it does not
        -- implement.
        if model_family == "string" then
            return {
                status = "rejected",
                code = "no_battery",
                message = "this Sungrow model has no battery registers",
                device_state = "unchanged",
            }
        end
        local limit, err = v2_power_limit(inputs.power_w)
        if not limit then
            return {status = "rejected", code = "invalid_power", message = err, device_state = "unchanged"}
        end
        if inputs.power_w > 0 then
            return v2_apply_mode(1, 13050, limit, limit)
        elseif inputs.power_w < 0 then
            return v2_apply_mode(2, 13051, limit, -limit)
        end
        return v2_apply_mode(0, nil, nil, 0)
    elseif action == "curtail" then
        local limit, err = v2_power_limit(inputs.power_w)
        if not limit then
            return {status = "rejected", code = "invalid_power", message = err, device_state = "unchanged"}
        end
        return v2_apply_mode(1, 13050, limit, limit)
    elseif action == "curtail_disable" then
        return v2_apply_mode(0, nil, nil, 0)
    end

    return {status = "rejected", code = "unknown_action", device_state = "unchanged"}
end

function driver_default_mode_v2(context)
    local ok, err = v2_write_register(13049, 0)
    if not ok then
        return v2_failure("default_write_failed", err)
    end
    local actual_mode, read_err = v2_read_register(13049)
    if read_err then
        return v2_failure("default_readback_failed", read_err)
    end
    if actual_mode ~= 0 then
        return v2_failure("default_readback_mismatch", "operating mode did not return to auto")
    end
    return {
        status = "defaulted",
        code = "default_restored",
        device_state = "default",
        evidence = {"write_ack", "readback"},
    }
end

function driver_cleanup()
end
