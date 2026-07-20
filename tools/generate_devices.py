#!/usr/bin/env python3
"""Generate devices.yaml device catalog from YAML manifests.

Reads all manifests/*.yaml and produces a manufacturer-centric device
hierarchy at devices.yaml in the repo root.

Usage:
    uv run tools/generate_devices.py
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from manifest_parser import parse_yaml_simple, parse_tested_devices


def yaml_list_inline(items: list) -> str:
    """Format list as YAML inline."""
    if not items:
        return "[]"
    return "[" + ", ".join(items) + "]"


def yaml_escape(s: str) -> str:
    """Wrap string in quotes if it contains special chars."""
    if not s:
        return '""'
    if any(c in s for c in ":{}[],'\"#&*!|>%@`"):
        return f'"{s}"'
    return f'"{s}"'


def main():
    repo_root = Path(__file__).resolve().parent.parent
    manifests_dir = repo_root / "manifests"

    yaml_files = sorted(manifests_dir.glob("*.yaml"))
    if not yaml_files:
        print("No YAML manifest files found.")
        return

    # Build catalog: manufacturer -> model_family -> {variants, regions, protocols, ...}
    catalog: dict[str, dict[str, dict]] = {}

    for yaml_path in yaml_files:
        text = yaml_path.read_text()
        data = parse_yaml_simple(text)
        devices = parse_tested_devices(text)

        driver_name = data.get("name", yaml_path.stem)
        version = data.get("version", "1.0.0")
        protocol = data.get("protocol", "")
        ders = data.get("ders", [])
        control = data.get("control", False)

        for device in devices:
            manufacturer = device.get("manufacturer", "Unknown")
            model_family = device.get("model_family", device.get("model", "Unknown"))
            variants = device.get("variants", [])
            if isinstance(variants, str):
                variants = [v.strip() for v in variants.split(",") if v.strip()]
            regions = device.get("regions", [])
            if isinstance(regions, str):
                regions = [r.strip() for r in regions.split(",") if r.strip()]
            firmware_versions = device.get("firmware_versions", "")
            notes = device.get("notes", "")

            if manufacturer not in catalog:
                catalog[manufacturer] = {}

            if model_family not in catalog[manufacturer]:
                catalog[manufacturer][model_family] = {
                    "variants": set(),
                    "regions": set(),
                    "protocols": [],
                    "firmware_versions": firmware_versions,
                    "notes": notes,
                }

            entry = catalog[manufacturer][model_family]
            if isinstance(variants, list):
                entry["variants"].update(variants)
            if isinstance(regions, list):
                entry["regions"].update(regions)

            entry["protocols"].append({
                "protocol": protocol,
                "driver": driver_name,
                "version": version,
                "ders": ders,
                "control": control,
            })

            # Merge firmware/notes (keep non-empty)
            if firmware_versions and not entry["firmware_versions"]:
                entry["firmware_versions"] = firmware_versions
            if notes and not entry["notes"]:
                entry["notes"] = notes

    # Build devices.yaml
    lines = [
        "version: 1",
        "manufacturers:",
    ]

    for mfr_name in sorted(catalog.keys()):
        lines.append(f"  - name: {yaml_escape(mfr_name)}")
        lines.append("    model_families:")

        for family_name in sorted(catalog[mfr_name].keys()):
            entry = catalog[mfr_name][family_name]
            variants = sorted(entry["variants"])
            regions = sorted(entry["regions"])

            lines.append(f"      - name: {yaml_escape(family_name)}")
            lines.append(f"        variants: {yaml_list_inline(variants)}")
            lines.append(f"        regions: {yaml_list_inline(regions)}")
            lines.append("        protocols:")

            for proto in entry["protocols"]:
                lines.append(f"          - protocol: {proto['protocol']}" if proto["protocol"] else '          - protocol: ""')
                lines.append(f"            driver: \"{proto['driver']}\"")
                lines.append(f"            version: \"{proto['version']}\"")
                lines.append(f"            ders: {yaml_list_inline(proto['ders'])}")
                lines.append(f"            control: {'true' if proto['control'] else 'false'}")

            lines.append(f"        firmware_versions: {yaml_escape(entry['firmware_versions'])}")
            lines.append(f"        notes: {yaml_escape(entry['notes'])}")

    devices_path = repo_root / "devices.yaml"
    devices_path.write_text("\n".join(lines) + "\n")
    print(f"Generated {devices_path} with {len(catalog)} manufacturers.")


if __name__ == "__main__":
    main()
