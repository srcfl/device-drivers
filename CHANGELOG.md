# Changelog

All notable changes to drivers in this repository are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Driver versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **FTW's 37 field-proven drivers are now the source.** They had run on customer sites for months while this repository treated its own 62 drivers of unknown provenance as the truth. Every serious defect found here was in the catalog, never in FTW's drivers — a sign bug flipping every float in 12 of them, 35 calling host functions that do not exist, 60 of 62 manifest hashes lying, a Sungrow control path that charges when told to discharge. The wrong set was being repaired. All 37 are promoted verbatim and kept byte-identical to `baselines/ftw`, which is what makes provenance checkable and any later edit visible
- The DER vocabulary knew only `pv`, `battery`, `meter` and `v2x_charger`. FTW also emits `ev`, `heatpump` and `vehicle`, so eight shipped drivers had no honest way to describe themselves. `myuplink` emits only metrics and now declares none rather than claiming telemetry it never sends
- `spec/host-api-profile.json` called `modbus_write` and `millis` "spellings this catalog grew on its own". They are FTW's real API names. It also omitted the entire transport layer — `ws_open`, `tcp_open`, `mqtt_pub`, `persist_secret`. The function list now comes from FTW's Go binding rather than from assumption

### Added
- **`blueprint/BLUEPRINT.lua`** — a complete, working driver for an imaginary inverter, written for people and agents alike. Every rule this repository enforces appears beside the code that follows it: bounded probing, never fabricating a zero, decoding on 16-bit halves, negating at the sign boundary. `tests/test_blueprint.py` holds it to every rule a shipped driver must meet and runs it against the harness, including the test that matters most — that failed reads per poll settle to zero, because a driver that never gives up takes the site offline
- **`docs/WRITING-A-DRIVER.md`** — the reasoning behind each rule, with the blueprint as the specification

### Removed
- `tools/canonical_debt.py` measured distance from an ideal that never existed. In its place `tools/host_api_check.py` asks the only question that predicts a crash: does a driver call a function no host provides? That is what 35 drivers were doing while passing every test here
- Tests pinning the behaviour of catalog drivers that have been replaced. They tested code that no longer exists; FTW tests the promoted drivers in Go

### Added
- `spec/host-api-profile.json` defines what a canonical driver may call on a linux-edge host, enforced by `make check`. Blixt L1 is the naming reference: endianness belongs in the name (`decode_u32_be`, not `decode_u32`), identification has its own setters (`set_model`, `set_rated_w`, `set_warmup_s`), and `decode_string` replaces the register loop every driver writes by hand
- `tools/canonical_debt.py` and `canonical-debt.json` count how far the catalog still is from that shape — 370 items across all 62 drivers. `make check` fails if the count grows, so a new driver cannot add to it and a converted driver ratchets it down

### Changed
- This repository targets linux-edge hosts only: FTW and Blixt L1. `zap-firmware` is no longer a package target and `zap` is no longer a host product; Zap is built on a separate track that compiles from this source
- `drivers/lua/GUIDELINES.md` no longer sets a bytecode ceiling. It described Zap's 48 KB shared Lua pool, which does not apply to a linux-edge host
- `spec/host-api.md` documents `set_sn`, `set_poll_interval`, `set_device_fault` and `emit_metric`. All four were already called by shipped drivers without appearing in the spec

### Added
- **sungrow** 1.3.0 — Takes three things from FTW's bundled `sungrow-shx` that the catalog driver never had: the running-state fault channel, so a faulted inverter is reported as faulted instead of reading as a healthy 0 W; an MPPT fallback for firmware that leaves register 5016 at zero while the strings clearly generate; and diagnostic metrics that make both PV readings visible when they disagree. This is the first of the 20 drivers that exist in both repositories to be reconciled
- The Lua test mock gained `emit_metric` and the canonical host aliases `write`, `write_registers` and `now_ms`. It lacked all four, so a driver using them failed in the harness while working on hardware — `hello` was already calling `now_ms`

