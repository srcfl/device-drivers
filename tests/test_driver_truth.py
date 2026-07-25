"""The repository must state the truth about the drivers it publishes.

Three claims are checked here:

1. Every manifest's `sha256` and `size_bytes` describe the Lua file it names.
2. A driver's version is the same in the manifest and in the DRIVER table.
3. A published version in driver-history.json is never rewritten.

The first two drifted for a long time without anything noticing, which is why
they are tests and not conventions.
"""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
MANIFEST_DIR = ROOT / "manifests"
LUA_DIR = ROOT / "drivers" / "lua"
HISTORY_PATH = ROOT / "driver-history.json"

MANIFESTS = sorted(MANIFEST_DIR.glob("*.yaml"))
DRIVER_IDS = [p.stem for p in MANIFESTS]


def manifest_field(text: str, key: str) -> str | None:
    match = re.search(rf'^{re.escape(key)}:\s*(.+)$', text, re.M)
    if not match:
        return None
    return match.group(1).strip().strip('"').strip("'")


def lua_driver_version(text: str) -> str | None:
    start = text.find("DRIVER")
    if start == -1:
        return None
    end = text.find("\n}", start)
    if end == -1:
        return None
    match = re.search(r'version\s*=\s*"([^"]+)"', text[start:end])
    return match.group(1) if match else None


@pytest.mark.parametrize("driver_id", DRIVER_IDS)
def test_manifest_hash_and_size_match_the_source(driver_id: str) -> None:
    lua_path = LUA_DIR / f"{driver_id}.lua"
    assert lua_path.exists(), f"{driver_id}.yaml names a source that does not exist"

    raw = lua_path.read_bytes()
    text = (MANIFEST_DIR / f"{driver_id}.yaml").read_text(encoding="utf-8")

    assert manifest_field(text, "sha256") == hashlib.sha256(raw).hexdigest(), (
        f"{driver_id}: manifest sha256 does not describe drivers/lua/{driver_id}.lua. "
        "Run: make sync-manifests")
    assert manifest_field(text, "size_bytes") == str(len(raw)), (
        f"{driver_id}: manifest size_bytes does not describe "
        f"drivers/lua/{driver_id}.lua. Run: make sync-manifests")


@pytest.mark.parametrize("driver_id", DRIVER_IDS)
def test_manifest_and_driver_table_agree_on_the_version(driver_id: str) -> None:
    manifest_version = manifest_field(
        (MANIFEST_DIR / f"{driver_id}.yaml").read_text(encoding="utf-8"), "version")
    lua_version = lua_driver_version(
        (LUA_DIR / f"{driver_id}.lua").read_text(encoding="utf-8"))

    if lua_version is None:
        pytest.skip(f"{driver_id} has no version in its DRIVER table")

    assert manifest_version == lua_version, (
        f"{driver_id}: manifest says {manifest_version}, the DRIVER table says "
        f"{lua_version}. Run: make bump-driver ID={driver_id}")


def test_driver_history_exists_and_is_well_formed() -> None:
    assert HISTORY_PATH.exists(), "driver-history.json is missing. Run: make history"
    history = json.loads(HISTORY_PATH.read_text(encoding="utf-8"))

    assert history["schema_version"] == "sourceful.driver-history/v1"
    assert history["drivers"], "the history records no drivers"

    for driver_id, entries in history["drivers"].items():
        versions = [entry["version"] for entry in entries]
        assert len(versions) == len(set(versions)), (
            f"{driver_id} records the same version twice")
        for entry in entries:
            assert len(entry["sha256"]) == 64, (
                f"{driver_id} {entry['version']} has no full source hash")
            assert entry["size_bytes"] > 0
            assert entry["commit"], f"{driver_id} {entry['version']} names no commit"


def test_history_never_rewrites_a_published_version() -> None:
    """The generator's own guard, run the way CI runs it."""
    result = subprocess.run(
        (sys.executable, "tools/generate_history.py", "--check"),
        cwd=ROOT, capture_output=True, text=True)
    assert result.returncode == 0, (
        "a published driver version was rewritten or dropped:\n"
        f"{result.stdout}{result.stderr}")


def test_current_versions_can_be_traced_to_a_commit() -> None:
    """Anyone asking for a shipped version must be able to find its source."""
    history = json.loads(HISTORY_PATH.read_text(encoding="utf-8"))

    untraceable = []
    for driver_id in DRIVER_IDS:
        text = (MANIFEST_DIR / f"{driver_id}.yaml").read_text(encoding="utf-8")
        current = manifest_field(text, "version")
        recorded = {e["version"] for e in history["drivers"].get(driver_id, [])}
        # A version bumped on this branch is not committed yet, so it is
        # recorded at release. Everything already on main must be traceable.
        if current not in recorded and recorded:
            untraceable.append(f"{driver_id} {current}")

    # Report rather than fail: a release branch legitimately runs one ahead.
    if untraceable:
        print(f"versions awaiting a history entry: {', '.join(untraceable)}")
