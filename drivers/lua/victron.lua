-- Victron Energy Venus OS Modbus TCP Driver (community, untested)
-- Emits: PV, Battery, Meter
-- Register type: HOLDING (FC 0x03)
-- Reads from Venus OS GX device as Modbus server, unit ID 100 (system summary)
--
-- Sign convention:
--   PV W: negative (generation)
--   Battery W: positive = charging, negative = discharging
--   Meter W: positive = import, negative = export

PROTOCOL = "modbus"

function driver_init(config)
    host.set_make("Victron")
end

function driver_poll()
    -- ---- PV Values ----

    -- PV AC power: 808 (U16, W)
    local ok_pvac, pvac_regs = pcall(host.modbus_read, 808, 1, "holding")
    local pv_ac_w = 0
    if ok_pvac then
        pv_ac_w = pvac_regs[1]
    end

    -- PV DC power: 850 (U16, W)
    local ok_pvdc, pvdc_regs = pcall(host.modbus_read, 850, 1, "holding")
    local pv_dc_w = 0
    if ok_pvdc then
        pv_dc_w = pvdc_regs[1]
    end

    -- Total PV = AC + DC, negate for generation convention
    local pv_total = pv_ac_w + pv_dc_w

    -- Emit PV telemetry
    host.emit("pv", {
        w = -pv_total,
    })

    -- ---- Grid / Meter Values ----

    -- Grid L1 power: 820 (I16, W), L2: 821, L3: 822
    local ok_gw, gw_regs = pcall(host.modbus_read, 820, 3, "holding")
    local grid_l1_w, grid_l2_w, grid_l3_w = 0, 0, 0
    if ok_gw then
        grid_l1_w = host.decode_i16(gw_regs[1])
        grid_l2_w = host.decode_i16(gw_regs[2])
        grid_l3_w = host.decode_i16(gw_regs[3])
    end

    -- Grid L1 voltage: 823 (U16, 0.1V), L2: 824, L3: 825
    local ok_gv, gv_regs = pcall(host.modbus_read, 823, 3, "holding")
    local grid_l1_v, grid_l2_v, grid_l3_v = 0, 0, 0
    if ok_gv then
        grid_l1_v = gv_regs[1] * 0.1
        grid_l2_v = gv_regs[2] * 0.1
        grid_l3_v = gv_regs[3] * 0.1
    end

    -- Grid L1 current: 826 (I16, 0.1A), L2: 827, L3: 828
    local ok_ga, ga_regs = pcall(host.modbus_read, 826, 3, "holding")
    local grid_l1_a, grid_l2_a, grid_l3_a = 0, 0, 0
    if ok_ga then
        grid_l1_a = host.decode_i16(ga_regs[1]) * 0.1
        grid_l2_a = host.decode_i16(ga_regs[2]) * 0.1
        grid_l3_a = host.decode_i16(ga_regs[3]) * 0.1
    end

    local grid_total_w = grid_l1_w + grid_l2_w + grid_l3_w

    -- Emit Meter telemetry (Victron: positive = import, matches convention)
    host.emit("meter", {
        w    = grid_total_w,
        l1_w = grid_l1_w,
        l2_w = grid_l2_w,
        l3_w = grid_l3_w,
        l1_v = grid_l1_v,
        l2_v = grid_l2_v,
        l3_v = grid_l3_v,
        l1_a = grid_l1_a,
        l2_a = grid_l2_a,
        l3_a = grid_l3_a,
    })

    -- ---- Battery Values ----

    -- Battery voltage: 840 (U16, 0.1V)
    local ok_bv, bv_regs = pcall(host.modbus_read, 840, 1, "holding")
    local bat_v = 0
    if ok_bv then
        bat_v = bv_regs[1] * 0.1
    end

    -- Battery current: 841 (I16, 0.1A)
    local ok_ba, ba_regs = pcall(host.modbus_read, 841, 1, "holding")
    local bat_a = 0
    if ok_ba then
        bat_a = host.decode_i16(ba_regs[1]) * 0.1
    end

    -- Battery power: 842 (I16, W)
    local ok_bw, bw_regs = pcall(host.modbus_read, 842, 1, "holding")
    local bat_w = 0
    if ok_bw then
        bat_w = host.decode_i16(bw_regs[1])
    end

    -- Battery SoC: 843 (U16, %)
    local ok_soc, soc_regs = pcall(host.modbus_read, 843, 1, "holding")
    local bat_soc = 0
    if ok_soc then
        bat_soc = soc_regs[1] / 100  -- percent to fraction
    end

    -- Battery temp: 844 (I16, 0.1C)
    local ok_bt, bt_regs = pcall(host.modbus_read, 844, 1, "holding")
    local bat_temp = 0
    if ok_bt then
        bat_temp = host.decode_i16(bt_regs[1]) * 0.1
    end

    -- Emit Battery telemetry
    -- Victron Modbus: positive power = discharging, negate for convention
    host.emit("battery", {
        w      = -bat_w,
        v      = bat_v,
        a      = bat_a,
        soc    = bat_soc,
        temp_c = bat_temp,
    })

    return 5000
end

function driver_cleanup()
end
