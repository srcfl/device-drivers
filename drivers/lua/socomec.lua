-- Socomec Diris A-10/A-20/A-40 Three-Phase Meter Driver
-- Emits: Meter only
-- Register type: HOLDING (FC 0x03)
-- U32/I32 with scaling
-- Default port 502

PROTOCOL = "modbus"

-- A register the meter never answers costs a failed read on every poll for as
-- long as the driver keeps asking. The host counts those failures against the
-- poll whether or not the pcall caught them, so a driver that keeps reporting
-- telemetry while permanently failing one read gets the whole site marked
-- offline. Give a register three chances, then leave it alone until restart.
-- Three rather than one: a single failure is not proof, the link may just
-- have been slow.
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
            "Socomec: register %d did not answer %d times; leaving it alone " ..
            "until restart", addr, GIVE_UP_AFTER))
    end
    return nil
end

function driver_init(config)
    host.set_make("Socomec")
end

function driver_poll()
    -- Per-phase voltage: 50520(0xC558), 50522, 50524 (U32, V)
    local v_regs = probe_read(50520, 6, "holding")
    local l1_v, l2_v, l3_v = 0, 0, 0
    if v_regs then
        l1_v = host.decode_u32_be(v_regs[1], v_regs[2])
        l2_v = host.decode_u32_be(v_regs[3], v_regs[4])
        l3_v = host.decode_u32_be(v_regs[5], v_regs[6])
    end

    -- Per-phase current: 50528(0xC560), 50530, 50532 (U32, mA -> A)
    local a_regs = probe_read(50528, 6, "holding")
    local l1_a, l2_a, l3_a = 0, 0, 0
    if a_regs then
        l1_a = host.decode_u32_be(a_regs[1], a_regs[2]) * 0.001
        l2_a = host.decode_u32_be(a_regs[3], a_regs[4]) * 0.001
        l3_a = host.decode_u32_be(a_regs[5], a_regs[6]) * 0.001
    end

    -- Total power: 50540(0xC56C) (I32, W)
    local tw_regs = probe_read(50540, 2, "holding")
    local total_w = 0
    if tw_regs then
        total_w = host.decode_i32_be(tw_regs[1], tw_regs[2])
    end

    -- Per-phase power: 50542(0xC56E), 50544, 50546 (I32, W)
    local w_regs = probe_read(50542, 6, "holding")
    local l1_w, l2_w, l3_w = 0, 0, 0
    if w_regs then
        l1_w = host.decode_i32_be(w_regs[1], w_regs[2])
        l2_w = host.decode_i32_be(w_regs[3], w_regs[4])
        l3_w = host.decode_i32_be(w_regs[5], w_regs[6])
    end

    -- Frequency: 50552(0xC578) (U32, 0.01Hz)
    local hz_regs = probe_read(50552, 2, "holding")
    local hz = 0
    if hz_regs then
        hz = host.decode_u32_be(hz_regs[1], hz_regs[2]) * 0.01
    end

    -- Import energy: 50770(0xC652) (U32+U32 -> high pair, Wh)
    local imp_regs = probe_read(50770, 4, "holding")
    local import_wh = 0
    if imp_regs then
        import_wh = host.decode_u32_be(imp_regs[1], imp_regs[2])
    end

    -- Export energy: 50782(0xC65E) (U32, Wh)
    local exp_regs = probe_read(50782, 2, "holding")
    local export_wh = 0
    if exp_regs then
        export_wh = host.decode_u32_be(exp_regs[1], exp_regs[2])
    end

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
