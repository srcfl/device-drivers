# Sourceful Device Integration Overview

> **53 drivers, 46 manufacturers, 551+ device variants**
> One Lua driver framework, two runtimes (Blaxt + Zap), zero firmware updates needed for new devices.

---

## How It Works

Every device integration is a self-contained Lua script (~100-500 lines) that runs inside the gateway's sandboxed runtime. The driver reads from the device using the host API (Modbus, HTTP, MQTT, Serial) and emits standardized telemetry.

```
Physical Device
    ↕  (Modbus TCP / HTTP / MQTT / Serial)
Gateway Host API  ← thin I/O layer, rarely changes
    ↕
Lua Driver        ← all protocol intelligence lives here
    ↕
host.emit("meter", { w = 1500, l1_v = 230.1, ... })
    ↕
NATS → Cloud      ← standardized data model
```

**Key insight**: Adding a new device = writing a Lua file. No firmware update, no recompilation, no deployment. Drivers can be updated over-the-air independently of the gateway firmware.

---

## Supported Devices

### Solar Inverters — 22 drivers, 250+ variants

| Brand | Models | Protocol | Control |
|-------|--------|----------|---------|
| **Sungrow** | SH-RT, SH-RS, SG-RT, SG-CX | Modbus | Full |
| **Solis** | S6-EH3P, S6-EH1P, S5/S6-GR3P, C&I | Modbus | Full |
| **Huawei** | SUN2000 (1P+3P), LUNA2000 batteries, SmartLogger | Modbus | Stub |
| **Fronius** | GEN24 Primo/Symo, Tauro, Verto, Classic Symo/Primo | Modbus | Stub |
| **SMA** | Tripower X, CORE1/2, Sunny Boy, Sunny Island | Modbus | Stub |
| **SolarEdge** | SE Series (1P+3P), StorEdge, SolarEdge Home | Modbus | Stub |
| **Deye** | SUN Series (1P+3P Hybrid, HV, String) | Modbus | Stub |
| **GoodWe** | ET, EH, BT, BH, ES, EM, BP, DT, DNS, XS | Modbus | Stub |
| **Growatt** | SPH, MIN, MIC, MOD, MAX | Modbus | Stub |
| **SolaX** | X1/X3 Hybrid G4, X3 PRO | Modbus | Stub |
| **Kostal** | Plenticore Plus/BI, PIKO MP Plus/IQ | Modbus | Stub |
| **Fox ESS** | H1, H3, H3 PRO, AIO-H3, KH | Modbus | Stub |
| **Sofar Solar** | HYD, ME, HYD-ES | Modbus | Stub |
| **SAJ** | H2, HS2, AS2 | Modbus | Stub |
| **KSTAR** | KSE, BluE-S | Modbus | Stub |
| **AlphaESS** | Smile, G2 | Modbus | Stub |
| **Victron Energy** | MultiPlus-II, Quattro-II, SmartSolar, SmartShunt | Modbus + MQTT |  Stub |
| **Hoymiles** (via OpenDTU) | HM, HMS, HMT series microinverters | HTTP + MQTT | — |
| **Fronius** (Solar API) | All Fronius models via HTTP | HTTP | — |

### Batteries & Storage — 3 drivers

| Brand | Models | Protocol |
|-------|--------|----------|
| **VARTA** | pulse neo, element, link | Modbus |
| **sonnen** | eco 8.0, 10 performance, FlexStack | HTTP |
| **Pixii** | PowerShaper 2.0 | Modbus |

### Energy Meters — 10 drivers, 50+ variants

| Brand | Models | Protocol |
|-------|--------|----------|
| **Eastron** | SDM630, SDM120, SDM230 | Modbus |
| **Carlo Gavazzi** | EM24, EM340, EM530 | Modbus |
| **Schneider Electric** | iEM3xxx, PM5xxx, PM710 | Modbus |
| **Janitza** | UMG 96, 604 Pro, 806 | Modbus |
| **ABB** | B23, B24, M4M | Modbus |
| **Siemens** | PAC2200, PAC3200 | Modbus |
| **Socomec** | Diris A-10/A-20/A-40 | Modbus |
| **Chint** | DDSU666, DTSU666 | Modbus |
| **Acrel** | DTSD1352 | Modbus |
| **Circutor** | CEM-C, CVM-C10 | Modbus |

### EV Chargers — 14 drivers

| Brand | Models | Protocol |
|-------|--------|----------|
| **Alfen** | Eve NG910/NG920 | Modbus |
| **ABB** | Terra AC 7.4/11/22kW | Modbus |
| **go-e** | Gemini flex 11/22kW | Modbus + HTTP |
| **Keba** | KeContact P30 | Modbus |
| **Wallbox** | Commander 2, Pulsar Plus | Modbus |
| **Mennekes** | AMTRON | Modbus |
| **Easee** | Home, Charge | Modbus |
| **Schrack** | i-CHARGE CION | Modbus |
| **Etrel** | INCH HOME/DUO/PRO | Modbus |
| **OpenEVSE** | OpenEVSE | HTTP |
| **Zaptec** | GO, PRO | HTTP |
| **HardyBarth** | cPH1, Salia | HTTP |
| **Ambibox** | V2X Charger | MQTT |

