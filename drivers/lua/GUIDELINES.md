# Lua Driver Development Guidelines

Rules for writing a canonical driver: one driver per device, one source, running
on the linux-edge hosts this repository targets — FTW (gopher-lua) and Blixt L1
(luajit).

Both run on Linux-class hardware, so a driver here is not written to a memory
budget. Write the driver the device needs. Zap builds are a separate track that
compiles from this source; its constraints do not shape the code here.

What a driver may call is set by `spec/host-api-profile.json` and checked by
`tests/test_host_api_profile.py`. A function that is not in the profile is not
available, whichever host you tested against.

## Rules

### 1. Write one driver per device, not one per host

The reason this repository exists is that the same device ended up with several
drivers that drifted apart. If a host needs something the others do not, that
belongs in the host API, not in a second copy of the driver.

Two names for one function is the same failure in miniature. `decode_u32_be` and
`decode_u32` decode identical bytes; `modbus_write_multi` and
`modbus_write_multiple` write identical registers. Which spelling a driver
happens to call then decides which host it runs on. Use the name in the profile.

### 2. Don't accumulate state

**Wrong:**
```lua
local history = {}
function driver_poll()
    history[#history + 1] = read_value()  -- grows forever
    return 5000
end
```

**Right:**
```lua
function driver_poll()
    local value = read_value()  -- local, GC'd after tick
    host.emit("meter", { w = value })
    return 5000
end
```

If you need state across ticks, keep it minimal: a single number, a flag, not a growing table.

### 3. Don't concatenate strings in a loop

This is the single biggest memory mistake in Lua on constrained devices.

**Wrong — creates N garbage strings:**
```lua
local buf = ""
function driver_poll()
    local data = host.serial_read(256, 500)
    if data then
        buf = buf .. data  -- ALLOCATES new string every time!
    end
end
```

Each `buf .. data` allocates a new string of `len(buf) + len(data)`. The old `buf` becomes garbage but isn't collected until GC runs. Buffering 2KB via 8 chunks of 256B creates ~10KB of garbage.

**Right — use a table of chunks:**
```lua
local chunks = {}
local total_len = 0

function driver_poll()
    local data = host.serial_read(256, 500)
    if data and #data > 0 then
        chunks[#chunks + 1] = data
        total_len = total_len + #data
    end

    -- Only concat when you need the full buffer
    if total_len > 100 then
        local buf = table.concat(chunks)
        chunks = {}
        total_len = 0
        process_frame(buf)
    end
end
```

`table.concat` does a single allocation for the final string. Much less garbage.

### 4. Batch Modbus reads

**Wrong — 4 separate reads for consecutive registers:**
```lua
local r1 = host.modbus_read(100, 1, "input")
local r2 = host.modbus_read(101, 1, "input")
local r3 = host.modbus_read(102, 1, "input")
local r4 = host.modbus_read(103, 1, "input")
```

**Right — one read for all 4:**
```lua
local regs = host.modbus_read(100, 4, "input")
local r1, r2, r3, r4 = regs[1], regs[2], regs[3], regs[4]
```

Each `modbus_read` creates a Lua table AND a coroutine yield/resume cycle. Fewer reads = fewer tables = less pool pressure. You can read up to 125 registers in one call.

### 5. Always use pcall for I/O

```lua
local ok, regs = pcall(host.modbus_read, 5016, 2, "input")
if ok and regs then
    -- use regs
end
```

Never let an I/O error crash your tick. A failed read returns an error; pcall
catches it. Do not emit a fabricated zero. Return without an emit when a core
read fails, and omit only fields whose reads are truly optional.

### 6. Return early when there's nothing to do

```lua
function driver_poll()
    local ok, data = pcall(host.serial_read, 256, 500)
    if not ok or not data or #data == 0 then
        return 200  -- nothing to do, check again in 200ms
    end
    -- process data...
end
```

### 7. Don't emit a value you didn't read

A failed read is not a zero. Emitting a fabricated zero tells the site that PV
stopped or the battery is empty, and every sum downstream inherits the lie.
Leave the field out, or skip the whole stream when its registers did not answer.

The same goes for a device that is reachable but faulted: it can answer every
read with fresh values while its hardware is unavailable. Say so with
`host.set_device_fault(true, reason)` rather than letting the telemetry look
healthy.

### 8. Clean up on unload

```lua
function driver_cleanup()
    -- Release any state. GC handles Lua objects,
    -- but clear references so they can be collected.
    serial_buf = nil
    history = nil
end
```

## Limits

| Resource | Limit | Why |
|----------|-------|-----|
| Serial buffer | 4KB max | Cap with `if #buf > 4096 then buf = "" end`; an uncapped buffer grows without end on a noisy line |
| Poll interval | 200ms min | Shorter wastes CPU without giving fresher data |
| Instructions per tick | 10M max | Host-enforced, catches an infinite loop |

There is no bytecode ceiling on a linux-edge host. The habits above still pay —
fewer allocations mean less GC in the poll path, and edge control has a 200ms
budget to hold — but size is not what decides whether a driver may ship.

## Patterns

### Modbus Inverter (Sungrow-style)

```lua
PROTOCOL = "modbus"
DRIVER_NAME = "My Inverter"

function driver_init(config)
    host.set_make("Brand")
    -- Read serial from device registers (once, on first poll)
end

function driver_poll()
    -- Batch reads where possible
    local ok, regs = pcall(host.modbus_read, 5000, 20, "input")
    if not ok or not regs then return 5000 end

    host.emit("pv", { w = -decode_power(regs) })
    host.emit("meter", { w = decode_grid(regs) })
    return 5000
end
```

### Serial Meter (P1-style)

```lua
PROTOCOL = "serial"
DRIVER_NAME = "My Meter"

local chunks = {}
local total = 0

function driver_init(config)
    host.set_make("Brand")
end

function driver_poll()
    local ok, data = pcall(host.serial_read, 256, 500)
    if ok and data and #data > 0 then
        chunks[#chunks + 1] = data
        total = total + #data
    end

    if total > 50 then
        local buf = table.concat(chunks)
        chunks = {}; total = 0
        local frame = find_frame(buf)
        if frame then
            local values = parse(frame)
            host.emit("meter", values)
        end
    end
    return 200
end
```

### EMS Logic Driver

```lua
PROTOCOL = "logic"
DRIVER_NAME = "My EMS"

function driver_init(config)
    host.set_make("My EMS")
end

function driver_poll()
    local telem = host.ems_read_telemetry()
    -- Make decisions based on telemetry...
    -- Dispatch commands to device drivers...
    -- host.ems_dispatch(driver_id, "battery", power_w)
    return 5000  -- match slowest device poll interval
end
```

## Testing Your Driver

```bash
make test-driver ID=<id>      # syntax, sandbox, manifest and driver tests
make package-driver ID=<id> TARGET=ftw-core
make check                    # the whole suite, including the host API profile
```

`make test-driver` compiles the driver, checks it against the sandbox rules and
runs the Lua harness. `make check` additionally verifies that every function the
driver calls exists in `spec/host-api-profile.json`, which is what stops a
driver from working on the host you tested and failing on the other one.

Hardware evidence is separate from all of this. A green suite says the driver is
well formed, not that it read the right register on a real device.
