# Host API Reference

Functions available to Lua drivers via the `host` table, implemented by each
linux-edge host: FTW (gopher-lua) and Blixt L1 (luajit).

Two hosts, two dialects, both correct. FTW spells several functions the way
its Go binding always has (`modbus_write`, `millis`); Blixt L1 spells them
`write` and `now_ms`. Neither is the "real" name — each is the real API of a
shipping host, and a host that wants the other's drivers adds aliases, which
FTW did in about thirty lines. `spec/host-api-profile.json` maps the two under
`ftw_to_blixt`, and `tools/host_api_check.py` enforces the one rule that
matters: a driver must not call a name no host provides.

## Core

### `host.log(message)`
Log a message to the gateway's log system.

### `host.now_ms()`
Returns current uptime in milliseconds (integer).

### `host.sleep(milliseconds)`
Pause inside a driver call. Use it only where a device requires a gap between
writes; the host owns scheduling, so a driver must not use it to pace polling.

### `host.set_make(brand_name)`
Set the device brand name used in telemetry payloads. Call in `driver_init()`.

### `host.set_model(model)`
Set the device model. Call in `driver_init()` once the model is known from the
bus, so an operator can tell two units of the same make apart.

### `host.set_sn(serial)`
Set the device serial number. Call as soon as a stable identity is known, which
for most Modbus devices is the first successful poll rather than `driver_init()`.

### `host.set_rated_w(watts)`
Set the device's rated AC power. Read it off the bus where the device reports
it rather than asking the operator to configure a number the device knows.

### `host.set_warmup_s(seconds)`
Hold off the first poll for this many seconds after start. Use it for a device
that answers Modbus before its values are meaningful.

### `host.set_poll_interval(milliseconds)`
Change the interval before the next poll. `driver_poll()`'s return value already
does this; use the call when the interval changes outside a poll.

### `host.set_device_fault(faulted, reason)`
Report that the device itself is in a fault state. A device can answer every
read with fresh values while its hardware is unavailable, so a driver that knows
the difference must say so; the host cannot infer it from telemetry. Clear it
with `false` once a later read shows the fault is gone.

### `host.emit_metric(name, value, unit)`
Emit one diagnostic value outside the DER telemetry schema. `unit` is optional.
Use it for evidence an operator needs when a device misbehaves, not for
telemetry that belongs in `host.emit()`.

### `host.emit(der_type, data)`
Emit telemetry for one DER. `der_type` is the host's DER kind: `"pv"`,
`"battery"`, `"inverter"`, `"meter"` or `"v2x_charger"`.

Use the field names your target host accepts. The host maps its Lua keys to
its telemetry model; a catalog or signed artifact does not change that map.
Key names and case are exact: a host can silently drop an unknown key.

