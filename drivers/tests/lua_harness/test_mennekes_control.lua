-- Mennekes control on both maps: the ECU (AMTRON Professional, Charge
-- Control) and the HCC3 (AMTRON Xtra, Premium). Whole amps, caps, pause and
-- resume, the ECU refresh, default mode and honest results.
dofile("drivers/tests/lua_harness/host_mock.lua")
local driver = "drivers/lua/mennekes.lua"

local H, I
local function hi_lo(addr, v) H[addr], H[addr + 1] = v // 65536, v % 65536 end
-- 0xFFFFFFFF does not fit the harness's 32-bit integers, so set the words.
local function absent(addr) H[addr], H[addr + 1] = 0xFFFF, 0xFFFF end
local function lo_hi(addr, v) I[addr], I[addr + 1] = v % 65536, v // 65536 end

-- An ECU with a car charging at 16 A on three phases.
local function ecu(opts)
    opts = opts or {}
    H = host._modbus_registers.holding
    I = host._modbus_registers.input
    H[104] = opts.ocpp or 6
    H[122] = opts.vehicle or 3
    H[131], H[132] = 6, opts.timeout or 60
    for i = 0, 2 do
        absent(200 + 2 * i)                 -- per-phase energy: none
        hi_lo(206 + 2 * i, (opts.power or 11000) // 3)
        hi_lo(212 + 2 * i, (opts.phase_ma or {})[i + 1] or opts.amps_ma or 16000)
        hi_lo(222 + 2 * i, 231)
    end
    hi_lo(200, 987654)
    hi_lo(218, 987654)
    hi_lo(220, opts.power or 11000)
    H[705], H[706] = 1234, opts.signaled or 16
    hi_lo(716, 1234)
    H[1000] = 32
    host._modbus_read_fail_addresses[0x0302] = "Illegal Data Address"
end

-- An HCC3 with a car charging; power and energy low word first.
local function hcc3(opts)
    opts = opts or {}
    H = host._modbus_registers.holding
    I = host._modbus_registers.input
    host._modbus_read_fail_addresses[122] = "Illegal Data Address"
    I[0x0302] = opts.cp or 6
    I[0x0304] = opts.error or 0
    I[0x0305] = 3
    I[0x0308] = opts.phases or 3
    I[0x0309], I[0x030A] = 32, opts.installed or 16
    lo_hi(0x030B, 12345678)
    lo_hi(0x030D, 2500)
    lo_hi(0x030F, opts.power or 11000)
    H[0x0400] = 16
end

local function boot(kind, opts, config)
    host.reset()
    DRIVER, driver_command, driver_default_mode = nil, nil, nil
    dofile(driver)
    if kind == "hcc3" then hcc3(opts) else ecu(opts) end
    driver_init(config or {})
end

local REG
local function writes()
    local out = {}
    for _, c in ipairs(host._calls) do
        if c.func == "modbus_write" or c.func == "modbus_write_multiple" then
            assert(c.func == "modbus_write" and c.args[1] == REG,
                "wrote " .. c.func .. " " .. tostring(c.args[1]))
            out[#out + 1] = c.args[2]
        end
    end
    return out
end
local function last() local w = writes(); return w[#w] end
local function count() return #writes() end
local function later(ms) host._millis_counter = host._millis_counter + ms end
local function order(w, cmd)
    return driver_command("ev_set_current", w,
        cmd or { phase_mode = "3p", voltage = 230, max_amps_per_phase = 25 })
end

for _, kind in ipairs({ "ecu", "hcc3" }) do
    REG = kind == "hcc3" and 0x0400 or 1000

    -- 1. Detection, then whole amps rounded down, and the minimum.
    boot(kind, { vehicle = 2, ocpp = 5, cp = 4, power = 0, amps_ma = 0 })
    driver_poll()
    assert(order(11040)); assert(last() == 16, kind .. ": 11040 W 3p is 16 A")
    assert(order(7000)); assert(last() == 10, kind .. ": 7000 W 3p rounds down to 10 A")
    assert(order(4140)); assert(last() == 6, kind .. ": 4140 W 3p is exactly 6 A")
    assert(order(4000)); assert(last() == 0, kind .. ": below 6 A must write 0")
    assert(order(3680, { phase_mode = "1p", voltage = 230 }))
    assert(last() == 0, kind .. ": a 1p order on an idle three-phase charger divides by three")
    assert(driver_command("ev_start", 0, {}), kind .. ": start after an order")

    -- 2. Caps.
    assert(order(11040, { phase_mode = "3p", voltage = 230, max_amps_per_phase = 10 }))
    assert(last() == 10, kind .. ": max_amps_per_phase must cap")
    assert(order(11040, { phase_mode = "3p", voltage = 230, max_amps_per_phase = 25, cap_amps_per_phase = 7.9 }))
    assert(last() == 7, kind .. ": cap_amps_per_phase must cap and round down")
    assert(order(50000, { phase_mode = "3p", voltage = 230 }))
    assert(last() == (kind == "hcc3" and 16 or 32),
        kind .. ": device ceiling, got " .. tostring(last()))

    -- 3. Pause and resume, through Core's contactor cycle.
    boot(kind)
    driver_poll()
    assert(driver_command("ev_resume", 0, {}) == false, kind .. ": resume before any order must say no")
    assert(count() == 0, kind .. ": resume before any order wrote")
    assert(order(11040)); assert(last() == 16)
    assert(driver_command("ev_pause", 0, {})); assert(last() == 0, kind .. ": pause must write 0")
    later(3000); local n = count()
    assert(order(11040)); assert(count() == n, kind .. ": an order inside the pause hold reopened")
    assert(driver_command("ev_resume", 0, {})); assert(last() == 16, kind .. ": resume must restore")

    -- 4. Default mode: nothing unless FTW wrote; then 0 A once.
    boot(kind)
    driver_poll()
    assert(driver_default_mode()); assert(count() == 0, kind .. ": default mode wrote unasked")
    assert(order(11040))
    assert(driver_default_mode()); assert(last() == 0, kind .. ": default mode must write 0")
    local settled = count()
    for _ = 1, 5 do later(20000); assert(driver_default_mode()) end
    assert(count() == settled, kind .. ": default mode did not settle")

    -- 5. Honest results.
    boot(kind)
    driver_poll()
    assert(order(11040))
    host._modbus_write_error = "modbus exception function=0x06 code=0x02"
    assert(order(6900) == false, kind .. ": a refused write must return false")
    -- After FTW wrote, a refused stand-down says false: a car may still be
    -- charging. It is tried again once a minute, not on every call, and says
    -- true only once the charger takes 0 A.
    local function standdown(expect_write)
        local b = host._modbus_write_attempts
        local result = driver_default_mode()
        local wrote = host._modbus_write_attempts - b
        assert(wrote == (expect_write and 1 or 0),
            kind .. ": stand-down wrote " .. wrote .. " times")
        return result
    end
    assert(standdown(true) == false, kind .. ": a refused stand-down must say false")
    for _ = 1, 5 do
        later(5000)
        assert(standdown(false) == false, kind .. ": retried inside a minute, or said true")
    end
    later(35000)
    assert(standdown(true) == false, kind .. ": not retried after a minute")
    later(30000)
    assert(standdown(false) == false, kind .. ": retried inside a minute")
    host._modbus_write_error = nil
    later(31000)
    assert(standdown(true) == true, kind .. ": a stand-down the charger took must say true")
    for _ = 1, 3 do assert(standdown(false) == true, kind .. ": did not settle") end

    -- 6. A limit someone changed in the app is written back, at a slow pace.
    boot(kind)
    driver_poll()
    assert(order(11040)); n = count()
    H[REG] = 32; driver_poll()
    later(31000); assert(order(11040)); assert(count() == n + 1, kind .. ": changed limit not restored")
end

-- ECU phases: only a measurement or config makes one phase.
REG = 1000
local P1 = { phase_mode = "1p", voltage = 230, max_amps_per_phase = 25 }
boot("ecu")
driver_poll()
assert(order(7360, P1)); assert(last() == 10, "ecu: three phases measured on a 1p order")
boot("ecu", { phase_ma = { 15000, 0, 0 } })
driver_poll()
assert(order(3680, P1)); assert(last() == 16, "ecu: one phase measured, got " .. tostring(last()))
H[122] = 1; driver_poll()          -- unplugged
H[122], H[104] = 2, 5; driver_poll() -- plugged in again, not charging yet
assert(order(3680, P1)); assert(last() == 0, "ecu: first order after a re-plug")
boot("ecu", { vehicle = 2, ocpp = 5, amps_ma = 0, power = 0 }, { phases = 1 })
driver_poll()
assert(order(3680, P1)); assert(last() == 16, "ecu: config phases: 1")

-- HCC3 phases: no currents are measured, and 0x0308 is a floor.
REG = 0x0400
boot("hcc3", { installed = 32 })
driver_poll()
assert(order(7360, P1)); assert(last() == 10, "hcc3: 0x0308 = 3 must divide by three, got " .. tostring(last()))
boot("hcc3", { installed = 32 }, { phases = 1 })
driver_poll()
assert(order(3680, P1)); assert(last() == 0, "hcc3: config phases: 1 against 0x0308 = 3")
boot("hcc3", { installed = 32, phases = 1 })
driver_poll()
assert(order(3680, P1)); assert(last() == 0, "hcc3: 0x0308 = 1 alone is not proof")
boot("hcc3", { installed = 32, phases = 1 }, { phases = 1 })
driver_poll()
assert(order(3680, P1)); assert(last() == 16, "hcc3: config and charger agree on one phase")

-- ECU refresh and readings.
REG = 1000
boot("ecu")
driver_poll()
assert(order(11040)); assert(count() == 1)
later(5000); assert(order(11040)); assert(count() == 1, "ecu: rewrote within 5 s")
later(11000); assert(order(11040)); assert(count() == 2, "ecu: no refresh after 16 s")
boot("ecu", { timeout = 12 })
driver_poll()
assert(order(11040)); later(4500); assert(order(11040))
assert(count() == 2, "ecu: a 12 s COMM_TIMEOUT needs a refresh every 4 s")

boot("ecu")
driver_poll()
local e = host._emitted.ev[#host._emitted.ev]
assert(e.w == 11000 and e.connected == true and e.charging == true and e.request_active == true)
assert(e.session_wh == 1234 and e.total_charge_wh == 987654 and e.max_a == 32)
assert(e.current_limit_a == 16 and e.l1_v == 231 and e.l3_a == 16 and e.phases == 3)
H[122], H[104], H[706] = 2, 7, 16; driver_poll()
e = host._emitted.ev[#host._emitted.ev]
assert(e.charging == false and e.request_active == false, "ecu: B with an offer is a car not asking")
-- Older firmware: no 218..227, total in the L1 registers.
boot("ecu")
host._modbus_read_fail_addresses[218] = "Illegal Data Address"
hi_lo(206, 11000); absent(208); absent(210)
for _ = 1, 4 do driver_poll() end
e = host._emitted.ev[#host._emitted.ev]
assert(e.w == 11000 and e.total_charge_wh == 987654 and e.l1_v == nil, "ecu: old firmware power")
local reads218 = 0
for _, c in ipairs(host._calls) do
    if c.func == "modbus_read" and c.args[1] == 218 then reads218 = reads218 + 1 end
end
assert(reads218 == 3, "ecu: an absent register must be dropped after three tries")
-- No meter at all: nothing to report.
boot("ecu")
for i = 0, 2 do absent(206 + 2 * i) end
absent(220)
local before = #(host._emitted.ev or {})
driver_poll()
assert(#(host._emitted.ev or {}) == before, "ecu: emitted without a power reading")

-- HCC3 readings.
REG = 0x0400
boot("hcc3")
driver_poll()
assert(host._sn == "12345678", "hcc3 serial: " .. tostring(host._sn))
e = host._emitted.ev[#host._emitted.ev]
assert(e.w == 11000 and e.connected == true and e.charging == true and e.session_wh == 2500)
assert(e.max_a == 16 and e.phases == 3 and e.l1_a == nil)
I[0x0302] = 3; driver_poll()   -- B1 under our offer
assert(order(11040)); driver_poll(); later(31000); driver_poll()
e = host._emitted.ev[#host._emitted.ev]
assert(e.command_stalled == true and e.reason_no_current_label == "charger not offering current")

-- A configured family skips detection.
boot("ecu", nil, { family = "ecu" })
driver_poll()
for _, c in ipairs(host._calls) do
    assert(not (c.func == "modbus_read" and c.args[3] == "input"), "configured ecu probed the HCC3 map")
end

-- Detection that fails at boot is retried once a minute, not never.
host.reset()
DRIVER, driver_command, driver_default_mode = nil, nil, nil
dofile(driver)
H = host._modbus_registers.holding
I = host._modbus_registers.input
driver_init({})
host._modbus_read_fail_addresses[122] = "timeout"
host._modbus_read_fail_addresses[0x0302] = "timeout"
for _ = 1, 10 do driver_poll(); later(5000) end
assert(host._emitted.ev == nil)
host._modbus_read_fail_addresses[0x0302] = nil
hcc3()
host._modbus_read_fail_addresses[0x0302] = nil
later(25000); driver_poll(); driver_poll()
assert(host._emitted.ev and #host._emitted.ev > 0, "charger offline at boot never came back")

print("mennekes control: ok")
