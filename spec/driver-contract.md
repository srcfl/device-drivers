# Driver Contract

Every Lua driver must define these globals and functions.

## Required

### `PROTOCOL` (string)

Tells the runtime what client to create:

| Value | Client Created |
|-------|---------------|
| `"modbus"` | Modbus TCP or RTU (from device config) |
| `"mqtt"` | MQTT broker connection |
| `"http"` | HTTP client for local device REST/RPC APIs |
| `"serial"` or `"p1"` | Serial port for P1/HAN telegrams |
| `"standalone"` | No client (test/demo drivers) |

### `driver_init(config)`

Called once after the VM is created and the protocol client is connected.

`config` is a table with:
- `sn` — managed device serial number
- `type` — device type (`"lua"`)
- `profile` — profile name
- `host` — connection host (Modbus TCP / MQTT)
- `port` — connection port
- `unit_id` — Modbus unit/slave ID
- `serial_port` — serial device path (RTU / P1)
- `baud_rate` — serial baud rate
- `gateway_serial` — this gateway's identity
- `ders` — array of `{type, enabled, rated_power}`

### `driver_poll()`

Called repeatedly by the runtime. Must:
1. Read data from the device
2. Emit telemetry via `host.emit()`
3. Return the next poll interval in milliseconds

Return value:
- Number > 0: poll interval in ms (capped to 100ms–60s)
- nil/0: use default interval (5000ms)

### `driver_cleanup()`

Called when the driver is stopped. Release any resources.

## Optional (Control)

### `driver_command(action, power_w, cmd)`

Called when an EMS control command arrives via NATS.

Parameters:
- `action` — `"init"`, `"battery"`, `"curtail"`, `"curtail_disable"`, `"deinit"`
- `power_w` — target power in watts (signed: positive=charge, negative=discharge)
- `cmd` — table with `{id, source, duration_ms, expires_at}`

Return: `true` on success, `false` on failure.

### `driver_default_mode()`

Called when the EMS heartbeat watchdog expires (60s without heartbeat). Should revert the device to safe autonomous operation (e.g., auto mode).
