"""Tests for the signed FTW driver channel."""

from __future__ import annotations

import base64
import copy
import hashlib
import json
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from ftw_repository import (  # noqa: E402
    RepositoryError,
    build_publication,
    canonical_json,
    verify_artifacts,
    verify_manifest,
    verify_stable_promotion,
)


COMMIT = "a" * 40
KEY_ID = "ftw-test-1"


@pytest.fixture
def keypair() -> tuple[str, str]:
    private_key = Ed25519PrivateKey.generate()
    seed = private_key.private_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PrivateFormat.Raw,
        encryption_algorithm=serialization.NoEncryption(),
    )
    public = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    return base64.b64encode(seed).decode(), base64.b64encode(public).decode()


def build(tmp_path: Path, keypair: tuple[str, str], **changes) -> tuple[dict, Path]:
    private_key, public_key = keypair
    output = tmp_path / "publication"
    options = {
        "repo_root": ROOT,
        "config_path": ROOT / "ftw-channel.json",
        "output_dir": output,
        "base_url": "https://github.com/srcfl/device-drivers/releases/download/drivers-beta",
        "repository": "https://github.com/srcfl/device-drivers",
        "commit": COMMIT,
        "channel": "beta",
        "key_id": KEY_ID,
        "private_key_base64": private_key,
        "expected_public_key_base64": public_key,
        "generated_at": datetime(2026, 7, 21, tzinfo=timezone.utc),
    }
    options.update(changes)
    return build_publication(**options), output


def write_signed_manifest(
    path: Path,
    payload: dict,
    keypair: tuple[str, str],
    *,
    write_payload: bool = False,
) -> None:
    private_key = Ed25519PrivateKey.from_private_bytes(base64.b64decode(keypair[0]))
    envelope = {
        "schema_version": 1,
        "key_id": KEY_ID,
        "payload": payload,
        "signature": base64.b64encode(
            private_key.sign(canonical_json(payload))
        ).decode(),
    }
    path.write_bytes(canonical_json(envelope) + b"\n")
    if write_payload:
        (path.parent / "manifest.payload.json").write_text(
            json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
        )


def promotion_publications(
    tmp_path: Path, keypair: tuple[str, str]
) -> tuple[Path, Path, Path, Path]:
    beta, beta_output = build(tmp_path / "beta", keypair)
    beta_history = copy.deepcopy(beta["drivers"][0])
    beta_history["version"] = "0.0.1"
    beta_history["metadata"]["version"] = "0.0.1"
    beta_history["source_commit"] = "b" * 40
    beta_history["url"] = (
        beta_history["url"].rsplit("/", 1)[0]
        + f"/driver-{beta_history['id']}-v0.0.1-{beta_history['sha256'][:16]}.lua"
    )
    beta["history"] = [beta_history]
    beta_manifest = beta_output / "manifest.json"
    write_signed_manifest(beta_manifest, beta, keypair)

    previous_stable = copy.deepcopy(beta)
    previous_stable.pop("history")
    added_driver = previous_stable["drivers"].pop()
    previous_stable["commit"] = "b" * 40
    previous_stable["generated_at"] = "2026-07-20T00:00:00Z"
    for driver in previous_stable["drivers"]:
        driver["channel"] = "stable"
        driver["source_commit"] = previous_stable["commit"]
        driver["url"] = driver["url"].replace("drivers-beta", "drivers-stable")
    previous_stable_manifest = tmp_path / "previous-stable.json"
    write_signed_manifest(previous_stable_manifest, previous_stable, keypair)

    candidate, candidate_output = build(
        tmp_path / "candidate",
        keypair,
        channel="stable",
        base_url=(
            "https://github.com/srcfl/device-drivers/releases/download/drivers-stable"
        ),
        previous_manifest_path=previous_stable_manifest,
    )
    assert candidate["drivers"][-1]["id"] == added_driver["id"]
    return beta_manifest, beta_output, previous_stable_manifest, candidate_output


def verify_promotion(
    publications: tuple[Path, Path, Path, Path], keypair: tuple[str, str]
) -> dict:
    beta_manifest, beta_output, previous_stable_manifest, candidate_output = (
        publications
    )
    return verify_stable_promotion(
        beta_manifest_path=beta_manifest,
        beta_artifacts_dir=beta_output,
        previous_stable_manifest_path=previous_stable_manifest,
        candidate_manifest_path=candidate_output / "manifest.json",
        candidate_artifacts_dir=candidate_output,
        key_id=KEY_ID,
        public_key_base64=keypair[1],
    )


