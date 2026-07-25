#!/usr/bin/env python3
"""Raise a driver's version in every place that states it.

A driver version lives in two files that must agree: the `version` field in
manifests/<id>.yaml and the `version` field of the `DRIVER` table in
drivers/lua/<id>.lua. Bumping one and forgetting the other ships a driver that
misreports itself to the host, so this tool moves both together and then
refreshes the generated catalog.

Usage:
    python tools/bump_driver.py --id sungrow --level patch
    python tools/bump_driver.py --id sungrow --version 2.0.0

Levels are `major`, `minor` and `patch`. Prefer `patch` for a fix that keeps
the same registers and fields, `minor` for new telemetry, and `major` when a
host or an operator has to do something differently.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST_DIR = ROOT / "manifests"
LUA_DIR = ROOT / "drivers" / "lua"

SEMVER = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")


def next_version(current: str, level: str) -> str:
    match = SEMVER.match(current)
    if not match:
        raise SystemExit(f"current version '{current}' is not major.minor.patch")
    major, minor, patch = (int(part) for part in match.groups())
    if level == "major":
        return f"{major + 1}.0.0"
    if level == "minor":
        return f"{major}.{minor + 1}.0"
    return f"{major}.{minor}.{patch + 1}"


def read_manifest_version(path: Path) -> str:
    match = re.search(r'^version:\s*"([^"]+)"', path.read_text(encoding="utf-8"), re.M)
    if not match:
        raise SystemExit(f"{path.name} has no version field")
    return match.group(1)


def write_manifest_version(path: Path, version: str) -> None:
    text = path.read_text(encoding="utf-8")
    text, count = re.subn(r'^version:\s*"[^"]+"', f'version: "{version}"',
                          text, count=1, flags=re.M)
    if count != 1:
        raise SystemExit(f"could not rewrite the version in {path.name}")
    path.write_text(text, encoding="utf-8")


def write_lua_version(path: Path, version: str) -> bool:
    """Rewrite the version inside the DRIVER table, not anywhere else.

    Most drivers carry no DRIVER table and take their version from the
    manifest alone. That is fine; there is simply nothing to keep in step.
    Returns whether the file was changed.
    """
    text = path.read_text(encoding="utf-8")
    start = text.find("DRIVER")
    if start == -1:
        return False
    end = text.find("\n}", start)
    if end == -1:
        raise SystemExit(f"{path.name} has an unterminated DRIVER table")

    block = text[start:end]
    new_block, count = re.subn(r'(version\s*=\s*)"[^"]+"', rf'\1"{version}"',
                               block, count=1)
    if count != 1:
        return False
    path.write_text(text[:start] + new_block + text[end:], encoding="utf-8")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--id", required=True, help="driver id, e.g. sungrow")
    parser.add_argument("--level", choices=["major", "minor", "patch"],
                        help="how far to move the version")
    parser.add_argument("--version", help="set this exact version instead")
    args = parser.parse_args()

    if bool(args.level) == bool(args.version):
        print("pass exactly one of --level or --version", file=sys.stderr)
        return 2

    manifest_path = MANIFEST_DIR / f"{args.id}.yaml"
    lua_path = LUA_DIR / f"{args.id}.lua"
    for path in (manifest_path, lua_path):
        if not path.exists():
            print(f"missing {path.relative_to(ROOT)}", file=sys.stderr)
            return 2

    current = read_manifest_version(manifest_path)
    if args.version:
        if not SEMVER.match(args.version):
            print(f"'{args.version}' is not major.minor.patch", file=sys.stderr)
            return 2
        target = args.version
    else:
        target = next_version(current, args.level)

    write_manifest_version(manifest_path, target)
    lua_changed = write_lua_version(lua_path, target)

    print(f"{args.id}: {current} -> {target}")
    if lua_changed:
        print("manifest and DRIVER table updated. Now run:")
    else:
        print(f"manifest updated ({args.id} states no version in Lua). Now run:")
    print(f"  make test-driver ID={args.id}")
    print("  make check")
    print(f"Add a CHANGELOG.md entry for {args.id} {target} before opening the PR.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
