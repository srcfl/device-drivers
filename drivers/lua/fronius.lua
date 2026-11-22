-- fronius.lua
-- Fronius Symo / Primo GEN24 hybrid inverter driver
-- Emits: PV, Battery, Meter
-- Protocol: Modbus TCP (SunSpec), ALL HOLDING registers
-- Ported from sourceful-hugin/device-support/drivers/lua/fronius.lua
-- Port notes (v2.1 API drift vs hugin):
--   host.log(msg)           → host.log("info", msg)
--   host.decode_u32/i32     → _be variants
--   host.decode_f32         → inline IEEE-754 (two u16, big-endian words)
--   host.scale(v, sf)       → local apply_sf(v, sf)

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "fronius",
  name         = "Fronius GEN24",
  manufacturer = "Fronius",
  version      = "2.3.0",
  protocols    = { "modbus" },
  capabilities = { "pv", "battery" },
  read_only    = true,
  description  = "Fronius Symo / Primo GEN24 hybrid inverters via Modbus TCP (SunSpec).",
  homepage     = "https://www.fronius.com",
  authors      = { "FTW contributors" },
  tested_models = { "Symo GEN24", "Primo GEN24" },
  verification_status = "experimental",
  verification_notes = "Ported from a reference implementation. Not yet verified against live hardware on a FTW site.",
  connection_defaults = {
    port    = 502,
    unit_id = 1,
  },
}
--
-- Register conventions:
--   All registers read as FC 0x03 (holding).
--   Inverter scalar values (AC power, frequency, DC power, per-phase V/A)
--   are SunSpec IEEE 754 float32, two consecutive u16 registers, big-endian
--   word order (high word first).
--   MPPT, battery, and rated-power values are u16/i16 raw + a signed
--   int16 scale factor in a separate register.
--
-- Sign convention (site/EMS):
--   meter.w  : positive = importing from grid, negative = exporting
--   pv.w     : always <= 0 (generation pushes to site)
--   battery.w: positive = charging (into battery), negative = discharging

PROTOCOL = "modbus"

local sn_read = false

----------------------------------------------------------------------------
-- Local decoders (replace host.decode_f32 / host.scale from hugin v1.x)
----------------------------------------------------------------------------

-- Apply a SunSpec int16 scale factor: value * 10^sf.
-- sf is typically in the range [-3, 3]; split on sign to avoid 10^(-n)
-- rounding quirks.
local function apply_sf(v, sf)
    if sf >= 0 then
        return v * (10 ^ sf)
    else
        return v / (10 ^ -sf)
    end
end

