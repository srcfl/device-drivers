-- With control on, a failed battery-power read (34755) must skip the
-- self-heal check, not raise. 50-125k-svk did math.abs(nil) and
-- 50-125k-svk-slew did nil - committed, so one missed read failed the
-- whole poll and took telemetry with it.
--
-- Usage: lua55 test_svk_selfheal_nil.lua <driver-path> <polls-in-a-row>
--   <polls-in-a-row>: the driver's SELF_HEAL_RUN_REQUIRED (2 or 4).
local driver_path = arg[1]
local run_required = tonumber(arg[2])
assert(driver_path and run_required, "usage: test_svk_selfheal_nil.lua <driver-path> <polls>")

dofile("drivers/tests/lua_harness/host_mock.lua")
-- Both real hosts have it; the shared mock does not.
host.set_warmup_s = function() end

local function set_s32(addr, v)
    if v < 0 then v = v + 4294967296 end
    host._modbus_registers.input[addr] = math.floor(v / 65536)
    host._modbus_registers.input[addr + 1] = v % 65536
end

local function writes()
    local n = 0
    for _, c in ipairs(host._calls) do
        if c.func == "modbus_write" or c.func == "modbus_write_multiple" then n = n + 1 end
    end
    return n
end

local function fresh_armed()
    host.reset()
    local reg = host._modbus_registers.input
    for i = 0, 15 do reg[33004 + i] = 0x4142 end   -- serial number
    reg[33067] = 10000
    reg[34799] = 0x0100
    reg[33139] = 55
    set_s32(34765, 0)
    set_s32(34755, 0)
    driver_init, driver_poll, driver_command = nil, nil, nil
    dofile(driver_path)
    assert(driver_init({}) == true, "driver_init failed")
    -- Hold 0 W: control on, last command 0.
    assert(driver_command("battery", 0) == true, "arming failed")
end

local function poll(label)
    local ok, err = pcall(driver_poll)
    assert(ok, label .. ": driver_poll raised: " .. tostring(err))
end

-- 1. Battery power read fails while control is on: no error, no write.
fresh_armed()
local before = writes()
host._modbus_read_fail_addresses[34755] = "Illegal Data Address"
for i = 1, run_required + 2 do poll("failed 34755, poll " .. i) end
assert(writes() == before, "self-heal wrote without a battery reading")
local bat = host._emitted.battery[#host._emitted.battery]
assert(bat and bat.W == nil, "battery W invented without a reading")

-- 2. A missing reading breaks a run of disagreeing polls: the count
--    starts again, so no self-heal fires on non-consecutive evidence.
fresh_armed()
host._modbus_read_fail_addresses[34755] = nil
set_s32(34755, 5000)   -- disagrees with the 0 W hold
before = writes()
for i = 1, run_required - 1 do poll("disagree " .. i) end
host._modbus_read_fail_addresses[34755] = "Illegal Data Address"
poll("gap")
host._modbus_read_fail_addresses[34755] = nil
for i = 1, run_required - 1 do poll("disagree again " .. i) end
assert(writes() == before, "self-heal fired across a missing reading")

-- 3. The self-heal itself is unchanged: enough disagreeing polls in a
--    row still re-arm and rewrite.
fresh_armed()
set_s32(34755, 5000)
before = writes()
for i = 1, run_required + 1 do poll("disagree " .. i) end
assert(writes() > before, "self-heal no longer fires on a real disagreement")

print("ok " .. driver_path)
