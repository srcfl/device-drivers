"""Byte-exact FTW legacy imports and observe-only derivation checks."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_MAP = ROOT / "baselines" / "ftw" / "source-map.json"
BASELINE = ROOT / "baselines" / "ftw" / "drivers" / "sungrow.lua"
OBSERVE = ROOT / "packages" / "v1" / "sungrow" / "targets" / "ftw-observe.lua"


def extract(source: str, start: str, end: str) -> str:
    start_at = source.index(start)
    end_at = source.index(end, start_at)
    return source[start_at:end_at].rstrip()


# packages/v1/sungrow/targets/ftw-observe.lua is generated from this exact
# file, and tools/derive_sungrow_ftw_observe.py refuses to run against any
# other bytes. That hash is the contract, not FTW's commit sha: the sha moves
# whenever any other bundled driver changes, while these bytes must not.
SUNGROW_BASELINE_SHA256 = (
    "466a5f8637e6756fc2e1af4197d4edc1845474231413c0016f0e5900acb7b7ac")


def sungrow_entry(source_map: dict) -> dict:
    for entry in source_map["drivers"]:
        if entry["source_path"] == "drivers/sungrow.lua":
            return entry
    raise AssertionError("the FTW source map no longer records sungrow.lua")


def test_sungrow_ftw_baseline_keeps_exact_identity_and_hash() -> None:
    source_map = json.loads(SOURCE_MAP.read_text(encoding="utf-8"))
    entry = sungrow_entry(source_map)

    assert entry["original_id"] == "sungrow-shx"
    assert entry["original_version"] == "1.1.0"
    assert entry["canonical_id"] == "sungrow"
    assert entry["source_sha256"] == SUNGROW_BASELINE_SHA256
    assert hashlib.sha256(BASELINE.read_bytes()).hexdigest() == SUNGROW_BASELINE_SHA256


def test_every_ftw_baseline_matches_its_recorded_hash() -> None:
    """A baseline is a record of FTW's bytes, so it must never be hand-edited."""
    source_map = json.loads(SOURCE_MAP.read_text(encoding="utf-8"))
    assert source_map["drivers"], "the FTW source map records no drivers"

    for entry in source_map["drivers"]:
        path = ROOT / entry["baseline_path"]
        assert path.exists(), f"{entry['baseline_path']} is missing"
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        assert digest == entry["source_sha256"], (
            f"{entry['baseline_path']} was edited after import. Re-import it "
            "with tools/import_ftw_baseline.py instead of editing it.")
        assert entry["import_status"] == "byte_exact"
        # A baseline is a record, never something the channel can activate.
        assert entry["live_activation"] == "blocked"


def test_sungrow_observe_target_keeps_ftw_fingerprint_and_poll() -> None:
    baseline = BASELINE.read_text(encoding="utf-8")
    observe = OBSERVE.read_text(encoding="utf-8")

    baseline_fingerprint = extract(
        baseline,
        "function driver_fingerprint()",
        "\n----------------------------------------------------------------------------\n-- Initialization",
    )
    observe_fingerprint = extract(
        observe,
        "function driver_fingerprint()",
        "\n\nfunction driver_init",
    )
    baseline_poll = extract(
        baseline,
        "function driver_poll()",
        "\n----------------------------------------------------------------------------\n-- Battery control",
    )
    observe_poll = extract(
        observe,
        "function driver_poll()",
        "\n\nfunction driver_command",
    )

    assert observe_fingerprint == baseline_fingerprint
    assert observe_poll == baseline_poll


def test_sungrow_observe_target_has_no_write_path() -> None:
    observe = OBSERVE.read_text(encoding="utf-8")

    assert "host.modbus_write" not in observe
    assert "host.modbus_write_multi" not in observe
    assert "function driver_command_v2(" not in observe
    assert "function driver_default_mode_v2(" not in observe
    assert "local APPROVED_MODEL_FIRMWARE_PROFILES = {}" in observe
