# Changelog

All notable changes to drivers in this repository are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Driver versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- **sungrow** 1.5.1 — **The string-inverter guard, returning, on the write path this time.** `driver_command` accepted a `battery` setpoint on a model the driver had already classified as a string inverter. That is not a no-op: it wrote forced mode to 13049, a force command to 13050 and a setpoint to 13051 — a register block an SG model does not implement — and then answered **success**, because the read-back that would have caught it fails on such a device and a failed read-back is assumed transient. So the host recorded an applied setpoint, renewed the lease on it, and the planner went on dispatching a battery that is not there. It now refuses with `no_battery`, the same code `packages/v1/sungrow/targets/ftw.lua` already returns, and writes nothing. Curtail is untouched: an SG inverter has no battery, but it does have PV
- This guard shipped once already, in #17 as part of 1.2.1 — `if model_family == "string" then return false end`, with the comment explaining why. Promoting FTW's drivers in #27 replaced the catalog file wholesale and took it out. #29 restored the **read** half at 1.4.0 and stopped there. The guard survived in the FTW v2 target, whose own test was green throughout. Third time this shape of regression reaches the catalog driver, after Pixii's 40288 and SolarEdge legacy's 40123, and the third time a package target's green test hid it
- `drivers/tests/lua_harness/` caught this and gated nothing, because CI runs pytest and not the Lua harness. The guard now lives in `drivers/tests/test_sungrow_model_family.py`, which runs. It pins the refusal, the code and the reason in the log, and pins the two ways refusing could go too far: a hybrid must still take a battery command, and a string inverter must still take a curtail
- **sigenergy** 1.1.1 — Removed the ESS State of Health read at register 30087 (`input`, U16, gain 10). The result was thrown away; nothing in `spec/host-api.md`, the canonical battery keys or `test_emit_fields.py` has anywhere to put SoH, and the read cost a failed Modbus round trip every poll once the register went unanswered. `drivers/tests/absent-register-baseline.json` sigenergy count drops from 6 to 5.

### Added
- **The flap that took Pixii and SolarEdge legacy offline is now measured across the whole catalog, and it is not two drivers.** `drivers/tests/test_absent_register_settles.py` takes every register a driver reads, makes that register stop answering, and watches ten polls. The rule: a driver that keeps reporting telemetry must not keep failing reads. Emitting nothing while failing is fine — a device that cannot answer its identity block really is unreadable. Doing both is the outage, because the host counts every failed `modbus_read` against the poll and the watchdog marks the driver offline
- The first run found **49 of 50 Modbus drivers violating the rule on at least one register — 497 of 543 probed addresses.** Pixii and SolarEdge legacy were not unlucky; they were the two that met firmware omitting a register they happened to read. `drivers/tests/absent-register-baseline.json` records that debt and the test ratchets against it: a count that rises fails, a driver not listed must be clean, and a count that falls fails until the file is updated, so the debt cannot be quietly re-borrowed. Shrink it, never grow it. `make absent-register-report ID=<id>` prints the registers for one driver
- `tests/test_blueprint.py` had held the blueprint to this property since it was written. It applied to an imaginary driver and to none of the ones that ship

### Fixed
- **The FTW exemption was hiding the outage it caused.** `drivers/tests/conftest.py` skips catalog-convention checks for every driver promoted from FTW, which is right for conventions this repository grew and FTW never spoke — spelling, key names, structure. It was applied to all parametrised checks without distinction, so a rule about what a driver does on hardware was skipped for exactly the 34 drivers the outage happened in. A check marked `holds_for_ftw_drivers` now applies to every driver. Without it the new suite silently measured 46 drivers and reported success

### Fixed
- **pixii package** 1.2.4 — The package target carried the narrow fix from #16, which guarded register 40288 alone. Every other scale factor it reads — 40084, 40086, 40106, 40177, 40180, 40182, 40184, 40240, 40249, 40251, 40256 — would flap the poll counter the same way if that firmware omitted it. It now uses the same per-address probe as the catalog driver: measured 3 reads of an absent 40256 over 3 polls before, 1 after. Both files are held to the rule by one parametrised test, because the package target having its own green test is what hid the catalog regression

### Changed
- `AGENTS.md` says where a driver change has to land. There are three places a driver can exist — the catalog driver, an optional package target that is **not** generated from it, and FTW's bundled snapshot — and no check catches a fix that lands in one and not the others. It also records that a promoted driver drops its `baselines/ftw` exemption the moment it is edited, so `make check` starting to fail on rules that driver never met is the system working
- FTW's `drivers/` is generated from this repository at the commit pinned in FTW's `drivers/BUNDLED_SOURCE.json`. Merging here does not move that pin, so a gateway booting offline keeps running the old driver until someone does. Neither repository's docs said so; `AGENTS.md` and `SOURCE_IMPORT.md` do now
- `README.md` claimed the 37 promoted drivers are kept byte-identical to `baselines/ftw/drivers/`. Three no longer are, which is what fixing a driver means. The baseline is a record of what was imported, not a mirror of what ships
- `SOURCE_IMPORT.md` still weighed whether the bundled drivers could replace their catalog namesakes, one at a time. #27 answered that months of customer runtime ago, by promoting all 37 at once
- `CLAUDE.md` was missing. It points at `AGENTS.md` rather than copying it