### Changed
- Every driver now emits the canonical `@srcful/data-models` keys — `W`, `Hz`, `SoC_nom_fract`, `L1_V`, `total_import_Wh` and the rest — and calls the canonical host functions `write`, `write_registers` and `now_ms`. FTW accepts both spellings from v1.11.4-beta.7, so no site loses telemetry. Canonical debt is 0
- `v2x_charger` keeps the short keys. `@srcful/data-models` has no agreed shape for it and Blixt has no v2x driver to take the naming from; `spec/host-api-profile.json` records that as undecided rather than guessing
- Three tests hand-maintained lists of valid decode functions, emit fields and package versions. Each now reads `spec/host-api-profile.json` or the manifest, so a name added to the contract cannot fail a test that was never updated

### Fixed
- **ferroamp_modbus** 1.0.4 — The setpoint encoder had no domain. Infinity spun its normalising loop forever, so a single malformed command hung the driver; a value past float32's range came back with the sign bit set, turning a large charge into a small discharge; NaN produced `nan` register words; and anything below the smallest normal yielded a negative word, which is not a 16-bit number. Setpoints arrive from the control plane, so a unit slip or a NaN from a division upstream reached all of this directly. It now refuses what float32 cannot hold and the command fails instead of writing something arbitrary to a battery. The working range is unchanged, byte for byte
- **ferroamp_modbus** also emitted `inf`. `decode_f32_be` refuses infinity, but the driver then scales kW to W, and an inverter answering with float32's largest value — which some firmware does for a register it cannot serve — decoded to 3.4e38 and overflowed straight back into `inf` on the multiply. All eleven scaled readings are now checked before they reach a site total
- **sdm630** and 11 other drivers decoded every positive float as negative on a 32-bit integer Lua build. The float helper combined both registers into one 32-bit word and tested the sign with `combined >= 0x80000000`, which is always true where that literal is itself negative. `ferroamp_modbus` had the same fault in its encode path, so a battery setpoint could be written with a flipped sign. Both now work on the 16-bit halves, verified by an encode/decode round trip
- Decode helpers that no host provides — `decode_f32_be`, `decode_u64`, `scale` — now live in the driver's own Lua rather than being called on `host`. They are arithmetic, not I/O, so 16 drivers stop depending on a host function that has to be added first
- `make bump-driver` now moves `DRIVER_MANIFEST` and the package recipe alongside the manifest. sdm630 carries all three, and leaving one behind failed the package build
- 35 drivers called `host.decode_u32`, `host.decode_i32` or `host.decode_f32`, which FTW does not implement — it registers `decode_u32_be` and `decode_i32_be`, and no float helper at all. Those drivers would have failed on the host they were built for. All are converted to the canonical `_be` spellings, which fixes 37 call sites outright and leaves the 11 float ones waiting only on FTW gaining `decode_f32_be`
- The Lua test mock implemented decode helpers no host provides, so the suite passed while the drivers could not have run. `test_modbus_drivers` now reads the allowed decode set from `spec/host-api-profile.json` instead of a hand-maintained list

### Fixed
- **sungrow** 1.2.1 and FTW target 1.3.3 — Read the device type code and skip the SH hybrid block on string inverters. SG models such as the SG12RT have no battery and no 13xxx block, so the unconditional hybrid reads failed the whole poll and took the device offline instead of reporting the PV it does have. The battery and meter streams are emitted only when their registers answered, so a string inverter no longer reports a battery at 0% that does not exist. Battery commands are refused on a string model. Registers are written off as absent only after three failed reads in a row, so a timeout cannot silence a healthy inverter.
- Manifest `sha256` and `size_bytes` now describe the Lua file each manifest names. They were maintained by hand and had drifted on 60 of 62 drivers; `validate_manifest.py` only checked that the size was a non-negative number. `make check` regenerates them and fails on any difference

### Added
- `make bump-driver ID=<id> LEVEL=patch` raises a driver version in the manifest and the `DRIVER` table together, then refreshes the generated catalog
- `make sync-manifests` derives manifest `sha256` and `size_bytes` from the source
- `driver-history.json` and `make history` record every published driver version with its source hash, size, first commit and date, so an operator can recover the exact bytes of an older driver. The record is append-only and `make check` fails if a published version is rewritten or dropped

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