### Smart Meters (P1/HAN) — 1 driver, 30+ meter models

| Brand | Models | Protocol |
|-------|--------|----------|
| **Aidon** | 6442, 6490, 6492, 65xx | DSMR + HDLC/DLMS |
| **Iskraemeco** | AM550 | DSMR + DLMS |
| **Kaifa** | MA105, MA304, MA309 | HDLC/DLMS |
| **Kamstrup** | Omnia, Omnipower | DSMR + HAN/NVE |
| **Landis+Gyr** | E350, E360, E450 | DSMR + HDLC/DLMS |
| **Sagemcom** | S211, T211, T210-D | DSMR + DLMS |
| **NES** | G5 83335-X | DSMR |
| **Sanxing** | S34U18 | DSMR |
| + any DSMR v2-v5 meter | (NL, BE, SE, DK, NO, AT, CH) | Auto-detect |

The P1/HAN driver does full protocol parsing in Lua: DSMR ASCII, HDLC framing, DLMS/COSEM binary decoding, M-Bus, and AES-GCM encrypted meters (Belgian/Austrian).

### Other

| Driver | Protocol | Purpose |
|--------|----------|---------|
| **Shelly** (Gen2/3/4) | HTTP | 12+ metering models, auto-detect |
| **Ferroamp** EnergyHub | MQTT | Full PV + Battery + Meter + Control |

---

## Protocols

| Protocol | Drivers | Host API |
|----------|---------|----------|
| **Modbus TCP** | 39 | `host.modbus_read/write` |
| **HTTP** | 8 | `host.http_get` |
| **MQTT** | 4 | `host.mqtt_subscribe/messages/publish` |
| **Serial** (P1/HAN) | 1 | `host.serial_read` |
| **Standalone** | 1 | (demo) |

**Planned**: HTTP POST, HTTPS (Tesla/Enphase), UDP (SMA Speedwire), BLE Client (Victron BLE).

---

## Driver Tiers

| Tier | Count | Signed | Auto-Update | Who |
|------|-------|--------|-------------|-----|
| **Core** | 13 | Ed25519 | Yes | Sourceful |
| **Community** | 40 | No | Manual | Contributors |
| **OEM** | 0 | OEM key | Per agreement | Manufacturers |

**Core** = tested on real hardware, signed, shipped by default.
**Community** = based on public documentation, CI-validated, promoted to core after hardware testing.

---

## Driver Versioning & Updates

Each driver has an independent semver version. Gateways can update drivers over-the-air without firmware changes.

```
Gateway                         Cloud API
   │                                │
   ├── Check index.yaml ───────────►│
   │◄── New sungrow v1.3.0 ────────┤
   │                                │
   ├── Download + verify ──────────►│
   │◄── .lua + SHA256 + Ed25519 ───┤
   │                                │
   ├── Activate (hot-reload)        │
   │   └── rollback if crash        │
   │                                │
```

**Per-device policy**:
- `auto` — update automatically (default for core)
- `manual` — download but wait for user to activate
- `pinned` — stay on a specific version

**Safety**: Automatic rollback if a new driver crashes within the first 3 poll cycles. Gateways always have built-in fallback drivers for offline operation.

Full spec: [`drivers/spec/driver-versioning.md`](spec/driver-versioning.md)

---

## Quality Assurance

Every driver passes 4 layers of validation:

| Layer | What | Tests |
|-------|------|-------|
| **Static analysis** | Contract, sandbox, Lua 5.5 syntax | 2339 Python tests |
| **Manifest validation** | Schema, protocol/DER matching, semver | 53 manifests |
| **Mock execution** | Full lifecycle with simulated device | 53 Lua harness tests |
| **Sandbox safety** | No io/os/debug, no require, no globals leak | 53 drivers |

```bash
# Run everything
cd drivers
python3 -m pytest tests/ -v          # 2339 tests
lua tests/lua_harness/test_all_drivers.lua  # 53 drivers
python3 tools/validate_manifest.py    # 53 manifests
bash tools/check_sandbox.sh           # sandbox safety
```

---

## Adding a New Device

1. Write `drivers/lua/<name>.lua` (~100-300 lines of Lua)
2. Write `drivers/manifests/<name>.yaml` (metadata)
3. Run tests, open PR
4. CI validates automatically
5. On merge: driver appears in API, available for OTA to all gateways

**Time to add a typical Modbus device**: 1-2 hours (register map + Lua driver + manifest).

---

## Comparison

| | Sourceful | Reduxi (claimed) |
|--|-----------|-----------------|
| **Device entries** | 551+ variants | ~367 entries |
| **Brands** | 46 | 50+ |
| **Driver framework** | Lua (portable, OTA-updatable) | Compiled (firmware update needed) |
| **Open drivers** | Yes (Lua source) | No |
| **Community contributions** | PR a .lua file | Not possible |
| **Update mechanism** | Per-driver OTA | Full firmware |
