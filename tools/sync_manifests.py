#!/usr/bin/env python3
"""Write the true source hash and size into every driver manifest.

`sha256` and `size_bytes` describe the Lua file a manifest belongs to. They
were maintained by hand, so they drifted: a driver could change while its
manifest kept claiming the old bytes. Nothing caught it, because
validate_manifest.py only checked that the size was a non-negative number.

This tool derives both fields from the file itself. `make check` runs it and
then fails on any diff, so a stale manifest cannot reach `main`.

Usage:
    python tools/sync_manifests.py            # rewrite every manifest
    python tools/sync_manifests.py --check    # report drift, change nothing
    python tools/sync_manifests.py --id pixii # one driver
"""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST_DIR = ROOT / "manifests"
LUA_DIR = ROOT / "drivers" / "lua"


def source_facts(driver_id: str) -> tuple[str, int] | None:
    """Return (sha256, size_bytes) for a driver's Lua source."""
    lua_path = LUA_DIR / f"{driver_id}.lua"
    if not lua_path.exists():
        return None
    raw = lua_path.read_bytes()
    return hashlib.sha256(raw).hexdigest(), len(raw)


def replace_scalar(text: str, key: str, value: str) -> tuple[str, bool]:
    """Replace a top-level `key: value` line. Returns (text, changed)."""
    pattern = re.compile(rf'^{re.escape(key)}:.*$', re.M)
    if not pattern.search(text):
        return text, False
    new_text, count = pattern.subn(f"{key}: {value}", text, count=1)
    return new_text, count > 0 and new_text != text


def sync_manifest(path: Path, check_only: bool) -> list[str]:
    """Bring one manifest in line with its source. Returns drift messages."""
    driver_id = path.stem
    facts = source_facts(driver_id)
    if facts is None:
        return [f"{driver_id}: manifest has no drivers/lua/{driver_id}.lua"]

    sha256, size_bytes = facts
    text = path.read_text(encoding="utf-8")
    drift = []

    text, sha_changed = replace_scalar(text, "sha256", f'"{sha256}"')
    if sha_changed:
        drift.append(f"{driver_id}: sha256 did not match the source")

    text, size_changed = replace_scalar(text, "size_bytes", str(size_bytes))
    if size_changed:
        drift.append(f"{driver_id}: size_bytes did not match the source")

    if drift and not check_only:
        path.write_text(text, encoding="utf-8")

    return drift


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="report drift without rewriting anything")
    parser.add_argument("--id", help="sync a single driver id")
    args = parser.parse_args()

    if args.id:
        paths = [MANIFEST_DIR / f"{args.id}.yaml"]
        if not paths[0].exists():
            print(f"no manifest for id '{args.id}'", file=sys.stderr)
            return 2
    else:
        paths = sorted(MANIFEST_DIR.glob("*.yaml"))

    all_drift = []
    for path in paths:
        all_drift.extend(sync_manifest(path, args.check))

    if not all_drift:
        print(f"{len(paths)} manifests match their source.")
        return 0

    for message in all_drift:
        print(message)

    if args.check:
        print(f"\n{len(all_drift)} fields drifted. Run: make sync-manifests")
        return 1

    print(f"\nupdated {len(all_drift)} fields across {len(paths)} manifests.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