### Fixed
- **pixii** 2.1.1 — **The 40288 flap, returning.** PowerShaper firmware below CPU 2.0.23 answers Modbus exception 2 on register 40288 (`meter_energy_sf`). The driver caught that in `pcall` and fell back to sf=0, which is the right value — but the host counts the failed read against the poll whether or not Lua handled it, so the driver sat at "1 of 37 reads failed" every five seconds, went offline on the stale-telemetry watchdog, and stopped feeding the planner. It now probes each scale factor once, remembers the absent ones and stops asking. A restart re-probes, so a firmware update that adds the register is picked up. This was fixed once already, in #16 for issue #15; the fix lived only in `packages/v1/pixii/targets/ftw.lua`, so promoting FTW's driver in #27 reverted the catalog copy and the flap reached customer hardware again. The test added here runs the catalog driver, which is what the signed channel publishes
- **solaredge_legacy** 0.3.1 — Same failure, different register. K-series inverters (SE7K/10K/17K/25K, the display era) do not populate the proprietary MPPT block at 40123, so every poll spent a failed read on it and the driver flapped offline with PV data never reaching the planner. It now probes once and emits Model 103 metrics alone when the block is absent
- `_extract_decode_calls` in the Modbus test suite counted a nested call's comma as an argument separator, so `host.decode_i16(reg(regs, 40084))` read as two arguments and failed a driver that was correct. It now matches parentheses and splits only at depth zero. The bug stayed hidden because the drivers that write decode calls this way were byte-identical to `baselines/ftw` and therefore exempt from the suite

### Changed
- The 19 drivers whose implementation was replaced by FTW's move to a **major version**. The signed channel refuses to publish changed bytes under a version it already published — that immutability is what makes rollback mean anything — so the release failed until they moved. A major bump is also the honest signal: these are different implementations, not patches, and an operator pinning a version needs to know that

### Fixed
- **sungrow** 1.4.0 — **The SG12RT outage.** Sungrow ships two families behind one driver: SH hybrids answer the 13xxx block, SG string inverters have no battery and answer none of it. The driver read that block regardless, and because the host fails a whole poll when any single read fails, a string inverter did not report less telemetry — it reported none. A customer's SG12RT lost everything, 12 of 19 reads failing on every poll. It now asks the device which family it is, using the classification `driver_fingerprint` already had, and reads the hybrid block only when there is reason to. Measured: **zero failed reads from the first poll**, where it was eight
- Detection and the serial read both give up after three tries. A register retried on every poll forever costs a failed read on every poll forever, which is the same outage arriving more slowly. Where detection never succeeds the driver probes once and settles, rather than guessing
- The battery stream was emitted unconditionally, with zeros when its registers had not answered — a fabricated reading on a hybrid, and an entirely invented battery on a string inverter. It is now emitted only when the defining read answered, and each energy counter only when that counter answered: a lifetime counter reporting zero looks like a meter that was reset
- The fault channel cleared only on a non-zero running state, but `0x0000` and `0x0040` are both documented as Running. An inverter that recovered into `0x0000` stayed reported as faulted. It now clears on any running state that was actually read, and a string inverter — which never reads it — neither raises nor clears
- `optional_read` checks every register it asked for, not just the first. A short Modbus reply left the rest nil, and arithmetic on nil ended the whole poll

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
- The **goodwe** package recipe. It promised `read_only: true` and copied `drivers/lua/goodwe.lua` straight through, which was true of the catalog's goodwe and is not true of FTW's — that one has a control path and declares no such thing. Publishing it unchanged would have shipped a control-capable driver under a package that promised it could not write. Rebuilding it needs a write-inert target derived deliberately, the way `packages/v1/sungrow/targets/ftw-observe.lua` was, which is a decision about hardware rather than a build fix

### Added
- `spec/host-api-profile.json` defines what a canonical driver may call on a linux-edge host, enforced by `make check`. Blixt L1 is the naming reference: endianness belongs in the name (`decode_u32_be`, not `decode_u32`), identification has its own setters (`set_model`, `set_rated_w`, `set_warmup_s`), and `decode_string` replaces the register loop every driver writes by hand

### Changed
- This repository targets linux-edge hosts only: FTW and Blixt L1. `zap-firmware` is no longer a package target and `zap` is no longer a host product; Zap is built on a separate track that compiles from this source
- `drivers/lua/GUIDELINES.md` no longer sets a bytecode ceiling. It described Zap's 48 KB shared Lua pool, which does not apply to a linux-edge host
- `spec/host-api.md` documents `set_sn`, `set_poll_interval`, `set_device_fault` and `emit_metric`. All four were already called by shipped drivers without appearing in the spec

### Added
- **sungrow** 1.3.0 — Takes three things from FTW's bundled `sungrow-shx` that the catalog driver never had: the running-state fault channel, so a faulted inverter is reported as faulted instead of reading as a healthy 0 W; an MPPT fallback for firmware that leaves register 5016 at zero while the strings clearly generate; and diagnostic metrics that make both PV readings visible when they disagree. This is the first of the 20 drivers that exist in both repositories to be reconciled
- The Lua test mock gained `emit_metric` and the canonical host aliases `write`, `write_registers` and `now_ms`. It lacked all four, so a driver using them failed in the harness while working on hardware — `hello` was already calling `now_ms`

### Changed
- Every driver now emits the canonical `@srcful/data-models` keys — `W`, `Hz`, `SoC_nom_fract`, `L1_V`, `total_import_Wh` and the rest — and calls the canonical host functions `write`, `write_registers` and `now_ms`. FTW accepts both spellings from v1.11.4-beta.7, so no site loses telemetry.
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
