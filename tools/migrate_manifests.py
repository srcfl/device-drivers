#!/usr/bin/env python3
"""Migrate manifests from JSON V1 to YAML V2 format.

Reads manifests/*.json files and writes manifests/*.yaml with tier, version,
author, signature, and other V2 fields. Optionally removes old JSON files.

Usage:
    uv run tools/migrate_manifests.py [--remove-json]
"""

import json
import hashlib
import sys
from pathlib import Path

# Mapping of driver names to known metadata
DRIVER_METADATA = {
    "sungrow": {
        "tested_devices": [{"model": "SH-RT", "manufacturer": "Sungrow"}],
        "dkb_id": "sungrow_sh_rt",
    },
    "solis": {
        "tested_devices": [{"model": "S6-EH3P", "manufacturer": "Solis"}],
        "dkb_id": "solis",
    },
    "solaredge": {
        "tested_devices": [{"model": "SE Series", "manufacturer": "SolarEdge"}],
        "dkb_id": "solaredge",
    },
    "sma": {
        "tested_devices": [{"model": "Sunny Tripower X", "manufacturer": "SMA"}],
        "dkb_id": "sma",
    },
    "huawei": {
        "tested_devices": [{"model": "SUN2000", "manufacturer": "Huawei"}],
        "dkb_id": "huawei_sun2000",
    },
    "fronius": {
        "tested_devices": [{"model": "Symo GEN24", "manufacturer": "Fronius"}],
        "dkb_id": "fronius_symo_gen24",
    },
    "fronius_smart_meter": {
        "tested_devices": [{"model": "Smart Meter TS", "manufacturer": "Fronius"}],
        "dkb_id": "fronius_smart_meter",
    },
    "deye": {
        "tested_devices": [{"model": "SUN Series", "manufacturer": "Deye"}],
        "dkb_id": "deye",
    },
    "pixii": {
        "tested_devices": [{"model": "PowerShaper 2.0", "manufacturer": "Pixii"}],
        "dkb_id": "pixii",
    },
    "sdm630": {
        "tested_devices": [{"model": "SDM630", "manufacturer": "Eastron"}],
        "dkb_id": "sdm630",
    },
    "ferroamp": {
        "tested_devices": [{"model": "EnergyHub XL", "manufacturer": "Ferroamp"}],
        "dkb_id": "ferroamp",
    },
    "ambibox": {
        "tested_devices": [{"model": "V2X Charger", "manufacturer": "Ambibox"}],
        "dkb_id": "ambibox",
    },
    "p1_meter": {
        "tested_devices": [{"model": "DSMR P1", "manufacturer": "Various"}],
        "dkb_id": "p1_meter",
    },
    "hello": {
        "tested_devices": [],
        "dkb_id": "",
    },
}


def yaml_list(items: list, indent: int = 2) -> str:
    """Format a list as YAML inline or block style."""
    if all(isinstance(i, str) for i in items) and len(items) <= 5:
        return "[" + ", ".join(items) + "]"
    lines = []
    prefix = " " * indent
    for item in items:
        if isinstance(item, dict):
            first = True
            for k, v in item.items():
                if first:
                    lines.append(f"{prefix}- {k}: \"{v}\"" if isinstance(v, str) else f"{prefix}- {k}: {v}")
                    first = False
                else:
                    lines.append(f"{prefix}  {k}: \"{v}\"" if isinstance(v, str) else f"{prefix}  {k}: {v}")
        else:
            lines.append(f"{prefix}- {item}")
    return "\n" + "\n".join(lines)


def compute_sha256(filepath: Path) -> str:
    """Compute SHA256 hash of a file."""
    return hashlib.sha256(filepath.read_bytes()).hexdigest()


def migrate_manifest(json_path: Path, drivers_dir: Path) -> str:
    """Convert a V1 JSON manifest to V2 YAML format."""
    with open(json_path) as f:
        data = json.load(f)

    name = data["name"]
    protocol = data["protocol"]
    ders = data.get("ders", [])
    control = data.get("control", False)
    size_bytes = data.get("size_bytes", 0)

    meta = DRIVER_METADATA.get(name, {"tested_devices": [], "dkb_id": ""})

    # Determine tier: hello is community, everything else is core (Sourceful-maintained)
    tier = "community" if name == "hello" else "core"

    # Compute actual size and SHA256 from driver file
    driver_path = drivers_dir / f"{name}.lua"
    if driver_path.exists():
        size_bytes = driver_path.stat().st_size
        sha256 = compute_sha256(driver_path)
    else:
        sha256 = ""

    # Build YAML manually to control field order
    lines = [
        f'name: "{name}"',
        f'version: "1.0.0"',
        f"tier: {tier}",
        f'author: "Sourceful Labs AB"' if tier == "core" else f'author: ""',
        f"protocol: {protocol}" if protocol else 'protocol: ""',
        f"ders: {yaml_list(ders)}",
        f"control: {'true' if control else 'false'}",
    ]

    # Tested devices
    if meta["tested_devices"]:
        lines.append(f"tested_devices:{yaml_list(meta['tested_devices'])}")
    else:
        lines.append("tested_devices: []")

    lines.extend([
        f'min_host_version: "2.0.0"',
        f"size_bytes: {size_bytes}",
        f'dkb_id: "{meta["dkb_id"]}"',
        f'sha256: "{sha256}"',
        f'signature: ""',
    ])

    return "\n".join(lines) + "\n"


def main():
    remove_json = "--remove-json" in sys.argv

    repo_root = Path(__file__).resolve().parent.parent
    manifests_dir = repo_root / "manifests"
    drivers_dir = repo_root / "drivers"

    json_files = sorted(manifests_dir.glob("*.json"))
    if not json_files:
        print("No JSON manifest files found.")
        return

    print(f"Migrating {len(json_files)} manifests from JSON V1 to YAML V2...")

    for json_path in json_files:
        yaml_content = migrate_manifest(json_path, drivers_dir)
        yaml_path = json_path.with_suffix(".yaml")
        yaml_path.write_text(yaml_content)
        print(f"  {json_path.name} -> {yaml_path.name}")

        if remove_json:
            json_path.unlink()
            print(f"  Removed {json_path.name}")

    print(f"\nDone. {len(json_files)} YAML manifests written to {manifests_dir}/")


if __name__ == "__main__":
    main()
