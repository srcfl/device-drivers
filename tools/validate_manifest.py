#!/usr/bin/env python3
"""Validate YAML V2 manifests for required fields and correct values.

Usage:
    uv run tools/validate_manifest.py [manifests/*.yaml]
    uv run tools/validate_manifest.py  # validates all manifests
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from manifest_parser import parse_yaml_simple, parse_tested_devices

REQUIRED_FIELDS = ["name", "version", "tier", "protocol", "ders", "size_bytes"]
VALID_TIERS = {"core", "community", "oem"}
VALID_PROTOCOLS = {"modbus", "mqtt", "serial", "standalone", "http", ""}
VALID_DERS = {"pv", "battery", "meter", "v2x_charger"}
SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+$")

REQUIRED_DEVICE_FIELDS = {"manufacturer", "model_family"}
VALID_DEVICE_FIELDS = {"manufacturer", "model_family", "model", "variants", "regions",
                        "firmware_versions", "min_driver_version", "notes"}


def validate_manifest(yaml_path: Path, drivers_dir: Path) -> list[str]:
    """Validate a single manifest file. Returns list of error strings."""
    errors = []
    text = yaml_path.read_text()
    data = parse_yaml_simple(text)

    # Check required fields
    for field in REQUIRED_FIELDS:
        if field not in data:
            errors.append(f"missing required field: {field}")

    # Validate name matches filename
    name = data.get("name", "")
    if name and name != yaml_path.stem:
        errors.append(f"name '{name}' does not match filename '{yaml_path.stem}'")

    # Validate version is semver
    version = data.get("version", "")
    if version and not SEMVER_RE.match(str(version)):
        errors.append(f"version '{version}' is not valid semver (expected X.Y.Z)")

    # Validate tier
    tier = data.get("tier", "")
    if tier and tier not in VALID_TIERS:
        errors.append(f"tier '{tier}' is not valid (expected: {', '.join(sorted(VALID_TIERS))})")

    # Validate protocol
    protocol = data.get("protocol", "")
    if isinstance(protocol, str) and protocol not in VALID_PROTOCOLS:
        errors.append(f"protocol '{protocol}' is not valid (expected: {', '.join(sorted(VALID_PROTOCOLS))})")

    # Validate ders
    ders = data.get("ders", [])
    if isinstance(ders, list):
        for der in ders:
            if der not in VALID_DERS:
                errors.append(f"invalid DER type: '{der}' (expected: {', '.join(sorted(VALID_DERS))})")
    else:
        errors.append(f"ders must be a list, got: {type(ders).__name__}")

    # Validate size_bytes
    size = data.get("size_bytes", 0)
    if isinstance(size, int) and size < 0:
        errors.append(f"size_bytes must be non-negative, got: {size}")

    # Validate bytecode_size
    bc_size = data.get("bytecode_size", 0)
    if isinstance(bc_size, int) and bc_size < 0:
        errors.append(f"bytecode_size must be non-negative, got: {bc_size}")

    # Check driver file exists
    driver_path = drivers_dir / f"{yaml_path.stem}.lua"
    if not driver_path.exists():
        errors.append(f"driver file not found: {driver_path.name}")

    # Core tier must have author
    if tier == "core" and not data.get("author"):
        errors.append("core tier drivers must have an author")

    # Validate tested_devices
    devices = parse_tested_devices(text)
    for i, device in enumerate(devices):
        prefix = f"tested_devices[{i}]"

        # Accept both 'model' (deprecated) and 'model_family'
        has_model_family = "model_family" in device
        has_model = "model" in device

        if not has_model_family and not has_model:
            errors.append(f"{prefix}: missing required field 'model_family'")

        if not device.get("manufacturer"):
            errors.append(f"{prefix}: missing required field 'manufacturer'")

        # Validate field types
        for list_field in ("variants", "regions"):
            if list_field in device and not isinstance(device[list_field], list):
                errors.append(f"{prefix}: '{list_field}' must be a list")

        # Validate min_driver_version is semver when present
        mdv = device.get("min_driver_version", "")
        if mdv and not SEMVER_RE.match(str(mdv)):
            errors.append(f"{prefix}: min_driver_version '{mdv}' is not valid semver")

        # Check for unknown fields
        for key in device:
            if key not in VALID_DEVICE_FIELDS:
                errors.append(f"{prefix}: unknown field '{key}'")

    return errors


def main():
    repo_root = Path(__file__).resolve().parent.parent
    manifests_dir = repo_root / "manifests"
    drivers_dir = repo_root / "drivers" / "lua"

    # Accept specific files or validate all
    if len(sys.argv) > 1:
        yaml_files = [Path(f) for f in sys.argv[1:]]
    else:
        yaml_files = sorted(manifests_dir.glob("*.yaml"))

    if not yaml_files:
        print("No YAML manifest files found.")
        sys.exit(1)

    total_errors = 0
    for yaml_path in yaml_files:
        errors = validate_manifest(yaml_path, drivers_dir)
        if errors:
            print(f"FAIL {yaml_path.name}:")
            for err in errors:
                print(f"  - {err}")
            total_errors += len(errors)
        else:
            print(f"OK   {yaml_path.name}")

    print(f"\n{len(yaml_files)} manifests checked, {total_errors} errors.")
    sys.exit(1 if total_errors > 0 else 0)


if __name__ == "__main__":
    main()