def test_publication_contains_the_full_read_only_catalog(
    tmp_path: Path, keypair: tuple[str, str]
) -> None:
    manifest, output = build(tmp_path, keypair)
    _, public_key = keypair

    expected_ids = sorted(path.stem for path in (ROOT / "manifests").glob("*.yaml"))
    assert len(expected_ids) == 62
    assert [driver["id"] for driver in manifest["drivers"]] == expected_ids
    assert all(driver["read_only"] for driver in manifest["drivers"])
    assert all(not driver["control_enabled"] for driver in manifest["drivers"])
    assert all(driver["host_api"] == {"min": 1, "max": 1} for driver in manifest["drivers"])
    assert all(driver["metadata"]["source"] == "upstream" for driver in manifest["drivers"])
    assert all(driver["source_commit"] == COMMIT for driver in manifest["drivers"])

    verified = verify_manifest(
        output / "manifest.json", key_id=KEY_ID, public_key_base64=public_key
    )
    assert verified == manifest
    verify_artifacts(verified, output)

    compiler = next(
        (path for name in ("luac5.4", "luac55", "luac") if (path := shutil.which(name))),
        None,
    )
    if compiler:
        for artifact in output.glob("driver-*.lua"):
            subprocess.run([compiler, "-p", artifact], check=True)


def test_esphome_dsmr_artifact_declares_one_ftw_host_api_range(
    tmp_path: Path, keypair: tuple[str, str]
) -> None:
    manifest, output = build(tmp_path, keypair)
    driver = next(driver for driver in manifest["drivers"] if driver["id"] == "esphome-dsmr")
    artifact = output / Path(driver["url"]).name
    source = artifact.read_text(encoding="utf-8")

    assert re.findall(r"(?m)^\s*host_api_min\s*=\s*([0-9]+)", source) == ["1"]
    assert re.findall(r"(?m)^\s*host_api_max\s*=\s*([0-9]+)", source) == ["1"]


def test_publication_is_deterministic(
    tmp_path: Path, keypair: tuple[str, str]
) -> None:
    _, first = build(tmp_path / "first", keypair)
    _, second = build(tmp_path / "second", keypair)
    assert sorted(path.name for path in first.iterdir()) == sorted(
        path.name for path in second.iterdir()
    )
    for path in first.iterdir():
        assert path.read_bytes() == (second / path.name).read_bytes()


def test_signature_and_artifact_tampering_are_rejected(
    tmp_path: Path, keypair: tuple[str, str]
) -> None:
    _, output = build(tmp_path, keypair)
    _, public_key = keypair
    manifest_path = output / "manifest.json"
    envelope = json.loads(manifest_path.read_text())
    envelope["payload"]["drivers"][0]["version"] = "9.9.9"
    manifest_path.write_bytes(canonical_json(envelope) + b"\n")
    with pytest.raises(RepositoryError, match="signature verification failed"):
        verify_manifest(manifest_path, key_id=KEY_ID, public_key_base64=public_key)

    _, output = build(tmp_path / "artifact", keypair)
    manifest = verify_manifest(
        output / "manifest.json", key_id=KEY_ID, public_key_base64=public_key
    )
    artifact = output / Path(manifest["drivers"][0]["url"]).name
    artifact.write_bytes(artifact.read_bytes() + b"tampered")
    with pytest.raises(RepositoryError, match="size mismatch"):
        verify_artifacts(manifest, output)


def test_manifest_requires_exact_canonical_envelope_bytes(
    tmp_path: Path, keypair: tuple[str, str]
) -> None:
    _, output = build(tmp_path, keypair)
    _, public_key = keypair
    manifest_path = output / "manifest.json"
    manifest_path.write_text(json.dumps(json.loads(manifest_path.read_text()), indent=2) + "\n")

    with pytest.raises(RepositoryError, match="exact canonical JSON bytes"):
        verify_manifest(manifest_path, key_id=KEY_ID, public_key_base64=public_key)


