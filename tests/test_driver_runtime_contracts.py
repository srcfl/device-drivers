from __future__ import annotations

from copy import deepcopy

import pytest

from tools.driver_package import PackageError, validate_document


def inventory() -> dict:
    return {
        "schema_version": "sourceful.driver-inventory/v1",
        "generated_at": "2026-07-20T10:00:00Z",
        "host": {
            "product": "ftw",
            "version": "1.5.0-beta.1",
            "update_channel": "beta",
            "target": "ftw-core",
            "runtime_abi": "gopher-lua-source-v1",
            "host_api": 1,
        },
        "drivers": [
            {
                "driver_id": "sdm630",
                "version": "1.1.1",
                "source": "managed",
                "package_id": "com.sourceful.driver.sdm630",
                "repository_id": "sourceful",
                "package_channel": "beta",
                "artifact_sha256": "a" * 64,
                "control_class": "read_only",
                "configured_instances": 2,
                "running_instances": 2,
                "health": {"ok": 1, "degraded": 0, "offline": 1, "unknown": 0},
            }
        ],
    }


def test_inventory_contract_accepts_bounded_aggregate() -> None:
    assert validate_document(inventory())["drivers"][0]["driver_id"] == "sdm630"


def test_inventory_contract_rejects_host_target_mismatch() -> None:
    mismatch = deepcopy(inventory())
    mismatch["host"]["target"] = "blixt-l1"
    with pytest.raises(PackageError):
        validate_document(mismatch)


def test_inventory_contract_rejects_false_counts_and_package_claims() -> None:
    bad_counts = deepcopy(inventory())
    bad_counts["drivers"][0]["health"]["ok"] = 2
    with pytest.raises(PackageError, match="counts"):
        validate_document(bad_counts)

    false_claim = deepcopy(inventory())
    false_claim["drivers"][0]["source"] = "bundled"
    with pytest.raises(PackageError):
        validate_document(false_claim)


def test_inventory_contract_requires_source_hash_for_bundled_drivers() -> None:
    bundled = deepcopy(inventory())
    driver = bundled["drivers"][0]
    driver["source"] = "bundled"
    for field in ("package_id", "repository_id", "package_channel", "artifact_sha256"):
        del driver[field]

    with pytest.raises(PackageError):
        validate_document(bundled)

    driver["source_sha256"] = "b" * 64
    assert validate_document(bundled) == bundled


def test_inventory_contract_marks_legacy_repository_without_package_claim() -> None:
    legacy = deepcopy(inventory())
    driver = legacy["drivers"][0]
    driver["source"] = "legacy_repository"
    del driver["package_id"]
    del driver["package_channel"]

    assert validate_document(legacy) == legacy


def test_command_and_result_contracts() -> None:
    command = {
        "schema_version": "sourceful.driver-command/v1",
        "id": "cmd-01K0ABCDEF0123456789",
        "command": "battery.set_power",
        "source": "ftw.core",
        "issued_at": "2026-07-20T10:00:00Z",
        "expires_at": "2026-07-20T10:00:30Z",
        "attempt": 1,
        "lease": {
            "id": "lease-01K0ABCDEF01234567",
            "expires_at": "2026-07-20T10:00:30Z",
            "heartbeat_interval_ms": 10000,
        },
        "inputs": {"power_w": -2500},
    }
    result = {
        "schema_version": "sourceful.driver-command-result/v1",
        "id": command["id"],
        "command": command["command"],
        "lease_id": command["lease"]["id"],
        "status": "applied",
        "code": "ok",
        "completed_at": "2026-07-20T10:00:01Z",
        "device_state": "controlled",
        "writes": 2,
        "evidence": ["write_ack", "readback"],
        "applied": {"power_w": -2500},
        "driver": {
            "package_id": "com.sourceful.driver.sungrow",
            "version": "1.3.0-beta.1",
            "artifact_sha256": "b" * 64,
        },
    }
    assert validate_document(command) == command
    assert validate_document(result) == result


def test_command_contract_rejects_secret_fields() -> None:
    command = {
        "schema_version": "sourceful.driver-command/v1",
        "id": "cmd-01K0ABCDEF0123456789",
        "command": "battery.set_power",
        "source": "ftw.core",
        "issued_at": "2026-07-20T10:00:00Z",
        "expires_at": "2026-07-20T10:00:30Z",
        "attempt": 1,
        "lease": {
            "id": "lease-01K0ABCDEF01234567",
            "expires_at": "2026-07-20T10:00:30Z",
            "heartbeat_interval_ms": 10000,
        },
        "inputs": {"api_key": "no"},
    }
    with pytest.raises(PackageError):
        validate_document(command)
