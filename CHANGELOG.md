# Changelog

All notable changes to drivers in this repository are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Driver versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **pixii** 1.2.1 — First public-source package version; control remains disabled
- **sdm630** 1.1.2 — First public-source package version for FTW and Blixt
- **sungrow** 1.3.1 — First public-source package version; control remains disabled pending FTW process isolation and physical HIL
- Repository provenance now binds public source commits instead of the former private source repository

### Added
- **pixii** 1.2.0 — Staged FTW control v2 package that keeps battery and site-meter telemetry live while calibration marks the battery unavailable for dispatch; control stays disabled pending runtime isolation and physical HIL
- **sungrow** 1.3.0 — Staged FTW control v2 adapter with checked Modbus writes, exact readback, structured results and vendor-auto default mode; the FTW target stays disabled pending runtime isolation and physical HIL
- Canonical `sourceful.driver-package/v1` JSON schemas, deterministic signed packager and SDM630/Sungrow metadata pilots
- Fail-closed target/host/runtime compatibility with explicit control leases, default mode, identity, provenance and rollback metadata
- Blixt L1 target profile and canonical SDM630 read-only pilot based on David's batched Blixt implementation
- Build-time Lua lifecycle and target-manifest checks for FTW and Blixt artifacts
- Signed `sourceful.driver-index/v1` discovery layer for FTW, Blixt, Nova and app consumers without making Hugin a registry
- **p1_dsmr** 2.0.0 — Dedicated DSMR ASCII telegram parser (split from p1_meter)
- **p1_hdlc** 2.0.0 — Dedicated HDLC/DLMS binary frame parser (split from p1_meter)
- **p1_encrypted** 2.0.0 — AES-GCM encrypted meter driver for Belgian/Austrian meters (split from p1_meter)
- **shelly** 1.0.0 — Shelly Gen2/Gen3 HTTP driver (meter) covering Pro 3EM, Pro EM-50, EM Gen3, Plus 1PM/2PM, Pro 4PM, Plus Plug S
- HTTP protocol support (`host.http_get()`) added to driver contract and host API spec
- `"http"` added to valid protocols in manifest validation and type mapping
- Device model hierarchy in manifests (`model_family`, `variants`, `regions`, `firmware_versions`, `notes`)
- Generated device catalog (`devices.yaml`) with manufacturer-centric hierarchy
- Device catalog spec (`spec/device-catalog.md`)
- Shared manifest parser module (`tools/manifest_parser.py`)
- Device catalog generator (`tools/generate_devices.py`)
- CI validation for device catalog consistency and changelog updates
- Versioning policy in manifest spec
- This changelog

### Earlier changes
- All manifests: `tested_devices.model` renamed to `tested_devices.model_family`
- All manifests: version bumped from 1.0.0 to 1.1.0
- Manifest spec (`spec/manifest-v2.md`) updated with new tested_devices fields
- `validate_manifest.py` now validates tested_devices entries
- `validate_manifest.py` and `generate_index.py` use shared parser module

## [1.0.0] - 2026-03-16

### Added
- **ambibox** 1.0.0 — Ambibox V2X Charger MQTT driver (battery, meter, v2x_charger)
- **deye** 1.0.0 — Deye SUN Series Modbus driver (battery, meter, pv)
- **ferroamp** 1.0.0 — Ferroamp EnergyHub MQTT driver (battery, meter, pv)
- **fronius** 1.0.0 — Fronius Symo GEN24 Modbus driver (battery, meter, pv)
- **fronius_smart_meter** 1.0.0 — Fronius Smart Meter TS Modbus driver (meter)
- **hello** 1.0.0 — Hello world example driver (meter)
- **huawei** 1.0.0 — Huawei SUN2000 Modbus driver (battery, meter, pv)
- **p1_meter** 1.0.0 — P1/DSMR Smart Meter serial driver (meter)
- **pixii** 1.0.0 — Pixii PowerShaper Modbus driver (battery, meter)
- **sdm630** 1.0.0 — Eastron SDM630 Modbus driver (meter)
- **sma** 1.0.0 — SMA Sunny Tripower X Modbus driver (battery, meter, pv)
- **solaredge** 1.0.0 — SolarEdge SE Series Modbus driver (meter, pv)
- **solis** 1.0.0 — Solis S6-EH3P Modbus driver (battery, meter, pv)
- **sungrow** 1.0.0 — Sungrow SH-RT Modbus driver (battery, meter, pv)
