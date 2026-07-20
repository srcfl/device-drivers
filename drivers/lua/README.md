# Lua device drivers

This catalog supplies drivers to FTW core, the Blixt gateway and supported Zap
firmware. Each driver is a standalone Lua script. Its package recipe lists the
exact runtime targets and versions it supports.

## Driver Types

| Protocol | Description | Examples |
|----------|-------------|----------|
| `modbus` | Modbus TCP/RTU inverters and meters | sungrow, fronius, sma, solaredge |
| `serial` | Serial/UART devices (P1/HAN meters) | p1_dsmr, p1_hdlc |
| `mqtt` | MQTT devices | ambibox, opendtu_mqtt, victron_mqtt |
| `http` | HTTP devices | ferroamp, goe_http, openevse |
| `standalone` | Local test or helper driver with no device I/O | hello |

## P1/HAN Smart Meter Drivers

Split by protocol for clarity and memory efficiency:

| Driver | Protocol | Countries | Meters |
|--------|----------|-----------|--------|
| `p1_dsmr.lua` | DSMR ASCII (IEC 62056-21) | NL, BE, SE, DK | Aydon, Ellevio, Kamstrup, Sagemcom, Iskra, Landis+Gyr |
| `p1_hdlc.lua` | HDLC/DLMS binary (IEC 62056-7-5) | NO, some SE/AT/CH | Aidon (NO variant), Kaifa, Kamstrup (NO) |
| `p1_encrypted.lua` | GCM-encrypted HDLC/DLMS | BE, AT, LU | Fluvius (BE), EVN (AT), Sagemcom T211 |
| `p1_meter.lua` | All protocols (legacy) | All | Auto-detects DSMR/HDLC/M-Bus/GCM |

**Use the specific driver** (`p1_dsmr` or `p1_hdlc`) instead of `p1_meter` when you know your meter type. The specific drivers are smaller, faster, and easier to debug.

### Serial Config

```json
{
  "rx_pin": 20,
  "baud_rate": 115200,
  "invert_rx": true,
  "parity": "none"
}
```

| Field | DSMR v5 / Nordic | DSMR v2/v4 | Norwegian HAN |
|-------|------------------|------------|---------------|
| baud_rate | 115200 | 9600 | 2400 or 115200 |
| parity | "none" | "even" | "none" or "even" |
| invert_rx | true (Zap hardware) | true | true |

## Driver Lifecycle

Every driver implements:

```lua
PROTOCOL = "modbus"           -- or "serial", "logic", or omit
DRIVER_NAME = "My Device"     -- shown in API

function driver_init(config)   -- called once with config table
function driver_poll()         -- called every N ms, returns next interval
function driver_cleanup()      -- called on unload (optional)
function driver_command(action, power_w, cmd)  -- for EMS control (optional)
function driver_default_mode()  -- safety reset when EMS unloads (optional)
```

## Serial Number

Drivers should set a stable hardware identifier:

```lua
host.set_sn("meter-serial-12345")  -- from device registers or protocol
```

If not set, the firmware auto-generates one from `{make}-{ip}` (Modbus) or `{make}-drv{slot}` (serial).

## Telemetry

```lua
host.emit("meter", { w=1500, l1_w=500, l2_w=500, l3_w=500, hz=50.01, ... })
host.emit("pv", { w=-3000, mppt1_v=350, mppt1_a=8.5, ... })
host.emit("battery", { w=2000, soc=0.75, v=48.2, a=41.5, ... })
```
