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


def test_sungrow_ftw_baseline_keeps_exact_identity_and_hash() -> None:
    source_map = json.loads(SOURCE_MAP.read_text(encoding="utf-8"))
    entry = source_map["drivers"][0]

    assert source_map["commit"] == "699873db3e7abe81f76e8110d1cefa4a38ba6efb"
    assert entry["source_path"] == "drivers/sungrow.lua"
    assert entry["original_id"] == "sungrow-shx"
    assert entry["original_version"] == "1.1.0"
    assert entry["canonical_id"] == "sungrow"
    assert hashlib.sha256(BASELINE.read_bytes()).hexdigest() == entry["source_sha256"]


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
