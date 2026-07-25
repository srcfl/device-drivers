#!/usr/bin/env python3
"""Count how far the catalog still is from the canonical driver shape.

Blixt L1 is the naming reference. This catalog grew its own spellings for the
same host functions — `modbus_write` for `write`, `decode_u32` for
`decode_u32_be` — and its own lowercase emit keys where Blixt uses the
`@srcful/data-models` names. Blixt drops a key whose case is wrong without
saying anything, so a driver written one way does not simply run the other way.

Converting 62 drivers at once would be a bad trade. Instead this counts the
debt and records it in canonical-debt.json. `make check` fails if the count
grows, so a new driver cannot add to it and a converted driver ratchets it
down.

Usage:
    python tools/canonical_debt.py            # report the current debt
    python tools/canonical_debt.py --check    # fail if the debt grew
    python tools/canonical_debt.py --record   # accept the current debt
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROFILE = json.loads((ROOT / "spec" / "host-api-profile.json").read_text(encoding="utf-8"))
LEDGER = ROOT / "canonical-debt.json"

DEPRECATED_FUNCTIONS = PROFILE["deprecated"]["functions"]

# Lowercase emit keys the catalog uses where Blixt expects the data-models name.
# Matched as `key =` inside an emit table, which is how every driver writes them.
DEPRECATED_EMIT_KEYS = {
    "w": "W",
    "v": "V",
    "a": "A",
    "hz": "Hz",
    "soc": "SoC_nom_fract",
    "temp_c": "temperature_C",
    "import_wh": "total_import_Wh",
    "export_wh": "total_export_Wh",
    "charge_wh": "total_charge_Wh",
    "discharge_wh": "total_discharge_Wh",
    "lifetime_wh": "total_generation_Wh",
    "rated_w": "rated_W",
}


def driver_files() -> list[Path]:
    return (sorted((ROOT / "drivers" / "lua").glob("*.lua"))
            + sorted((ROOT / "packages" / "v1").glob("*/targets/*.lua")))


def measure() -> dict:
    per_driver: dict[str, dict] = {}
    for path in driver_files():
        text = path.read_text(encoding="utf-8", errors="replace")
        functions = sorted({name for name in DEPRECATED_FUNCTIONS
                            if re.search(rf"host\.{name}\b", text)})
        keys = sorted({key for key in DEPRECATED_EMIT_KEYS
                       if re.search(rf"(?<![\w.]){key}\s*=", text)})
        if functions or keys:
            per_driver[str(path.relative_to(ROOT))] = {
                "functions": functions,
                "emit_keys": keys,
            }

    total = sum(len(v["functions"]) + len(v["emit_keys"]) for v in per_driver.values())
    return {
        "schema_version": "sourceful.canonical-debt/v1",
        "note": "Lower is better. Never raise a number here by hand; convert a "
                "driver and re-record.",
        "total": total,
        "drivers_affected": len(per_driver),
        "per_driver": per_driver,
    }


def report(current: dict) -> None:
    print(f"canonical debt: {current['total']} across "
          f"{current['drivers_affected']} drivers\n")

    fn_counts: dict[str, int] = {}
    key_counts: dict[str, int] = {}
    for entry in current["per_driver"].values():
        for name in entry["functions"]:
            fn_counts[name] = fn_counts.get(name, 0) + 1
        for key in entry["emit_keys"]:
            key_counts[key] = key_counts.get(key, 0) + 1

    if fn_counts:
        print("host functions to rename:")
        for name, count in sorted(fn_counts.items(), key=lambda kv: -kv[1]):
            print(f"  {name:<24} -> {DEPRECATED_FUNCTIONS[name]:<20} {count} drivers")
    if key_counts:
        print("\nemit keys to rename:")
        for key, count in sorted(key_counts.items(), key=lambda kv: -kv[1]):
            print(f"  {key:<24} -> {DEPRECATED_EMIT_KEYS[key]:<20} {count} drivers")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--check", action="store_true", help="fail if the debt grew")
    group.add_argument("--record", action="store_true", help="accept the current debt")
    args = parser.parse_args()

    current = measure()

    if args.record:
        LEDGER.write_text(json.dumps(current, indent=2) + "\n", encoding="utf-8")
        print(f"recorded canonical debt: {current['total']}")
        return 0

    if args.check:
        if not LEDGER.exists():
            print("canonical-debt.json is missing. Run: make canonical-debt-record",
                  file=sys.stderr)
            return 1
        recorded = json.loads(LEDGER.read_text(encoding="utf-8"))
        if current["total"] > recorded["total"]:
            print(f"canonical debt grew from {recorded['total']} to "
                  f"{current['total']}.", file=sys.stderr)
            print("A driver added a deprecated spelling. Use the canonical name "
                  "in spec/host-api-profile.json.", file=sys.stderr)
            new = set(current["per_driver"]) - set(recorded["per_driver"])
            if new:
                print(f"newly affected: {', '.join(sorted(new))}", file=sys.stderr)
            return 1
        if current["total"] < recorded["total"]:
            print(f"canonical debt fell from {recorded['total']} to "
                  f"{current['total']}. Run: make canonical-debt-record")
            return 1
        print(f"canonical debt unchanged at {current['total']}")
        return 0

    report(current)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
