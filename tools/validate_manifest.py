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
from manifest_parser import parse_yaml_simple, parse_tested_devices, parse_upstream_docs

REQUIRED_FIELDS = ["name", "version", "tier", "protocol", "ders", "size_bytes",
                   "connectivity"]
VALID_TIERS = {"core", "community", "oem"}
VALID_PROTOCOLS = {"modbus", "mqtt", "serial", "standalone", "http", ""}
# Where a driver talks while it runs, which is not what `protocol` says. Two
# NIBE heat pumps ship as `protocol: http` and are opposites: nibe_local reads
# the pump over the LAN, myuplink reads NIBE's cloud. An owner asking whether a
# device survives an internet outage cannot answer that from the protocol.
VALID_CONNECTIVITY = {"local", "cloud"}
# What a human has to obtain once, and from whom, before the driver can connect
# at all -- including when the driver itself never leaves the LAN. An absent
# `setup` means nobody has recorded one, which is not the same as none; only
# `[none]` claims a device needs nothing but an address.
VALID_SETUP = {
    "none",             # nothing beyond reaching the device on the network
    "device_screen",    # enabled on the device's own display or keypad
    "device_ui",        # enabled in the device's own local web interface
    "vendor_app",       # requires the manufacturer's phone app
    "vendor_portal",    # requires an account, API key or OAuth app from the vendor
    "installer",        # requires installer-level access or a service partner
    "vendor_approval",  # the manufacturer must enable it for this site on request
    "bridge",           # requires separate hardware or firmware in between
}
# The DER types FTW's drivers actually emit. `ev` is a charger, `v2x_charger`
# one that can also discharge, and `vehicle` the car itself rather than the
# thing it plugs into. The catalog knew only the first four, so eight shipped
# drivers had no honest way to describe themselves.
VALID_DERS = {"pv", "battery", "meter", "v2x_charger", "ev", "heatpump", "vehicle"}
SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+$")

REQUIRED_DEVICE_FIELDS = {"manufacturer", "model_family"}
VALID_DEVICE_FIELDS = {"manufacturer", "model_family", "model", "variants", "regions",
                        "firmware_versions", "min_driver_version", "notes"}

# Upstream reference documents a driver was built against (register maps,
# parameter changelogs, manuals). Their URLs are semi-persistent so a watcher
# can poll them and flag a driver for review when the source moves.
VALID_UPSTREAM_DOC_FIELDS = {"url", "title", "kind", "url_stability"}
VALID_UPSTREAM_DOC_KINDS = {"changelog", "register_map", "manual", "api_docs",
                            "firmware_notes", "other"}
# How durable the URL is — does the manufacturer keep it put? It weighs how
# loudly the watcher should complain when the link breaks.
#   committed = manufacturer documents/promises the URL is permanent
#   stable    = stable in practice, no explicit promise
#   volatile  = known to rotate (dated or versioned links)
#   unknown   = not assessed (also the default when the field is absent)
VALID_URL_STABILITY = {"committed", "stable", "volatile", "unknown"}


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

    # Validate connectivity
    connectivity = data.get("connectivity")
    if connectivity is not None and connectivity not in VALID_CONNECTIVITY:
        errors.append(
            f"connectivity '{connectivity}' is not valid "
            f"(expected: {', '.join(sorted(VALID_CONNECTIVITY))})")

    # Validate setup. Absent is allowed and means unrecorded; an empty list is
    # not, because it reads as "nothing required" without anyone saying so.
    if "setup" in data:
        setup = data["setup"]
        if not isinstance(setup, list):
            errors.append(f"setup must be a list, got: {type(setup).__name__}")
        elif not setup:
            errors.append("setup is empty: omit the field, or state [none]")
        else:
            for gate in setup:
                if gate not in VALID_SETUP:
                    errors.append(
                        f"invalid setup requirement: '{gate}' "
                        f"(expected: {', '.join(sorted(VALID_SETUP))})")
            if "none" in setup and len(setup) > 1:
                errors.append("setup 'none' cannot be combined with another requirement")

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

    # Validate upstream_docs
    docs = parse_upstream_docs(text)
    for i, doc in enumerate(docs):
        prefix = f"upstream_docs[{i}]"

        url = doc.get("url", "")
        if not url:
            errors.append(f"{prefix}: missing required field 'url'")
        elif not (url.startswith("http://") or url.startswith("https://")):
            errors.append(f"{prefix}: url must be an http(s) URL, got '{url}'")

        kind = doc.get("kind", "")
        if kind and kind not in VALID_UPSTREAM_DOC_KINDS:
            errors.append(f"{prefix}: kind '{kind}' is not valid "
                          f"(expected: {', '.join(sorted(VALID_UPSTREAM_DOC_KINDS))})")

        stability = doc.get("url_stability", "")
        if stability and stability not in VALID_URL_STABILITY:
            errors.append(f"{prefix}: url_stability '{stability}' is not valid "
                          f"(expected: {', '.join(sorted(VALID_URL_STABILITY))})")

        for key in doc:
            if key not in VALID_UPSTREAM_DOC_FIELDS:
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
