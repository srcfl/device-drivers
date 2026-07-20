#!/usr/bin/env python3
"""Generate index.yaml registry index from YAML manifests.

Reads all manifests/*.yaml files and produces index.yaml at the repo root.

Usage:
    uv run tools/generate_index.py
"""

import hashlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from manifest_parser import parse_yaml_simple


def yaml_list_inline(items: list) -> str:
    """Format list as YAML inline."""
    return "[" + ", ".join(items) + "]"


def main():
    repo_root = Path(__file__).resolve().parent.parent
    manifests_dir = repo_root / "manifests"
    drivers_dir = repo_root / "drivers" / "lua"

    yaml_files = sorted(manifests_dir.glob("*.yaml"))
    if not yaml_files:
        print("No YAML manifest files found. Run migrate_manifests.py first.")
        return

    entries = []
    for yaml_path in yaml_files:
        data = parse_yaml_simple(yaml_path.read_text())
        name = data.get("name", yaml_path.stem)

        # Compute SHA256 from actual driver file
        driver_path = drivers_dir / f"{name}.lua"
        if driver_path.exists():
            sha256 = hashlib.sha256(driver_path.read_bytes()).hexdigest()
            size_bytes = driver_path.stat().st_size
        else:
            sha256 = data.get("sha256", "")
            size_bytes = data.get("size_bytes", 0)

        # Bytecode fields from manifest
        bytecode_sha256 = data.get("bytecode_sha256", "")
        bytecode_size = data.get("bytecode_size", 0)

        entries.append({
            "name": name,
            "version": data.get("version", "1.0.0"),
            "tier": data.get("tier", "community"),
            "protocol": data.get("protocol", ""),
            "ders": data.get("ders", []),
            "control": data.get("control", False),
            "size_bytes": size_bytes,
            "sha256": sha256,
            "bytecode_sha256": bytecode_sha256,
            "bytecode_size": bytecode_size,
        })

    # Build index.yaml
    lines = ["version: 1", "drivers:"]
    for e in entries:
        lines.append(f'  - name: "{e["name"]}"')
        lines.append(f'    version: "{e["version"]}"')
        lines.append(f'    tier: {e["tier"]}')
        lines.append(f'    protocol: {e["protocol"]}' if e["protocol"] else '    protocol: ""')
        lines.append(f'    ders: {yaml_list_inline(e["ders"])}')
        lines.append(f'    control: {"true" if e["control"] else "false"}')
        lines.append(f'    size_bytes: {e["size_bytes"]}')
        lines.append(f'    sha256: "{e["sha256"]}"')
        if e["bytecode_sha256"]:
            lines.append(f'    bytecode_sha256: "{e["bytecode_sha256"]}"')
            lines.append(f'    bytecode_size: {e["bytecode_size"]}')

    index_path = repo_root / "index.yaml"
    index_path.write_text("\n".join(lines) + "\n")
    print(f"Generated {index_path} with {len(entries)} drivers.")


if __name__ == "__main__":
    main()
