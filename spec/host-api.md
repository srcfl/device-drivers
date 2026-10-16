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

### `host.unix_ms()` *(FTW)*
Returns wall-clock time in Unix milliseconds. `host.now_ms()` and
`host.millis()` are uptime and cannot be compared with a vendor's timestamp.

### `host.site_location()` *(FTW, vehicle drivers)*
Returns the site's `latitude, longitude`, or `nil`. FTW gives it only to a
driver from its signed channel whose signed catalog entry lists `vehicle`;
a bundled or local file gets `nil`, whatever its own `DRIVER` table says.
The position is the site's weather pin, and FTW treats the pin left where
the settings page put it as no position. A driver measures its car's
distance from the site and emits `site_distance_m`; it never emits the
car's coordinates. Check that the function exists before calling it: an
older FTW and Blixt L1 do not have it.

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

#### `vehicle` *(FTW)*

FTW also accepts `der_type` `"vehicle"`: a car's own telemetry, apart from the
charger it is plugged into. Besides `soc`, `charge_limit_pct`,
`charging_state`, `soc_fresh`, `soc_observed_at_ms` and `stale`, a vehicle
emit may say where the car's cable and the car are, so FTW can tell which car
was plugged in ([FTW docs/cars.md](https://github.com/srcfl/ftw/blob/master/docs/cars.md),
rule 2). Every field is optional; leave out what the source does not know.

Send `soc` as a percent, except a level of 1 % or less, which goes as a
fraction (`0.01`). FTW reads 1 or less as a fraction and more as a percent;
FTW before 0.131 reads every value as a percent. A plain `1` would read as
100 %.

| Field | Type | Meaning |
|---|---|---|
| `plugged` | bool | The car's own word on its charge cable: `true` in, `false` out. |
| `plugged_since_ms` | Unix ms | When the source read the cable take that state. Send it only when the source reads the cable at least every 30 seconds, and leave it out until the driver has seen a change: a value present at its first reading has no known time. It is the time of the read, not of the plug-in; Home Assistant's `last_changed` is when Home Assistant read it. |
| `at_site` | bool | `true` when the car is at this site, `false` when it is elsewhere, from the source's own idea of home (a Home Assistant zone, a TeslaMate geofence). |
| `site_distance_m` | metres | The car's distance from the site, from `host.site_location()`. FTW reads up to 300 m as here and over 5 km as elsewhere, and does not know in between: the site's position is a weather pin. `at_site` wins when both are given. |

FTW names a car when its source read the cable go in within a minute of the
charger's plug-in, no other charger saw a plug-in in that minute, no source
of the car says it is elsewhere, and no other car says the same. A reading
the car's source made after the plug-in that says `at_site` false or the
cable out rules the car out. Read the cable and the place at the driver's
own cadence: never wake a car only to learn them.

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
