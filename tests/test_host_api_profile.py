"""Every driver must call only host functions some host actually provides.

FTW and Blixt L1 spell several functions differently — `modbus_write` against
`write`, `millis` against `now_ms`. Neither spelling is wrong: each is the real
API of a shipping host, and a host that wants the other dialect's drivers adds
aliases, which FTW did in v1.11.4-beta.7. What no host can rescue is a call to
a name that exists nowhere. The catalog once had 35 drivers calling decode
helpers that lived only in the test mock; they passed every test here and would
have failed on hardware.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
PROFILE = json.loads((ROOT / "spec" / "host-api-profile.json").read_text(encoding="utf-8"))

# Calls only. A driver may also assign to host.<name> — esphome_dsmr replaces
# host.serial_write with a deny stub to harden itself — which is the opposite
# of relying on the host to provide it.
HOST_CALL = re.compile(r"\bhost\.(\w+)\s*\(")


def allowed_functions(profile_name: str) -> set[str]:
    groups = PROFILE["profiles"][profile_name]["functions"]
    return {fn for group in groups.values() for fn in group}


LINUX_EDGE = allowed_functions("linux-edge")
# FTW's spelling on the left, Blixt L1's on the right. Both sides are real.
DIALECT = PROFILE["deprecated"]["ftw_to_blixt"]
PENDING = set(PROFILE["pending"]["functions"])

CATALOG = sorted((ROOT / "drivers" / "lua").glob("*.lua"))
TARGETS = sorted((ROOT / "packages" / "v1").glob("*/targets/*.lua"))


def called_functions(path: Path) -> set[str]:
    return set(HOST_CALL.findall(path.read_text(encoding="utf-8", errors="replace")))


@pytest.mark.parametrize("path", CATALOG + TARGETS, ids=lambda p: p.stem)
def test_driver_calls_only_functions_a_host_provides(path: Path) -> None:
    called = called_functions(path)
    unknown = called - LINUX_EDGE - set(DIALECT) - set(DIALECT.values())

    assert not unknown, (
        f"{path.relative_to(ROOT)} calls host functions no host provides: "
        f"{sorted(unknown)}. Add them to spec/host-api-profile.json once a "
        f"host implements them, or fix the call."
        + (f" {sorted(unknown & PENDING)} are listed as pending, so decide "
           f"before shipping a driver that needs them."
           if unknown & PENDING else ""))


@pytest.mark.parametrize("path", CATALOG + TARGETS, ids=lambda p: p.stem)
def test_driver_does_not_mix_both_spellings_of_one_function(path: Path) -> None:
    """One driver, one dialect. Both names of the same function means a mistake."""
    called = called_functions(path)
    for ftw_name, blixt_name in DIALECT.items():
        assert not (ftw_name in called and blixt_name in called), (
            f"{path.relative_to(ROOT)} calls both {ftw_name} and {blixt_name}. "
            f"They are one host function under two names; pick one.")


def test_both_sides_of_the_dialect_map_are_real_names() -> None:
    """A dialect entry that names something no host has would hide a typo."""
    blixt_side = set(DIALECT.values())
    unknown = blixt_side - LINUX_EDGE
    assert not unknown, (
        f"the dialect map points at {sorted(unknown)}, which the profile does "
        "not define. Either add them or fix the map.")
