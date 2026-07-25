"""A driver may only call host functions the linux-edge contract defines.

Nothing checked this before, and the drift shows: seven functions are called by
shipped drivers without appearing in spec/host-api.md, and FTW renamed
modbus_write_multiple to modbus_write_multi in its own copies. A driver that
calls a function its host does not implement fails on hardware, not in CI.

baselines/ftw is exempt. Those files are a byte-exact record of FTW's source,
not drivers this repository ships; what they call is reported by
tools/import_ftw_baseline.py --report instead.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
PROFILE_PATH = ROOT / "spec" / "host-api-profile.json"
HOST_CALL = re.compile(r"host\.([a-z_0-9]+)")

PROFILE = json.loads(PROFILE_PATH.read_text(encoding="utf-8"))


def allowed_functions(profile_name: str) -> set[str]:
    groups = PROFILE["profiles"][profile_name]["functions"]
    return {fn for group in groups.values() for fn in group}


LINUX_EDGE = allowed_functions("linux-edge")
# Spellings the catalog grew on its own. Still accepted so existing drivers
# keep working; tools/canonical_debt.py is what stops them from spreading.
DEPRECATED = PROFILE["deprecated"]["functions"]
PENDING = set(PROFILE["pending"]["functions"])

CATALOG = sorted((ROOT / "drivers" / "lua").glob("*.lua"))
TARGETS = sorted((ROOT / "packages" / "v1").glob("*/targets/*.lua"))


def called_functions(path: Path) -> set[str]:
    return set(HOST_CALL.findall(path.read_text(encoding="utf-8", errors="replace")))


@pytest.mark.parametrize("path", CATALOG + TARGETS, ids=lambda p: p.stem)
def test_driver_stays_inside_the_linux_edge_contract(path: Path) -> None:
    called = called_functions(path)
    unknown = called - LINUX_EDGE - set(DEPRECATED)

    assert not unknown, (
        f"{path.relative_to(ROOT)} calls host functions the linux-edge profile "
        f"does not define: {sorted(unknown)}. Either add them to "
        f"spec/host-api-profile.json and spec/host-api.md, or rewrite the "
        f"driver without them."
        + (f" {sorted(unknown & PENDING)} are listed as pending, so decide "
           f"before shipping a driver that needs them."
           if unknown & PENDING else ""))


@pytest.mark.parametrize("path", CATALOG + TARGETS, ids=lambda p: p.stem)
def test_driver_does_not_mix_both_spellings_of_one_function(path: Path) -> None:
    """Calling both names of the same function means one of them is wrong."""
    called = called_functions(path)
    for old, canonical in DEPRECATED.items():
        assert not (old in called and canonical in called), (
            f"{path.relative_to(ROOT)} calls both {old} and {canonical}. "
            f"They are the same host function under two names; use {canonical}.")


def test_deprecated_spellings_are_not_also_canonical() -> None:
    """A name cannot be both the target and the thing being replaced."""
    overlap = set(DEPRECATED) & LINUX_EDGE
    assert not overlap, (
        f"{sorted(overlap)} appear as both canonical and deprecated.")

    unknown_targets = set(DEPRECATED.values()) - LINUX_EDGE
    assert not unknown_targets, (
        f"deprecated spellings point at {sorted(unknown_targets)}, which the "
        "profile does not define.")


def test_profile_and_spec_agree() -> None:
    """Every function in the profile must be documented in host-api.md."""
    spec_text = (ROOT / "spec" / "host-api.md").read_text(encoding="utf-8")
    documented = set(HOST_CALL.findall(spec_text))
    undocumented = LINUX_EDGE - documented

    assert not undocumented, (
        f"spec/host-api.md does not document {sorted(undocumented)}, but the "
        "linux-edge profile allows them. The prose and the contract must say "
        "the same thing.")


def test_pending_functions_are_not_already_allowed() -> None:
    """A function cannot be both undecided and permitted."""
    overlap = PENDING & LINUX_EDGE
    assert not overlap, (
        f"{sorted(overlap)} appear in both the profile and the pending list. "
        "Decide which one is true.")


def test_every_build_target_maps_to_a_profile() -> None:
    for target, profile_name in PROFILE["targets"].items():
        assert profile_name in PROFILE["profiles"], (
            f"target {target} maps to unknown profile {profile_name}")