@pytest.mark.parametrize(
    ("change", "message"),
    [
        (lambda driver: driver.update(permissions=["http.post"]), "write-capable permission"),
        (lambda driver: driver["metadata"].update(read_only=False), "metadata must stay read-only"),
        (lambda driver: driver.update(channel="edge"), "invalid channel"),
        (
            lambda driver: driver.update(url=driver["url"].replace(driver["sha256"][:16], "0" * 16)),
            "artifact name does not match",
        ),
    ],
)
def test_signed_manifest_rejects_unsafe_runtime_fields(
    tmp_path: Path,
    keypair: tuple[str, str],
    change,
    message: str,
) -> None:
    _, output = build(tmp_path, keypair)
    manifest_path = output / "manifest.json"
    envelope = json.loads(manifest_path.read_text())
    change(envelope["payload"]["drivers"][0])
    private_key = Ed25519PrivateKey.from_private_bytes(base64.b64decode(keypair[0]))
    envelope["signature"] = base64.b64encode(
        private_key.sign(canonical_json(envelope["payload"]))
    ).decode()
    manifest_path.write_bytes(canonical_json(envelope) + b"\n")

    with pytest.raises(RepositoryError, match=message):
        verify_manifest(manifest_path, key_id=KEY_ID, public_key_base64=keypair[1])


def test_previous_signed_versions_are_kept_as_history(
    tmp_path: Path, keypair: tuple[str, str]
) -> None:
    first, first_output = build(tmp_path / "first", keypair)
    _, public_key = keypair
    previous_path = tmp_path / "previous.json"
    previous_path.write_bytes((first_output / "manifest.json").read_bytes())

    envelope = json.loads(previous_path.read_text())
    previous_driver = copy.deepcopy(envelope["payload"]["drivers"][0])
    previous_driver["id"] = "retired"
    previous_driver["path"] = "drivers/retired.lua"
    previous_driver["filename"] = "retired.lua"
    previous_driver["metadata"]["id"] = "retired"
    previous_driver["url"] = (
        previous_driver["url"].rsplit("/", 1)[0]
        + f"/driver-retired-v{previous_driver['version']}-{previous_driver['sha256'][:16]}.lua"
    )
    envelope["payload"]["drivers"].append(previous_driver)

    private_key = Ed25519PrivateKey.from_private_bytes(base64.b64decode(keypair[0]))
    envelope["signature"] = base64.b64encode(
        private_key.sign(canonical_json(envelope["payload"]))
    ).decode()
    previous_path.write_bytes(canonical_json(envelope) + b"\n")

    current, _ = build(
        tmp_path / "current", keypair, previous_manifest_path=previous_path
    )
    assert [driver["id"] for driver in current["history"]] == ["retired"]
    assert verify_manifest(
        tmp_path / "current" / "publication" / "manifest.json",
        key_id=KEY_ID,
        public_key_base64=public_key,
    ) == current


def test_changed_final_artifact_requires_a_higher_driver_version(
    tmp_path: Path, keypair: tuple[str, str]
) -> None:
    repo = tmp_path / "repo"
    (repo / "drivers" / "lua").mkdir(parents=True)
    (repo / "manifests").mkdir()
    source_path = repo / "drivers" / "lua" / "goodwe.lua"
    source_path.write_bytes((ROOT / "drivers" / "lua" / "goodwe.lua").read_bytes())
    (repo / "manifests" / "goodwe.yaml").write_bytes(
        (ROOT / "manifests" / "goodwe.yaml").read_bytes()
    )
    config = {"schema_version": 1, "include_all": True, "release_mode": "read_only"}
    config_path = repo / "ftw-channel.json"
    config_path.write_text(json.dumps(config))
    _, first_output = build(
        tmp_path / "first",
        keypair,
        repo_root=repo,
        config_path=config_path,
    )
    previous_path = tmp_path / "previous.json"
    previous_path.write_bytes((first_output / "manifest.json").read_bytes())
    source_path.write_text(source_path.read_text() + "\n-- source changed\n")

    with pytest.raises(RepositoryError, match="needs a higher version"):
        build(
            tmp_path / "second",
            keypair,
            repo_root=repo,
            config_path=config_path,
            previous_manifest_path=previous_path,
        )