[Sourceful data models](https://github.com/srcfl/srcful-data-models) owns
Sourceful's wire field names, units and sign rules. Its published
[`docs/REFERENCE.md`](https://github.com/srcfl/srcful-data-models/blob/main/docs/REFERENCE.md)
is the source for those fields. DER and device types come from the
device-support API (`GET /der-types`, `GET /device-types`). The host kinds
map to those DER types as follows:

| `der_type` | device-support DER type |
|---|---|
| `pv` | `solar` |
| `battery` | `battery` |
| `meter` | `meter` |
| `v2x_charger` | `ev_charger_port` |
| `inverter` | Proposed in data-models v3.0.0; see the migration below |

Blixt L1 reads host keys such as `W`, `V`, `A`, `total_import_Wh` and
`rated_W`, and PV inputs as `pv.mppts`, a list of `{V, A, W}`. A Blixt driver
keeps those keys until its host changes. FTW drivers use keys such as `w`,
`soc` and `import_wh`; FTW also accepts the Blixt spelling since
v1.11.4-beta.7. Use the spelling your target speaks and keep a working
driver's keys when they already report the right values.

Leave out a value that was not read (`nil`). Never send a made-up zero.
Follow the target host's wire rules for absent values.

#### Proposed data-models v3.0.0 migration

[srcful-data-models#10](https://github.com/srcfl/srcful-data-models/pull/10)
proposes the `inverter` DER type, lowercase non-unit names, and `_ac` / `_dc`
postfixes for quantities that can describe either side. NovaCore's matching
change is [srcful-novacore#174](https://github.com/srcfl/srcful-novacore/pull/174).
These changes are still open. The reference on `main` currently describes
v2.0.0.

Those proposed wire names do not change `host.emit` yet. Before a driver
uses them, its host must accept or map them, and any receiving API must
support them. Keep the current host keys until that work lands; a link to
a newer data model does not add host support.

## Modbus

Available when `PROTOCOL = "modbus"`.

### `host.modbus_read(address, count, kind)`
Read `count` consecutive registers starting at `address`. `kind` is `"holding"` (FC 0x03) or `"input"` (FC 0x04).

Returns: 1-indexed Lua table of uint16 values, or `nil, error_string` on failure.

### `host.write(address, value)`
Write a single holding register. On FTW this is FC06. **On Blixt L1 it is
FC16 with count = 1** — Deye firmware silently ignores FC06 on some ranges,
so the Blixt host always uses FC16 for single-register writes and offers
`host.write_fc06` for the few registers that need a true FC06.

### `host.write_fc06(address, value)` *(Blixt L1)*
True FC06 write-single-register, opt-in per register for devices whose
firmware treats FC06 and FC16 differently. Not available on FTW.

### `host.write_registers(address, values_table)`
Write consecutive holding registers (FC16).

### Write results differ between hosts — check both

The two hosts report a failed write differently, and a driver that
targets both must handle both:

* **FTW** returns an error string on failure and nothing on success; it
  never raises. `pcall` alone therefore reports success for a failed
  write.
* **Blixt L1** returns `true` on success and **raises** (an mlua error,
  caught by `pcall`) on a Modbus exception or timeout.

Portable pattern:

```lua
local ok, res = pcall(host.write_registers, addr, values)
if not ok or res ~= nil and res ~= true then
  -- failed: `res` is the error (string on FTW, error object on Blixt)
end
```

The test harness (`drivers/tests/lua_harness/host_mock.lua`) uses the FTW
convention, so a Blixt-only driver that trusts `pcall`'s `ok` will read a
mocked refusal as a successful write. Drivers migrating from Blixt L1
should adopt the portable check before relying on the write-side tests.

## MQTT

Available when `PROTOCOL = "mqtt"`.

### `host.mqtt_subscribe(topic_pattern)`
Subscribe to an MQTT topic (supports wildcards `#`, `+`). Returns `true`/`false`.

### `host.mqtt_messages()`
Drain all buffered messages since last call. Returns a table of `{topic=string, payload=string}`.

### `host.mqtt_publish(topic, payload)`
Publish a message. Returns `true`/`false`.

## HTTP

Available when `PROTOCOL = "http"`.

### `host.http_get(url)`
Perform an HTTP GET request to a local device URL.

- `url` — full URL string (e.g., `"http://192.168.1.100/rpc/Shelly.GetStatus"`)
- Returns: response body as string on success (HTTP 2xx)
- Returns: `nil, error_string` on failure (timeout, connection refused, non-2xx status)

Constraints:
- Only `http://` scheme (no HTTPS on constrained devices)
- 5-second timeout
- 16 KB max response size
- Local network addresses only

## HTTP POST (Planned)

Available when `PROTOCOL = "http"`. **Status: Planned for next release.**

### `host.http_post(url, body, content_type)`
Perform an HTTP POST request to a local device URL.

- `url` — full URL string
- `body` — request body as string
- `content_type` — MIME type (e.g., `"application/json"`)
- Returns: response body as string on success (HTTP 2xx)
- Returns: `nil, error_string` on failure

Same constraints as `host.http_get` (5s timeout, 16KB response, local only).

**Unlocks:** Control for HTTP-based devices (Sonnen, go-e, OpenEVSE, etc.)

## HTTPS (Planned)

**Status: Planned.** Adds TLS support for local HTTPS endpoints.

### `host.https_get(url)`
### `host.https_post(url, body, content_type)`

Same interface as HTTP variants but with TLS support (including self-signed certificate acceptance for local devices).

**Unlocks:** Tesla Powerwall, Enphase Envoy, Fronius Gen24 (newer firmware).

## UDP (Planned)

**Status: Planned.** Adds UDP socket support.

### `host.udp_send(host, port, data)`
Send a UDP datagram. Returns `true`/`false`.

### `host.udp_recv(port, timeout_ms)`
Listen for a UDP response on `port` for up to `timeout_ms`. Returns data string or `nil`.

**Unlocks:** GoodWe native protocol, Keba P20, SMA Speedwire.

## BLE Client (Planned)

**Status: Planned.** Adds BLE central/client mode for Bluetooth device communication.

### `host.ble_scan(service_uuid, timeout_ms)`
Scan for BLE peripherals. Returns table of `{address, name, rssi}`.

### `host.ble_connect(address)`
Connect to BLE peripheral. Returns connection handle or `nil`.

### `host.ble_read(handle, service_uuid, char_uuid)`
Read a GATT characteristic. Returns data string.

### `host.ble_write(handle, service_uuid, char_uuid, data)`
Write a GATT characteristic. Returns `true`/`false`.

### `host.ble_subscribe(handle, service_uuid, char_uuid)`
Subscribe to GATT notifications. Returns `true`/`false`.

### `host.ble_notifications()`
Get buffered BLE notifications. Returns table of `{handle, char_uuid, data}`.

### `host.ble_disconnect(handle)`
Disconnect from BLE peripheral. Returns `true`/`false`.

**Unlocks:** Victron VE.Direct BLE, Bluetti portable power stations.

## Serial

Available when `PROTOCOL = "serial"`.

### `host.serial_read(max_bytes, timeout_ms)`
Read up to `max_bytes` raw bytes from the serial port.

- `max_bytes` — maximum number of bytes to read (1–4096)
- `timeout_ms` — read timeout in milliseconds (0 = non-blocking, returns immediately with available data)
- Returns: raw byte string (may be shorter than `max_bytes`), or `nil` if no data available within timeout
- The serial port is configured via the device config (`baud_rate`, `serial_port`, `parity`, `data_bits`, `stop_bits`)

### `host.serial_available()`
Returns the number of bytes available in the serial receive buffer without blocking.

### Serial Port Configuration

The serial port is configured via the device config table passed to `driver_init(config)`:
- `config.serial_port` — device path (e.g., `/dev/ttyUSB0`)
- `config.baud_rate` — baud rate (2400, 9600, 115200)
- `config.parity` — `"N"` (none), `"E"` (even), `"O"` (odd)
- `config.data_bits` — 7 or 8
- `config.stop_bits` — 1 or 2

## Crypto Helpers

Always available. For decrypting data from encrypted smart meters.

### `host.aes_gcm_decrypt(key, iv, ciphertext, aad, tag)`
Decrypt AES-128-GCM encrypted data (used by Belgian/Austrian/Luxembourg smart meters).

- `key` — 16-byte encryption key (binary string)
- `iv` — 12-byte initialization vector (system_title + frame_counter)
- `ciphertext` — encrypted payload (binary string)
- `aad` — additional authenticated data (binary string, may be empty `""`)
- `tag` — 12-byte authentication tag (binary string)
- Returns: decrypted plaintext (binary string), or `nil, error_string` on failure

## Decode Helpers

Always available. Used to interpret raw Modbus register values.

Endianness is part of the name. A helper that leaves it implicit is how a
driver ends up decoding the right registers the wrong way round.

### `host.decode_i16(val)`
Interpret a uint16 as signed int16. Returns number.

### `host.decode_u16(val)`
Interpret a raw register as uint16. Returns number.

### `host.decode_u32_be(hi, lo)`
Combine two uint16, high word first, into uint32. Returns number.

### `host.decode_i32_be(hi, lo)`
Combine two uint16, high word first, into signed int32. Returns number.

### `host.decode_u32_le(lo, hi)`
Combine two uint16, low word first, into uint32. Returns number.

### `host.decode_i32_le(lo, hi)`
Combine two uint16, low word first, into signed int32. Returns number.

### `host.decode_f32_be(hi, lo)`
Combine two uint16, high word first, into IEEE 754 float32. Returns number.

### `host.decode_string(registers, start, count)`
Read ASCII from `count` registers starting at `start`, two characters per
register. Returns string. Use it instead of looping over bytes in the driver.

### `host.decode_u64(w1, w2, w3, w4)`
Combine four uint16 (big-endian) into uint64. Returns number.

### `host.scale(value, sf)`
Apply SunSpec scale factor: `value × 10^sf`. Caps `|sf|` at 10 for safety.

### `host.json_decode(json_string)`
Parse a JSON string into a Lua table. Returns `table` or `nil, error_string`.
