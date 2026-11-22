-- KSTAR KSE Series Inverter Driver
-- Emits: PV, Battery, Meter
-- Register type: INPUT (FC 0x04)
-- Port: 502
-- Community tier (untested)
--
-- Register map: KSTAR "Hybrid Inverter MODBUS RS485 Communication Protocol"
-- V2.9.1 (2024-07-21, document SFT-KSE-001), table 3.1 "Inverter basic
-- information", read-only input registers from 3000. Its model table
-- (3.1.5) covers the KSE single-phase models, the BluE-S 3680D/5000D/6000D
-- (and M1) and the E8KT/E10KT/E12KT three-phase models. Signs, which the
-- vendor does not state, are taken from davidrapan/ha-solarman
-- kstar_hybrid.yaml; addresses and scales agree with it and with
-- StephanJoubert/home_assistant_solarman kstar_hybrid.yaml (written from
-- V2.5). No code was copied.

-- No control code has been written for this inverter yet: driver_command
-- only refuses. It says read_only so FTW and the catalog tell the owner
-- plainly, instead of offering control that cannot work.
DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "kstar",
  name         = "KSTAR inverter",
  manufacturer = "KSTAR",
  version      = "1.3.0",
  protocols    = { "modbus" },
  capabilities = { "pv", "battery", "meter" },
  read_only    = true,
  description  = "KSTAR KSE and BluE-S series inverters via Modbus TCP. Read-only: no control code has been written for it yet, so FTW reads it but cannot charge or discharge the battery.",
}

PROTOCOL = "modbus"

-- Reading a register the device does not have costs a failed read on every
-- poll forever, and the host counts those against the poll whether or not Lua
-- caught the error. Enough of them and the site is marked offline and reports
-- nothing at all, which is worse than reporting one field less. So stop asking
-- once a register has proved it is not there. Three tries, because one failure
-- proves nothing -- the link may just have been slow.
--
-- A short reply counts as a failure: every register asked for must be there,
-- or a decode further down would do arithmetic on nil.
local GIVE_UP_AFTER = 3
local read_failures = {}

local function probe_read(addr, count, kind)
    if (read_failures[addr] or 0) >= GIVE_UP_AFTER then return nil end
    local ok, regs = pcall(host.modbus_read, addr, count, kind)
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
            "KSTAR: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

local function plausible_temp(c)
    if c < -40 or c > 100 then return nil end
    return c
end

-- Inverter model, input 3045, KSTAR table 3.1.5: 0x00-0x1F are the
-- single-phase KSE and BluE-S models, 0x20-0x2F the three-phase ones. The
-- S and T phase meter registers (3101-3108) are "only for three phase
-- model". The model does not change, so it is read until it answers once.
-- nil until known; "single", "three", or "unknown" for a code outside the
-- table.
local phases = nil

local function detect_phases()
    if phases ~= nil then return phases end
    local regs = probe_read(3045, 1, "input")
    if not regs then return nil end
    local code = regs[1]
    if code <= 0x1F then
        phases = "single"
    elseif code <= 0x2F then
        phases = "three"
    else
        phases = "unknown"
        host.log("warn", string.format(
            "KSTAR: inverter model code 0x%02X is not in KSTAR's model table; " ..
            "grid meter left out", code))
    end
    return phases
end

function driver_init(config)
    host.set_make("KSTAR")
end

function driver_poll()
    -- ---- PV ----
    --
    -- 3000-3025 in one read:
    --   3000 PV1 input voltage   U16 x 0.1 V
    --   3012 PV1 input current   S16 x 0.01 A
    --   3024 PV1 input power     S16, 1 W
    --   3025 PV2 input power     S16, 1 W
    local pv_regs = probe_read(3000, 26, "input")
    if pv_regs then
        local pv_w = host.decode_i16(pv_regs[25]) + host.decode_i16(pv_regs[26])
        host.emit("pv", {
            W       = -pv_w,  -- generation is negative (site convention)
            mppt1_v = pv_regs[1] * 0.1,
            mppt1_a = host.decode_i16(pv_regs[13]) * 0.01,
        })
    end

    -- ---- Battery ----
    --
    -- 3055-3067 in one read:
    --   3055 inverter radiator temperature   S16 x 0.1 C
    --   3063 battery voltage                 U16 x 0.01 V
    --   3065 battery charge/discharge power  S16, 1 W
    --   3066 battery SOC                     U16 x 0.1 %
    --   3067 battery temperature             S16 x 0.1 C
    -- 3056 is the battery converter's heatsink, not the battery, and is not
    -- used. KSTAR does not give the sign of 3065. ha-solarman's KSTAR
    -- profile counts it as power into the DC bus (its "Power losses" sensor
    -- is PV + battery - inverter output), so positive is discharging, and
    -- the driver negates it (site convention: charging is positive).
    --
    -- 3070/3071 BAT_CHG_LIMIT_CURR / BAT_DISCHG_LIMIT_CURR (1 A) are not
    -- sent as available power: the map does not say whether they come from
    -- the BMS or move with it. 3078/3079 are percent settings.
    local bat_regs = probe_read(3055, 13, "input")
    if bat_regs then
        local battery = {
            W = -host.decode_i16(bat_regs[11]),   -- 3065
            V = bat_regs[9] * 0.01,               -- 3063
        }
        local soc_raw = bat_regs[12]              -- 3066
        if soc_raw <= 1000 then
            battery.SoC_nom_fract = soc_raw / 1000
        end
        local bat_temp_c = plausible_temp(host.decode_i16(bat_regs[13]) * 0.1)  -- 3067
        battery.temperature_C = bat_temp_c
        host.emit("battery", battery)
        if bat_temp_c ~= nil then
            host.emit_metric("battery_temp_c", bat_temp_c)
        end
        local inverter_c = plausible_temp(host.decode_i16(bat_regs[1]) * 0.1)  -- 3055
        if inverter_c ~= nil then
            host.emit_metric("inverter_temp_c", inverter_c)
        end
    end

    -- ---- Meter ----
    --
    -- 3097-3108, four registers per phase (R, S, T):
    --   3097 grid voltage    U16 x 0.1 V
    --   3098 grid frequency  U16 x 0.01 Hz
    --   3099 meter current   S16 x 0.001 A
    --   3100 meter power     S16, 1 W
    -- KSTAR does not give the sign of the meter power. ha-solarman negates
    -- it "to match standard behavior of the other inverters" (import
    -- positive), and an owner there reported the raw value negative while
    -- importing. So the raw value is positive when exporting, and the
    -- driver negates it. The current is sent as read; its sign is not
    -- documented.
    local p = detect_phases()
    local m_regs = nil
    if p == "single" then
        m_regs = probe_read(3097, 4, "input")
    elseif p == "three" then
        m_regs = probe_read(3097, 12, "input")
    end
    if m_regs then
        local w = host.decode_i16(m_regs[4])
        if p == "three" then
            w = w + host.decode_i16(m_regs[8]) + host.decode_i16(m_regs[12])
        end
        host.emit("meter", {
            W    = -w,
            L1_V = m_regs[1] * 0.1,
            L1_A = host.decode_i16(m_regs[3]) * 0.001,
            Hz   = m_regs[2] * 0.01,
        })
    end

    return 5000
end

function driver_command(action, power_w, cmd)
    host.log("KSTAR control not yet implemented: " .. action)
    return false
end

function driver_default_mode()
end

function driver_cleanup()
    -- nothing to clean up
end