-- Decode IEEE 754 single-precision float from two u16 registers,
-- big-endian word order: hi = first register, lo = second.
--
-- Works on the 16-bit halves (docs/WRITING-A-DRIVER.md, "Numbers"). Earlier
-- versions joined the words into one 32-bit number and compared it with
-- 0x80000000, which is negative where Lua integers are 32 bits, so every
-- float came out negative there (the harness, and any 32-bit host). FTW and
-- Blixt L1 use 64-bit integers and were not affected. ferroamp_modbus had the
-- same fault (srcfl/device-drivers#254).
--
-- NaN and infinity give nil. Fronius answers NaN (0x7FC00000) for a point it
-- does not support, and earlier versions turned that into 0, a reading
-- nobody took.
local function decode_f32_be(hi, lo)
    if hi == nil or lo == nil then return nil end
    hi = hi % 0x10000
    lo = lo % 0x10000
    local sign = 1
    if hi >= 0x8000 then sign = -1; hi = hi - 0x8000 end
    local exponent = math.floor(hi / 0x80)
    local mantissa = (hi % 0x80) * 0x10000 + lo
    if exponent == 0xFF then return nil end
    if exponent == 0 then
        if mantissa == 0 then return 0 end
        return sign * mantissa * 2 ^ -149
    end
    return sign * (1 + mantissa / 0x800000) * 2 ^ (exponent - 127)
end

-- A temperature from two float32 registers (high word first), or nil when
-- the read failed, the device has no value, or it is outside -40..100 °C
-- ("What a battery can do now").
local function decode_temp_f32_be(hi, lo)
    local v = decode_f32_be(hi, lo)
    if v == nil or v < -40 or v > 100 then return nil end
    return v
end

-- SunSpec marks a point it does not implement with 0xFFFF in a uint16 and
-- 0x8000 in a scale factor (SunSpec information model). Both give nil.
local function sunspec_sf(raw)
    if raw == nil or raw == 0x8000 then return nil end
    local sf = host.decode_i16(raw)
    if sf < -10 or sf > 10 then return nil end
    return sf
end

local function sunspec_u16(raw, sf)
    if raw == nil or sf == nil or raw == 0xFFFF then return nil end
    return apply_sf(raw, sf)
end

-- Turn a Lua array of u16s into an ASCII string, trimming NULs and spaces.
-- `first` is the index of the first register (default 1).
local function regs_to_string(regs, count, first)
    if not regs then return "" end
    first = first or 1
    local s = ""
    for i = first, first + count - 1 do
        local r = regs[i] or 0
        local hi = math.floor(r / 256)
        local lo = r % 256
        if hi > 32 and hi < 127 then s = s .. string.char(hi) end
        if lo > 32 and lo < 127 then s = s .. string.char(lo) end
    end
    return s
end

----------------------------------------------------------------------------
-- Initialization
----------------------------------------------------------------------------

-- Registers this device has stopped answering.
--
-- The host counts every failed host.modbus_read against the poll whether or
-- not this driver caught the error — "driver_poll: N of M modbus reads
-- failed". So a register retried on every poll costs a failed poll on every
-- poll, and the stale-telemetry watchdog takes the driver offline. The site
-- then reports nothing at all, which is worse than reporting one field less.
--
-- Three attempts absorb a transient blip; after that we stop asking. A
-- restart re-probes, so firmware that gains the register is picked up.
local GIVE_UP_AFTER = 3
local read_failures = {}

local function probe_read(addr, count, kind)
    if (read_failures[addr] or 0) >= GIVE_UP_AFTER then return nil end
    local ok, regs = pcall(host.modbus_read, addr, count, kind)
    if ok and regs and regs[1] ~= nil then
        read_failures[addr] = nil
        return regs
    end
    local failures = (read_failures[addr] or 0) + 1
    read_failures[addr] = failures
    if failures == GIVE_UP_AFTER then
        host.log("info", string.format(
            "Fronius: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

----------------------------------------------------------------------------
-- The SunSpec model chain: MPPT inputs and storage
--
-- Source: Fronius's register map bundle 1.2.7-2 (QR-link/0024 in the
-- manifest), the float maps for GEN24 and Verto, with and without storage,
-- and the GEN24 Modbus manual 42,0410,2649. Fronius numbers registers from 1;
-- the wire address is one lower.
--
-- Model 160 (Multiple MPPT) starts at register 40264, wire 40263 ("start
-- address for 'float' setting: 40263"). Its length L is 8 + 20 x N, one
-- 20-register block per DC input. With storage, N counts the MPPT trackers
-- plus two blocks for the battery: "StCha" (charge) and then "StDisCha"
-- (discharge), the last two. A GEN24 has N = 4 (L = 88); a Verto with three
-- trackers has N = 5 (L = 108); without storage N is the number of trackers.
--
-- Model 124 (Basic Storage Control) "is only available for inverters with a
-- storage solution" and follows model 160 directly. Without storage the end
-- block (0xFFFF) is there instead, and it answers, so the driver learns there
-- is no battery without a failed read. Earlier versions read model 124 at
-- fixed addresses that assume a two-input model 160, which on a GEN24 with
-- storage are inside model 160's battery blocks.
--
-- The int+SF maps start model 160 at 40254 and use a different inverter
-- model. This driver reads the float maps only; when model 160 is not at
-- 40264 it reads no DC input or battery values rather than guess.
----------------------------------------------------------------------------

local MPPT_ADDR = 40263     -- wire address of model 160's ID
local MAX_READ = 125        -- registers in one Modbus read

local mppt_len = nil        -- L of model 160, from its header
local mppt_missing = false  -- model 160 is not where the float map puts it
local storage_addr = nil    -- wire address of model 124's ID, with storage
local storage_checked = false
local mppt_logged = false

-- A battery fitted after the driver started changes the chain: model 160
-- grows by the two battery blocks and model 124 appears after it. So while
-- no storage model is known the driver looks again every five minutes, and
-- at once when model 160's own length no longer matches. That costs two
-- short reads every five minutes on an inverter without a battery.
local RECHECK_MS = 5 * 60 * 1000
local checked_at = nil

local function forget_models()
    mppt_len = nil
    mppt_missing = false
    storage_addr = nil
    storage_checked = false
    checked_at = nil
end

local function find_models()
    if storage_addr == nil and checked_at ~= nil
            and host.millis() - checked_at >= RECHECK_MS then
        forget_models()
    end
    if mppt_len == nil and not mppt_missing then
        local hdr = probe_read(MPPT_ADDR, 2, "holding")
        if hdr == nil or hdr[2] == nil then
            -- A model 160 that never answers is treated as absent.
            if (read_failures[MPPT_ADDR] or 0) >= GIVE_UP_AFTER then
                mppt_missing = true
                checked_at = host.millis()
            end
            return
        end
        local len = hdr[2]
        if hdr[1] == 160 and len >= 28 and (len - 8) % 20 == 0
                and len + 2 <= MAX_READ then
            mppt_len = len
        else
            mppt_missing = true
            checked_at = host.millis()
            if not mppt_logged then
                mppt_logged = true
                host.log("info", string.format(
                    "Fronius: register 40264 holds model %d, not 160; reading no " ..
                    "DC input or battery values (is Modbus set to 'float'?)", hdr[1]))
            end
            return
        end
    end
    if mppt_len ~= nil and not storage_checked then
        local addr = MPPT_ADDR + 2 + mppt_len
        local nxt = probe_read(addr, 2, "holding")
        if nxt == nil or nxt[2] == nil then return end
        storage_checked = true
        checked_at = host.millis()
        if nxt[1] == 124 and nxt[2] == 24 then storage_addr = addr end
    end
end

-- Offsets within one read of model 160 (index 1 = its ID). Module k's block
-- starts at index 11 + 20 x (k - 1): ID, IDStr (8 registers), DCA, DCV, DCW.
local function module_base(k) return 11 + 20 * (k - 1) end

local function module_name(regs, k)
    return regs_to_string(regs, 8, module_base(k) + 1)
end

function driver_init(config)
    host.set_make("Fronius")
end

----------------------------------------------------------------------------
-- Telemetry polling
----------------------------------------------------------------------------

function driver_poll()
    -- Read SunSpec Common block serial number once (40052, 16 regs = 32 chars).
    -- Some gateways don't expose the common block; fall back silently.
    if not sn_read then
        local sn_regs = probe_read(40052, 16, "holding")
        if sn_regs then
            local sn = regs_to_string(sn_regs, 16)
            if #sn > 0 then
                host.set_sn(sn)
                sn_read = true
            end
        end
    end

    find_models()

    -- ---------------------------------------------------------------- PV
    -- Inverter/AC values are SunSpec F32 BE pairs (model 113).

    local ac_w = nil
    local acw_regs = probe_read(40091, 2, "holding")
    if acw_regs then ac_w = decode_f32_be(acw_regs[1], acw_regs[2]) end

    local hz = nil
    local hz_regs = probe_read(40093, 2, "holding")
    if hz_regs then hz = decode_f32_be(hz_regs[1], hz_regs[2]) end

    local lifetime_wh = nil
    local le_regs = probe_read(40101, 2, "holding")
    if le_regs then lifetime_wh = decode_f32_be(le_regs[1], le_regs[2]) end

    -- DCW, model 113 "DC Power". Used for PV only without a battery input
    -- (see "PV power" below).
    local dc_w = nil
    local dcw_regs = probe_read(40107, 2, "holding")
    if dcw_regs then dc_w = decode_f32_be(dcw_regs[1], dcw_regs[2]) end

    -- Inverter temperature: TmpCab "Cabinet Temperature", float32 °C, model
    -- 113 registers 40110-40111 in Fronius's 1-based numbering, so address
    -- 40109 on the wire. Earlier versions read 40111, which is TmpSnk; the
    -- GEN24, Tauro and Verto maps mark TmpSnk "not supported", so it answered
    -- NaN and the driver sent 0 °C. Left out when the read fails or the
    -- device has no value.
    local cabinet_c = nil
    local temp_regs = probe_read(40109, 2, "holding")
    if temp_regs then cabinet_c = decode_temp_f32_be(temp_regs[1], temp_regs[2]) end

    -- Rated W: WRtg and WRtg_SF, model 120 registers 40135-40136, one read.
    local rated_w = nil
    local rw_regs = probe_read(40134, 2, "holding")
    if rw_regs then rated_w = sunspec_u16(rw_regs[1], sunspec_sf(rw_regs[2])) end

    -- Model 160 in one read, so the auto-scaled factors (DCA_SF, DCV_SF,
    -- DCW_SF) come with the values they scale. MPPT 1 and 2 are the first
    -- two blocks in every float map.
    local mppt = nil
    if mppt_len ~= nil then
        mppt = probe_read(MPPT_ADDR, 2 + mppt_len, "holding")
        if mppt and mppt[1] == 160 and mppt[2] ~= mppt_len then
            -- Model 160 changed length, for example a battery was fitted:
            -- find the chain again on the next poll.
            forget_models()
            mppt = nil
        elseif mppt and (mppt[1] ~= 160 or mppt[2 + mppt_len] == nil) then
            mppt = nil
        end
    end

    local mppt1_v, mppt1_a, mppt2_v, mppt2_a
    local dca_sf, dcv_sf, dcw_sf, modules
    if mppt then
        dca_sf = sunspec_sf(mppt[3])
        dcv_sf = sunspec_sf(mppt[4])
        dcw_sf = sunspec_sf(mppt[5])
        modules = mppt[9]
        if modules ~= nil and 8 + 20 * modules ~= mppt_len then modules = nil end
        if modules ~= nil and modules >= 1 then
            mppt1_a = sunspec_u16(mppt[module_base(1) + 9], dca_sf)
            mppt1_v = sunspec_u16(mppt[module_base(1) + 10], dcv_sf)
        end
        if modules ~= nil and modules >= 2 then
            mppt2_a = sunspec_u16(mppt[module_base(2) + 9], dca_sf)
            mppt2_v = sunspec_u16(mppt[module_base(2) + 10], dcv_sf)
        end
    end

    -- The battery blocks: the last two of model 160, named "StCha" and
    -- "StDisCha" in both storage maps. The names are checked, so a layout
    -- the driver does not know gives no battery blocks.
    local cha, dis = nil, nil
    if mppt and modules ~= nil and modules >= 3
            and module_name(mppt, modules - 1):sub(1, 5) == "StCha"
            and module_name(mppt, modules):sub(1, 8) == "StDisCha" then
        cha, dis = modules - 1, modules
    end

    -- PV power. Fronius's map does not say whether model 113's DC power
    -- includes the battery input, and evcc's fronius-gen24 template sums
    -- the MPPT blocks instead. So with storage PV is the sum of the MPPT
    -- blocks before the battery blocks; a 3 kW discharge then cannot show
    -- as 3 kW of sun. Model 113's DC power is used only where there is no
    -- battery input: no storage model after model 160, or a model 160 with
    -- no battery blocks. With storage and no readable battery blocks, PV is
    -- left out for that poll.
    local pv_dc_w = nil
    if cha ~= nil then
        local sum = 0
        for k = 1, cha - 1 do
            local w = sunspec_u16(mppt[module_base(k) + 11], dcw_sf)
            if w == nil then sum = nil; break end
            sum = sum + w
        end
        pv_dc_w = sum
    elseif storage_addr == nil and (mppt_missing or storage_checked
            or (mppt and modules ~= nil)) then
        pv_dc_w = dc_w
    end

    -- Per-phase AC current: 40073, 40075, 40077 (F32 BE pairs)
    local l1_a, l2_a, l3_a = nil, nil, nil
    local l1a_regs = probe_read(40073, 2, "holding")
    if l1a_regs then l1_a = decode_f32_be(l1a_regs[1], l1a_regs[2]) end
    local l2a_regs = probe_read(40075, 2, "holding")
    if l2a_regs then l2_a = decode_f32_be(l2a_regs[1], l2a_regs[2]) end
    local l3a_regs = probe_read(40077, 2, "holding")
    if l3a_regs then l3_a = decode_f32_be(l3a_regs[1], l3a_regs[2]) end

    -- Per-phase AC voltage: 40085, 40087, 40089 (F32 BE pairs)
    local l1_v, l2_v, l3_v = nil, nil, nil
    local l1v_regs = probe_read(40085, 2, "holding")
    if l1v_regs then l1_v = decode_f32_be(l1v_regs[1], l1v_regs[2]) end
    local l2v_regs = probe_read(40087, 2, "holding")
    if l2v_regs then l2_v = decode_f32_be(l2v_regs[1], l2v_regs[2]) end
    local l3v_regs = probe_read(40089, 2, "holding")
    if l3v_regs then l3_v = decode_f32_be(l3v_regs[1], l3v_regs[2]) end

    -- Emit PV (DC power magnitude → negative for generation, per site
    -- convention). DC power is PV's defining value: without it there is no
    -- PV reading. Each other field is left out when it did not answer.
    if pv_dc_w ~= nil then
        host.emit("pv", {
            w           = -pv_dc_w,
            mppt1_v     = mppt1_v,
            mppt1_a     = mppt1_a,
            mppt2_v     = mppt2_v,
            mppt2_a     = mppt2_a,
            lifetime_wh = lifetime_wh,
            temp_c      = cabinet_c,
            rated_w     = rated_w,
        })
    end
    -- Diagnostics: long-format TS DB
    if mppt1_v ~= nil then host.emit_metric("pv_mppt1_v", mppt1_v) end
    if mppt1_a ~= nil then host.emit_metric("pv_mppt1_a", mppt1_a) end
    if mppt2_v ~= nil then host.emit_metric("pv_mppt2_v", mppt2_v) end
    if mppt2_a ~= nil then host.emit_metric("pv_mppt2_a", mppt2_a) end
    if cabinet_c ~= nil then
        host.emit_metric("inverter_temp_c", cabinet_c)
    end
    if hz ~= nil then host.emit_metric("grid_hz", hz) end

    -- ----------------------------------------------------------- Battery
    --
    -- Only with storage, which model 124 following model 160 proves.
    --
    -- Power and voltage come from the two battery blocks of model 160 (see
    -- above). Fronius sets the charge block to 0
    -- while the battery discharges and the discharge block to 0 while it
    -- charges, so battery W = charge DCW - discharge DCW, positive charging
    -- (site convention; evcc's fronius-gen24 template reads it the same
    -- way). Both blocks carry the battery port's voltage since firmware
    -- 1.31; up to 1.30 only the active one did, so the driver takes the
    -- larger, and leaves the voltage out when both are 0.
    --
    -- SoC is model 124's ChaState (offset 8) x 10^ChaState_SF (offset 22),
    -- in percent: "Estimated_Capacity_Remaining [Wh] /
    -- Estimated_Capacity_Maximum [Wh]" (GEN24 manual).
    --
    -- Earlier versions took battery power from OutWRte / InWRte times
    -- WChaMax. Those are the owner's charge and discharge rate setpoints
    -- (WChaMax is max(MaxChaRte, MaxDisChaRte), a rating), not a measurement.
    --
    -- Fronius's maps carry no battery temperature and no live charge or
    -- discharge limit: model 124 has no temperature point, the battery
    -- blocks' Tmp is "not supported", InBatV is "not supported", and model
    -- 122's WAval (grid headroom) is "not supported". So none is sent.

    local bat_w, bat_v, bat_soc = nil, nil, nil
    if storage_addr ~= nil then
        if cha ~= nil then
            local cha_w = sunspec_u16(mppt[module_base(cha) + 11], dcw_sf)
            local dis_w = sunspec_u16(mppt[module_base(dis) + 11], dcw_sf)
            if cha_w ~= nil and dis_w ~= nil then bat_w = cha_w - dis_w end
            local cha_v = sunspec_u16(mppt[module_base(cha) + 10], dcv_sf)
            local dis_v = sunspec_u16(mppt[module_base(dis) + 10], dcv_sf)
            local v = math.max(cha_v or 0, dis_v or 0)
            if v > 0 then bat_v = v end
        end

        local st = probe_read(storage_addr, 23, "holding")
        if st and st[1] == 124 and st[23] ~= nil then
            local pct = sunspec_u16(st[9], sunspec_sf(st[23]))
            if pct ~= nil and pct >= 0 and pct <= 100 then bat_soc = pct / 100 end
        end
    end

    if bat_w ~= nil or bat_v ~= nil or bat_soc ~= nil then
        host.emit("battery", {
            w   = bat_w,
            v   = bat_v,
            soc = bat_soc,
        })
    end
    if bat_v ~= nil then host.emit_metric("battery_dc_v", bat_v) end

    -- NOTE: This driver does NOT emit meter telemetry. A Fronius inverter is
    -- NOT a grid meter — its AC output represents inverter production, not the
    -- grid boundary. Operators need a separate meter driver (fronius_smart_meter.lua,
    -- sdm630.lua, p1_meter.lua, etc.) with `is_site_meter: true` in config.yaml
    -- for accurate grid power readings.

    return 5000
end

----------------------------------------------------------------------------
-- Control (READ-ONLY driver — Fronius GEN24 battery control via SunSpec
-- requires the Modbus-control licence key and is not implemented here.)
----------------------------------------------------------------------------

function driver_command(action, power_w, cmd)
    if action == "init" or action == "deinit" then
        return true
    end
    host.log("warn", "Fronius: read-only driver, ignoring action=" .. tostring(action))
    return false
end

function driver_default_mode()
    -- Read-only: nothing to revert. Inverter runs its own self-consumption.
end

function driver_cleanup()
    sn_read = false
    forget_models()
end
