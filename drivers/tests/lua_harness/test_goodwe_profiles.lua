local profile = arg[1]
local mode = arg[2] or "import-charge"
local init_mode = arg[3] or "explicit"
if not profile then error("profile is required") end

dofile("drivers/tests/lua_harness/host_mock.lua")
host.reset()
local fixtures = dofile("drivers/tests/lua_harness/goodwe_fixtures.lua")
local fixture = fixtures[profile]
if not fixture then error("unknown fixture profile: " .. tostring(profile)) end
if mode == "export-discharge" then
    if profile == "community-v1" then
        fixture.registers[35132] = {0, 500}
        fixture.registers[35134] = {0, 500}
        fixture.registers[35136] = {0, 500}
        fixture.registers[35140] = {0, 1500}
        fixture.registers[35180][1] = 64336
    else
        fixture.registers[35138][3] = 1500
        fixture.registers[35164][1] = 500
        fixture.registers[35164][3] = 600
        fixture.registers[35164][5] = 700
        fixture.registers[35178][3] = 64336
    end
    fixture.expected.meter_w = -1500
    fixture.expected.l1_w = -500
    fixture.expected.battery_w = -1200
elseif mode == "zero-voltage" then
    if profile ~= "gw8kn-et-hk3000" then error("zero-voltage is only a GW8KN fixture") end
    fixture.registers[35145][1] = 0
    fixture.registers[35145][7] = 0
    fixture.registers[35145][13] = 0
elseif mode == "night-zero" then
    if profile ~= "gw8kn-et-hk3000" then error("night-zero is only a GW8KN fixture") end
    fixture.registers[35138][1] = 0
    fixture.expected.pv_w = 0
elseif mode ~= "import-charge" then
    error("unknown fixture mode: " .. mode)
end
for address, registers in pairs(fixture.registers) do
    host._modbus_registers.holding[address] = registers
end

dofile("drivers/lua/goodwe.lua")
if init_mode == "legacy-default" then
    driver_init({})
else
    driver_init({profile = profile})
end
driver_poll()

local function close(actual, expected, name)
    if actual == nil or math.abs(actual - expected) > 0.000001 then
        error(string.format("%s=%s, expected=%s", name, tostring(actual), tostring(expected)))
    end
end

local expected = fixture.expected
close(host._emitted.pv[1].w, expected.pv_w, "pv.w")
close(host._emitted.meter[1].w, expected.meter_w, "meter.w")
close(host._emitted.meter[1].l1_w, expected.l1_w, "meter.l1_w")
close(host._emitted.battery[1].w, expected.battery_w, "battery.w")
close(host._emitted.battery[1].soc, expected.soc, "battery.soc")
close(host._emitted.meter[1].hz, expected.hz, "meter.hz")
close(host._emitted.meter[1].import_wh, expected.import_wh, "meter.import_wh")
close(host._emitted.meter[1].export_wh, expected.export_wh, "meter.export_wh")
if mode == "zero-voltage" then
    if host._emitted.meter[1].l1_a ~= nil or host._emitted.meter[1].l2_a ~= nil or
       host._emitted.meter[1].l3_a ~= nil then
        error("zero voltage fabricated a phase current")
    end
end

local reads = {}
for _, call in ipairs(host._calls) do
    if call.func == "modbus_read" then table.insert(reads, call.args) end
end
if #reads ~= #fixture.batches then
    error(string.format("profile %s made %d reads, expected %d", profile, #reads, #fixture.batches))
end
for index, batch in ipairs(fixture.batches) do
    local read = reads[index]
    if read[1] ~= batch[1] or read[2] ~= batch[2] or read[3] ~= "holding" then
        error(string.format("read %d was %s/%s/%s", index, tostring(read[1]), tostring(read[2]), tostring(read[3])))
    end
end

local writes_before = host._modbus_write_attempts
if driver_command("battery", 1000, {}) ~= false then error("read-only command was accepted") end
driver_default_mode()
driver_cleanup()
if host._modbus_write_attempts ~= writes_before then error("read-only lifecycle attempted a write") end
