#!/usr/bin/env python3
"""Fail if a driver calls a host function no host provides.

This is the only portability rule that matters. A driver that spells a
function the way FTW does, or the way Blixt L1 does, runs on the host that
speaks that dialect and the other host can add an alias in a few lines --
FTW did so in v1.11.4-beta.7. But a driver that calls a name neither host
implements crashes on both, and no amount of aliasing helps.

The catalog once had 35 drivers calling decode helpers that existed only in
the test mock. They passed every test and would have failed on hardware.
That is the failure this exists to catch.

Usage:
    python tools/host_api_check.py            # report
    python tools/host_api_check.py --check    # exit non-zero on unknown calls
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROFILE = json.loads((ROOT / "spec" / "host-api-profile.json").read_text(encoding="utf-8"))
DRIVER_DIR = ROOT / "drivers" / "lua"

# Calls only. A driver may also *assign* to host.<name> -- esphome_dsmr
# overwrites host.serial_write with a deny stub to harden itself -- and that
# is the opposite of depending on the host providing it.
HOST_CALL = re.compile(r"\bhost\.(\w+)\s*\(")


def known_functions() -> set[str]:
    """Every host function name either dialect accepts."""
    names: set[str] = set()
    for profile in PROFILE["profiles"].values():
        for group in profile["functions"].values():
            names.update(group)
    # Both sides of the dialect map are real names on the host that speaks it.
    dialect = PROFILE["deprecated"]["ftw_to_blixt"]
    names.update(dialect.keys())
    names.update(dialect.values())
    # Declared but not yet built. A driver may name one; it just cannot run
    # until the host catches up, which is a release question, not a typo.
    names.update(PROFILE.get("pending", {}).get("functions", []))
    return names


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="exit non-zero when a driver calls an unknown function")
    args = parser.parse_args()

    allowed = known_functions()
    unknown: dict[str, set[str]] = {}

    for path in sorted(DRIVER_DIR.glob("*.lua")):
        text = path.read_text(encoding="utf-8")
        for line in text.splitlines():
            stripped = line.lstrip()
            if stripped.startswith("--"):
                continue
            for name in HOST_CALL.findall(line):
                if name not in allowed:
                    unknown.setdefault(name, set()).add(path.name)

    driver_count = len(list(DRIVER_DIR.glob("*.lua")))
    if not unknown:
        print(f"host API: {driver_count} drivers call only functions a host provides.")
        return 0

    print(f"host API: {len(unknown)} function(s) no host provides, "
          f"across {driver_count} drivers:\n")
    for name in sorted(unknown):
        drivers = sorted(unknown[name])
        shown = ", ".join(drivers[:4])
        if len(drivers) > 4:
            shown += f" and {len(drivers) - 4} more"
        print(f"  host.{name:<24} {shown}")
    print("\nAdd it to spec/host-api-profile.json once a host implements it, "
          "or fix the call.")
    return 1 if args.check else 0


if __name__ == "__main__":
    raise SystemExit(main())
