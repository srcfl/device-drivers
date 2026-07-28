-- Acrel DTSD1352 Three-Phase Meter Driver
-- Emits: Meter only
-- Register type: HOLDING (FC 0x03)
-- U16 for voltage/current/frequency, I32 for power, U32 for energy
-- Default port 502

PROTOCOL = "modbus"

-- Bounded register probe.
-- The host counts every failed host.modbus_read against the poll, even one
-- pcall caught here. A driver that keeps emitting while a register keeps
-- failing is marked offline by the stale-telemetry watchdog, and the site
-- then reports nothing at all. So: three tries, then leave the register
-- alone. Three rather than one because a single failure is not proof the
-- register is missing -- the link may just have been slow.
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
            "Acrel: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

function driver_init(config)
    host.set_make("Acrel")
end

function driver_poll()
    -- Per-phase voltage: 96(0x60), 97, 98 (U16, 0.1V)
    local v_regs = probe_read(96, 3, "holding")
    local l1_v, l2_v, l3_v = 0, 0, 0
    if v_regs then
        l1_v = v_regs[1] * 0.1
        l2_v = v_regs[2] * 0.1
        l3_v = v_regs[3] * 0.1
    end

    -- Per-phase current: 99(0x63), 100, 101 (U16, 0.001A)
    local a_regs = probe_read(99, 3, "holding")
    local l1_a, l2_a, l3_a = 0, 0, 0
    if a_regs then
        l1_a = a_regs[1] * 0.001
        l2_a = a_regs[2] * 0.001
        l3_a = a_regs[3] * 0.001
    end

    -- Total active power: 102(0x66) (I32, W)
    local tw_regs = probe_read(102, 2, "holding")
    local total_w = 0
    if tw_regs then
        total_w = host.decode_i32_be(tw_regs[1], tw_regs[2])
    end

    -- Frequency: 110(0x6E) (U16, 0.01Hz)
    local hz_regs = probe_read(110, 1, "holding")
    local hz = 0
    if hz_regs then
        hz = hz_regs[1] * 0.01
    end

    -- Import energy: 0(0x00) (U32, 0.01kWh -> Wh)
    local imp_regs = probe_read(0, 2, "holding")
    local import_wh = 0
    if imp_regs then
        import_wh = host.decode_u32_be(imp_regs[1], imp_regs[2]) * 10
    end

    -- Export energy: 8(0x08) (U32, 0.01kWh -> Wh)
    local exp_regs = probe_read(8, 2, "holding")
    local export_wh = 0
    if exp_regs then
        export_wh = host.decode_u32_be(exp_regs[1], exp_regs[2]) * 10
    end

    -- Derive per-phase power from voltage * current (no per-phase power registers)
    local l1_w = l1_v * l1_a
    local l2_w = l2_v * l2_a
    local l3_w = l3_v * l3_a

    host.emit("meter", {
        W         = total_w,
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

    return 5000
end

function driver_cleanup()
    -- nothing to clean up
end