def test_stable_promotion_allows_added_driver_and_beta_only_history(
    tmp_path: Path, keypair: tuple[str, str]
) -> None:
    publications = promotion_publications(tmp_path, keypair)

    report = verify_promotion(publications, keypair)

    beta = verify_manifest(
        publications[0], key_id=KEY_ID, public_key_base64=keypair[1]
    )
    assert report == {
        "commit": COMMIT,
        "driver_count": 62,
        "delta": {
            "added": [beta["drivers"][-1]["id"]],
            "removed": [],
            "changed": [],
        },
    }


def test_stable_promotion_rejects_unexpected_current_driver(
    tmp_path: Path, keypair: tuple[str, str]
) -> None:
    publications = promotion_publications(tmp_path, keypair)
    candidate_output = publications[3]
    candidate_path = candidate_output / "manifest.json"
    candidate = verify_manifest(
        candidate_path, key_id=KEY_ID, public_key_base64=keypair[1]
    )
    removed = candidate["drivers"].pop()
    (candidate_output / Path(removed["url"]).name).unlink()
    write_signed_manifest(candidate_path, candidate, keypair, write_payload=True)

    with pytest.raises(RepositoryError, match="current driver IDs differ"):
        verify_promotion(publications, keypair)


def test_stable_promotion_rejects_host_api_difference(
    tmp_path: Path, keypair: tuple[str, str]
) -> None:
    publications = promotion_publications(tmp_path, keypair)
    candidate_output = publications[3]
    candidate_path = candidate_output / "manifest.json"
    candidate = verify_manifest(
        candidate_path, key_id=KEY_ID, public_key_base64=keypair[1]
    )
    candidate["drivers"][0]["host_api"] = {"min": 0, "max": 1}
    write_signed_manifest(candidate_path, candidate, keypair, write_payload=True)

    with pytest.raises(RepositoryError, match="differs from beta in host_api"):
        verify_promotion(publications, keypair)


def test_stable_promotion_rejects_artifact_difference(
    tmp_path: Path, keypair: tuple[str, str]
) -> None:
    publications = promotion_publications(tmp_path, keypair)
    candidate_output = publications[3]
    candidate_path = candidate_output / "manifest.json"
    candidate = verify_manifest(
        candidate_path, key_id=KEY_ID, public_key_base64=keypair[1]
    )
    driver = candidate["drivers"][0]
    old_artifact = candidate_output / Path(driver["url"]).name
    raw = old_artifact.read_bytes() + b"\n-- unexpected change\n"
    digest = hashlib.sha256(raw).hexdigest()
    new_name = f"driver-{driver['id']}-v{driver['version']}-{digest[:16]}.lua"
    old_artifact.unlink()
    (candidate_output / new_name).write_bytes(raw)
    driver["sha256"] = digest
    driver["size_bytes"] = len(raw)
    driver["url"] = driver["url"].rsplit("/", 1)[0] + f"/{new_name}"
    write_signed_manifest(candidate_path, candidate, keypair, write_payload=True)

    with pytest.raises(RepositoryError, match="differs from beta in .*sha256"):
        verify_promotion(publications, keypair)


def test_stable_promotion_requires_the_exact_signed_beta_commit(
    tmp_path: Path, keypair: tuple[str, str]
) -> None:
    publications = promotion_publications(tmp_path, keypair)
    candidate_output = publications[3]
    candidate_path = candidate_output / "manifest.json"
    candidate = verify_manifest(
        candidate_path, key_id=KEY_ID, public_key_base64=keypair[1]
    )
    candidate["commit"] = "c" * 40
    for driver in candidate["drivers"]:
        driver["source_commit"] = candidate["commit"]
    write_signed_manifest(candidate_path, candidate, keypair, write_payload=True)

    with pytest.raises(RepositoryError, match="does not match signed beta commit"):
        verify_promotion(publications, keypair)


def test_control_sources_become_write_inert_ftw_artifacts(
    tmp_path: Path, keypair: tuple[str, str]
) -> None:
    manifest, output = build(tmp_path, keypair)
    sungrow = next(driver for driver in manifest["drivers"] if driver["id"] == "sungrow")
    artifact = (output / Path(sungrow["url"]).name).read_text()

    assert "host.modbus_write = __sourceful_ftw_write_denied" in artifact
    assert "function driver_command(action, value, context) return false end" in artifact
    assert sungrow["permissions"] == ["modbus.read"]
    assert sungrow["read_only"] is True
    assert sungrow["control_enabled"] is False
