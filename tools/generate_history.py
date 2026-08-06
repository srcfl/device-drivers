#!/usr/bin/env python3
"""Record every driver version this repository has published.

index.yaml names one version per driver: the current one. That is enough to
install a driver and not enough to go back to the one that worked. A site
running an older driver, or an operator rolling one back, needs to know which
exact source bytes a past version had and which commit carried them.

This tool walks the git history of each driver's Lua source and manifest and
writes driver-history.json: for every version, the source SHA-256, the size,
the commit that first carried it and the date.

The file is append-only. A published version describes bytes that are already
running on hardware somewhere, so rewriting an entry would make the record lie
about what a site installed. `--check` enforces that and is wired into
`make check`.

Usage:
    python tools/generate_history.py           # add newly published versions
    python tools/generate_history.py --check   # fail on a mutated entry
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HISTORY_PATH = ROOT / "driver-history.json"
MANIFEST_DIR = ROOT / "manifests"
SCHEMA = "sourceful.driver-history/v1"

# Fields that describe published bytes. If one of these changes for a version
# that is already recorded, the record has been rewritten.
IMMUTABLE_FIELDS = ("sha256", "size_bytes", "commit")


def git(*args: str) -> str:
    result = subprocess.run(("git", *args), cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


def file_at(commit: str, path: str) -> bytes | None:
    """Return a file's bytes at a commit, or None when it did not exist."""
    result = subprocess.run(("git", "show", f"{commit}:{path}"),
                            cwd=ROOT, capture_output=True)
    if result.returncode != 0:
        return None
    return result.stdout


def manifest_version(raw: bytes) -> str | None:
    for line in raw.decode("utf-8", errors="replace").splitlines():
        stripped = line.strip()
        if stripped.startswith("version:"):
            return stripped.split(":", 1)[1].strip().strip('"').strip("'")
    return None


def collect(driver_id: str) -> list[dict]:
    """Every version of one driver, oldest first."""
    lua_path = f"drivers/lua/{driver_id}.lua"
    manifest_path = f"manifests/{driver_id}.yaml"

    log = git("log", "--reverse", "--format=%H %cI", "--", lua_path, manifest_path)

    seen: dict[str, dict] = {}
    for line in log.strip().splitlines():
        if not line.strip():
            continue
        commit, date = line.split(" ", 1)

        manifest_raw = file_at(commit, manifest_path)
        lua_raw = file_at(commit, lua_path)
        if manifest_raw is None or lua_raw is None:
            continue

        version = manifest_version(manifest_raw)
        if version is None or version in seen:
            continue

        seen[version] = {
            "version": version,
            "sha256": hashlib.sha256(lua_raw).hexdigest(),
            "size_bytes": len(lua_raw),
            "commit": commit,
            "date": date.strip(),
            "source_path": lua_path,
        }

    return list(seen.values())


def build() -> dict:
    drivers = {}
    for manifest in sorted(MANIFEST_DIR.glob("*.yaml")):
        versions = collect(manifest.stem)
        if versions:
            drivers[manifest.stem] = versions
    return {"schema_version": SCHEMA, "drivers": drivers}


def load_existing() -> dict:
    if not HISTORY_PATH.exists():
        return {"schema_version": SCHEMA, "drivers": {}}
    return json.loads(HISTORY_PATH.read_text(encoding="utf-8"))


def compare(existing: dict, fresh: dict) -> tuple[list[str], list[str]]:
    """Return (mutations, additions). A mutation is always a bug."""
    mutations, additions = [], []
    old_drivers = existing.get("drivers", {})
    new_drivers = fresh.get("drivers", {})

    for driver_id, new_versions in new_drivers.items():
        old_by_version = {e["version"]: e for e in old_drivers.get(driver_id, [])}
        for entry in new_versions:
            old = old_by_version.get(entry["version"])
            if old is None:
                additions.append(f"{driver_id} {entry['version']}")
                continue
            for field in IMMUTABLE_FIELDS:
                if old.get(field) != entry.get(field):
                    mutations.append(
                        f"{driver_id} {entry['version']}: {field} changed from "
                        f"{old.get(field)!r} to {entry.get(field)!r}")

    for driver_id, old_versions in old_drivers.items():
        new_by_version = {e["version"] for e in new_drivers.get(driver_id, [])}
        for entry in old_versions:
            if entry["version"] not in new_by_version:
                mutations.append(
                    f"{driver_id} {entry['version']}: dropped from the history")

    return mutations, additions


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="fail if a recorded version was rewritten or dropped")
    args = parser.parse_args()

    fresh = build()
    existing = load_existing()
    # A driver removed from the catalog keeps its published record: the
    # history is the channel's memory of bytes that ran on hardware, not
    # a mirror of what the catalog currently offers. Only rewriting a
    # recorded version is a mutation; carrying one forward is the point.
    for driver_id, versions in existing.get("drivers", {}).items():
        if driver_id not in fresh["drivers"]:
            fresh["drivers"][driver_id] = versions
    mutations, additions = compare(existing, fresh)

    if mutations:
        print("published driver versions were rewritten:", file=sys.stderr)
        for message in mutations:
            print(f"  {message}", file=sys.stderr)
        print("\nA published version describes bytes already running on hardware.",
              file=sys.stderr)
        print("Publish a new version instead of changing an old one.", file=sys.stderr)
        return 1

    if args.check:
        total = sum(len(v) for v in fresh["drivers"].values())
        print(f"driver history intact: {total} versions across "
              f"{len(fresh['drivers'])} drivers.")
        if additions:
            # Not a failure. A version becomes recordable only once its commit
            # exists, so a branch that bumps a driver always runs one version
            # ahead of the file until `make history` runs at release.
            print(f"{len(additions)} version(s) still to record at release: "
                  f"{', '.join(additions[:5])}"
                  f"{' and more' if len(additions) > 5 else ''}")
        return 0

    HISTORY_PATH.write_text(json.dumps(fresh, indent=2) + "\n", encoding="utf-8")
    total = sum(len(v) for v in fresh["drivers"].values())
    print(f"wrote {HISTORY_PATH.name}: {total} versions across "
          f"{len(fresh['drivers'])} drivers")
    if additions:
        print(f"added: {', '.join(additions)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
