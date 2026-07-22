# Lua Driver Development Guidelines

Rules for writing drivers that run well on the Zap ESP32-C3 (400KB SRAM, 48KB shared Lua pool).

## Memory Budget

```
Lua pool:        48KB total
VM overhead:    ~14KB (state, stdlib, host table)
Usable:         ~34KB for ALL drivers combined
Per driver:     ~8KB target (allows 4 drivers)
```

**The pool is shared.** Your driver's garbage is every other driver's problem. A memory hog doesn't just crash itself — it can cause transient errors in ALL running drivers.

## Rules

### 1. Keep bytecode small

Target: **under 6KB** compiled bytecode (~200 lines of Lua).

The `p1_meter.lua` universal driver compiles to 11.8KB and uses ~20KB of pool. The focused `p1_dsmr.lua` compiles to 3.6KB and uses ~8KB. Same functionality for the target meter, half the memory.

Don't write universal drivers. Write focused drivers for specific devices.

Check your bytecode size:
```bash
luac -o driver.luac driver.lua
wc -c driver.luac
```

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

### 7. Check available memory

```lua
function driver_poll()
    local free = host.pool_free()
    if free < 2048 then
        -- Pool is critically low — skip heavy processing
        return 5000
    end
    -- normal processing...
end
```

### 8. Clean up on unload

```lua
function driver_cleanup()
    -- Release any state. GC handles Lua objects,
    -- but clear references so they can be collected.
    serial_buf = nil
    history = nil
end
```

## Size Limits

| Resource | Limit | Why |
|----------|-------|-----|
| Bytecode | 8KB max, 6KB target | Bytecode lives in pool permanently |
| Persistent state | 4KB max | Stays allocated between ticks |
| Tick peak memory | 8KB target | Temp tables during one tick |
| Serial buffer | 4KB max | Cap with `if #buf > 4096 then buf = "" end` |
| Poll interval | 200ms min | Shorter wastes CPU on serial polling |
| Instructions per tick | 10M max | Enforced by firmware (infinite loop protection) |

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

1. **Compile:** `luac -o driver.luac driver.lua` — check size < 6KB
2. **Upload:** `curl --globoff -X POST 'http://ZAP_IP/api/drivers/0/upload?config={...}' --data-binary @driver.luac`
3. **Check:** `curl http://ZAP_IP/api/drivers/0` — running, no errors
4. **Memory:** Check `pool_free_bytes` in `/api/drivers` — should stay stable
5. **Peak:** Check `memory_peak_bytes` in driver detail — should be < 8KB
