# Manifest V2 Format

Each driver has a YAML manifest in `manifests/` that describes its metadata, capabilities, and tier.

## Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | Yes | Driver name, must match filename (e.g., `sungrow` → `sungrow.yaml`) |
| `version` | string | Yes | Semantic version (`X.Y.Z`) |
| `tier` | string | Yes | One of: `core`, `community`, `oem` |
| `author` | string | Yes (core) | Author name or organization |
| `protocol` | string | Yes | `modbus`, `mqtt`, `serial`, `standalone`, or `""` |
| `ders` | list | Yes | DER types: `pv`, `battery`, `meter`, `v2x_charger` |
| `control` | bool | Yes | Whether the driver supports EMS control commands |
| `tested_devices` | list | No | Devices tested against (see below) |
| `min_host_version` | string | No | Minimum gateway firmware version required |
| `size_bytes` | int | Yes | Size of the `.lua` file in bytes |
| `dkb_id` | string | No | Corresponding Hugin DKB device profile ID |
| `sha256` | string | No | SHA256 hash of the `.lua` file |
| `signature` | string | No | Ed25519 signature (core tier only) |
| `bytecode_sha256` | string | No | SHA256 hash of the compiled `.luac` bytecode |
| `bytecode_signature` | string | No | Ed25519 signature of the bytecode hash |
| `bytecode_size` | int | No | Size of the `.luac` bytecode file in bytes |
| `changelog` | string | No | Version-specific release notes |

## Tested Devices

The `tested_devices` list describes the device models a driver has been verified against.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `manufacturer` | string | Yes | Manufacturer name (e.g., `"Huawei"`) |
| `model_family` | string | Yes | Product line or model family (e.g., `"SUN2000"`) |
| `variants` | list | No | Specific model numbers tested (e.g., `[SUN2000-10KTL-M1]`) |
| `regions` | list | No | Regional variants (e.g., `[EU, CN, INT]`) |
| `firmware_versions` | string | No | Firmware compatibility info (free text) |
| `min_driver_version` | string | No | Minimum driver version required for this model family (semver) |
| `notes` | string | No | Caveats, known limitations, or special behavior |

A driver may list multiple `tested_devices` entries if it supports devices from different manufacturers or distinct model families.

## Example

```yaml
name: "sungrow"
version: "1.1.0"
tier: core
author: "Sourceful Labs AB"
protocol: modbus
ders: [battery, meter, pv]
control: true
tested_devices:
  - manufacturer: "Sungrow"
    model_family: "SH-RT"
    variants: [SH5.0RT, SH6.0RT, SH8.0RT, SH10RT]
    regions: [EU]
    firmware_versions: ""
    notes: ""
min_host_version: "2.0.0"
size_bytes: 6968
dkb_id: "sungrow_sh_rt"
sha256: "abc123..."
signature: ""
bytecode_sha256: ""
bytecode_signature: ""
bytecode_size: 0
```

## Versioning Policy

Drivers follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) (MAJOR.MINOR.PATCH):

- **PATCH** (`1.0.0` → `1.0.1`): Bug fixes, register corrections, improved error handling
- **MINOR** (`1.0.0` → `1.1.0`): New features, new tested devices, new DER support, added model variants
- **MAJOR** (`1.0.0` → `2.0.0`): Breaking changes (protocol change, config format change, removed DER support)

Version changes must be accompanied by a `CHANGELOG.md` entry under `[Unreleased]`.

## Validation Rules

1. `name` must match the YAML filename (without extension)
2. `version` must be valid semantic versioning
3. `tier` must be one of the three valid tiers
4. `protocol` must be a known protocol or empty string
5. All entries in `ders` must be valid DER types
6. `size_bytes` must be non-negative
7. `core` tier drivers must have an `author`
8. Every manifest must have a corresponding `.lua` file in `drivers/`
9. `tested_devices` entries must have `manufacturer` and `model_family`

## Migration from V1

V1 manifests were JSON files with fields: `name`, `protocol`, `ders`, `control`, `size_bytes`.

V2 adds: `version`, `tier`, `author`, `tested_devices`, `min_host_version`, `dkb_id`, `sha256`, `signature`.

V2.1 extends `tested_devices` with: `model_family` (replaces `model`), `variants`, `regions`, `firmware_versions`, `notes`.

V2.2 adds bytecode fields: `bytecode_sha256`, `bytecode_signature`, `bytecode_size` for Lua 5.5.0 compiled bytecode.

Use `tools/migrate_manifests.py` to convert V1 JSON → V2 YAML.
