#!/usr/bin/env python3
"""Import FTW's bundled drivers into baselines/ftw as an exact record.

This repository is meant to be the only source for FTW's drivers. FTW still
bundles its own copies, and they have drifted: of the drivers that exist in
both places, none is byte-identical to its catalog namesake.

Importing a bundled driver straight into drivers/lua would break things, so
this tool does the safe half first. It copies each bundled driver in byte for
byte under baselines/ftw and records its hash, id and version in
source-map.json. Nothing here reaches the catalog, the package recipes or the
signed channel. It gives the repository the source, and gives us a hash to
check drift against.

Importing needs the GitHub API. Verifying does not, so CI can run --check
offline against the recorded hashes.

Usage:
    python tools/import_ftw_baseline.py             # import from FTW master
    python tools/import_ftw_baseline.py --check     # verify recorded hashes
    python tools/import_ftw_baseline.py --report    # compatibility report
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASELINE_DIR = ROOT / "baselines" / "ftw"
DRIVER_DIR = BASELINE_DIR / "drivers"
SOURCE_MAP = BASELINE_DIR / "source-map.json"
CATALOG_LUA = ROOT / "drivers" / "lua"

FTW_REPO = "srcfl/ftw"
FTW_DRIVER_PATH = "drivers"
SCHEMA = "sourceful.ftw-legacy-source-map/v1"

# Zap runs an ESP32-C3 with a 48 KB shared Lua pool. drivers/lua/GUIDELINES.md
# caps one driver at 8 KB of bytecode. FTW runs gopher-lua on far bigger
# hardware, so a bundled driver may be well past that and still be correct
# there. The report flags it rather than calling it a failure.
ZAP_BYTECODE_LIMIT = 8192


def gh_api(path: str) -> dict | list:
    result = subprocess.run(("gh", "api", path), capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"gh api {path} failed: {result.stderr.strip()}")
    return json.loads(result.stdout)


def driver_metadata(source: str) -> tuple[str | None, str | None]:
    """Read id and version out of the DRIVER table."""
    start = source.find("DRIVER")
    if start == -1:
        return None, None
    end = source.find("\n}", start)
    if end == -1:
        return None, None
    block = source[start:end]
    did = re.search(r'id\s*=\s*"([^"]+)"', block)
    version = re.search(r'version\s*=\s*"([^"]+)"', block)
    return (did.group(1) if did else None,
            version.group(1) if version else None)


def canonical_id(ftw_id: str | None, filename: str) -> str | None:
    """Map an FTW driver id onto a catalog driver, when one exists.

    FTW separates words with hyphens and the catalog uses underscores, so try
    the obvious spellings and the file name. Anything that does not land on a
    real manifest stays null: an unproven mapping is worse than none.
    """
    candidates = []
    if ftw_id:
        candidates += [ftw_id, ftw_id.replace("-", "_")]
    candidates += [filename, filename.replace("_", "-")]
    for candidate in candidates:
        if (ROOT / "manifests" / f"{candidate}.yaml").exists():
            return candidate
    return None


def do_import() -> int:
    commit = gh_api(f"repos/{FTW_REPO}/commits/master")["sha"]
    listing = gh_api(f"repos/{FTW_REPO}/contents/{FTW_DRIVER_PATH}")
    names = sorted(item["name"] for item in listing
                   if item["name"].endswith(".lua"))

    DRIVER_DIR.mkdir(parents=True, exist_ok=True)
    entries = []
    for name in names:
        blob = gh_api(f"repos/{FTW_REPO}/contents/{FTW_DRIVER_PATH}/{name}")
        raw = base64.b64decode(blob["content"])
        (DRIVER_DIR / name).write_bytes(raw)

        source = raw.decode("utf-8", errors="replace")
        ftw_id, version = driver_metadata(source)
        stem = name[:-4]
        entries.append({
            "source_path": f"{FTW_DRIVER_PATH}/{name}",
            "baseline_path": f"baselines/ftw/drivers/{name}",
            "source_sha256": hashlib.sha256(raw).hexdigest(),
            "size_bytes": len(raw),
            "original_id": ftw_id,
            "original_version": version,
            "canonical_id": canonical_id(ftw_id, stem),
            "import_status": "byte_exact",
            "package_eligibility": "observe_only_target_required",
            "live_activation": "blocked",
        })

    SOURCE_MAP.write_text(json.dumps({
        "schema_version": SCHEMA,
        "repository": f"https://github.com/{FTW_REPO}",
        "commit": commit,
        "drivers": entries,
    }, indent=2) + "\n", encoding="utf-8")

    mapped = sum(1 for e in entries if e["canonical_id"])
    print(f"imported {len(entries)} FTW drivers at {commit[:8]}")
    print(f"{mapped} map onto a catalog driver, {len(entries) - mapped} do not")
    return 0


def load_map() -> dict:
    if not SOURCE_MAP.exists():
        raise SystemExit("baselines/ftw/source-map.json is missing")
    return json.loads(SOURCE_MAP.read_text(encoding="utf-8"))


def do_check() -> int:
    """Verify each baseline file still matches its recorded hash."""
    data = load_map()
    problems = []
    for entry in data["drivers"]:
        path = ROOT / entry["baseline_path"]
        if not path.exists():
            problems.append(f"{entry['baseline_path']}: missing")
            continue
        raw = path.read_bytes()
        digest = hashlib.sha256(raw).hexdigest()
        if digest != entry["source_sha256"]:
            problems.append(
                f"{entry['baseline_path']}: hash {digest[:12]} does not match "
                f"the recorded {entry['source_sha256'][:12]}")

    if problems:
        print("FTW baseline no longer matches what was imported:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print("\nA baseline is an exact record of FTW's source. Re-import it "
              "rather than editing it by hand.", file=sys.stderr)
        return 1

    print(f"FTW baseline intact: {len(data['drivers'])} drivers at "
          f"{data['commit'][:8]}")
    return 0


def do_report() -> int:
    """What stands between a baseline and a catalog driver."""
    data = load_map()
    luac = ROOT / "luac55"
    have_luac = luac.exists()

    rows, oversize, unmapped = [], [], []
    for entry in data["drivers"]:
        path = ROOT / entry["baseline_path"]
        if not path.exists():
            continue
        bytecode = None
        if have_luac:
            out = ROOT / ".ftw-baseline-check.luac"
            result = subprocess.run((str(luac), "-o", str(out), str(path)),
                                    capture_output=True)
            if result.returncode == 0:
                bytecode = out.stat().st_size
                out.unlink()

        stem = Path(entry["baseline_path"]).stem
        rows.append((stem, entry["original_id"], entry["original_version"],
                     entry["canonical_id"], entry["size_bytes"], bytecode))
        if bytecode and bytecode > ZAP_BYTECODE_LIMIT:
            oversize.append((stem, bytecode))
        if not entry["canonical_id"]:
            unmapped.append(stem)

    print(f"FTW baseline at {data['commit'][:8]}: {len(rows)} drivers\n")
    print(f"{'file':<22} {'ftw id':<24} {'ver':<8} {'catalog':<20} "
          f"{'source':>8} {'bytecode':>9}")
    for stem, fid, ver, canon, size, code in rows:
        print(f"{stem:<22} {fid or '-':<24} {ver or '-':<8} {canon or '—':<20} "
              f"{size:>8} {code if code else '-':>9}")

    print(f"\n{len(oversize)} over the {ZAP_BYTECODE_LIMIT} B Zap bytecode cap "
          f"(fine on FTW, too big for a shared catalog driver):")
    for stem, code in sorted(oversize, key=lambda r: -r[1]):
        print(f"  {stem:<22} {code} B")

    print(f"\n{len(unmapped)} have no catalog driver yet:")
    print("  " + ", ".join(sorted(unmapped)))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--check", action="store_true",
                       help="verify recorded hashes offline")
    group.add_argument("--report", action="store_true",
                       help="show what blocks each baseline from the catalog")
    args = parser.parse_args()

    if args.check:
        return do_check()
    if args.report:
        return do_report()
    return do_import()


if __name__ == "__main__":
    raise SystemExit(main())
