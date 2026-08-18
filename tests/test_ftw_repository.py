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
    _ftw_artifact,
    _lua_has_top_level_field,
    _lua_named_table_body,
    _load_channel,
    build_publication,
    canonical_json,
    check_publication,
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
    assert len(expected_ids) == len(list((ROOT / 'manifests').glob('*.yaml')))
    assert [driver["id"] for driver in manifest["drivers"]] == expected_ids
    # read_only and control_enabled are two spellings of one fact and must
    # never disagree: a driver that may control while claiming to be read-only
    # reads as safe to anything checking only one of them.
    assert all(
        driver["read_only"] is not driver["control_enabled"]
        for driver in manifest["drivers"]
    )
    # A driver controls if its code does. Every battery driver here carries a
    # driver_command, and publishing them unable to use it was the whole
    # problem: the same file could drive a battery bundled and not downloaded.
    controlling = {d["id"] for d in manifest["drivers"] if d["control_enabled"]}
    assert {"sungrow", "pixii", "alphaess", "ferroamp"} <= controlling
    # And a driver that declares read_only in its own DRIVER table stays a
    # meter, whatever anything else says.
    assert not ({"sdm630", "zap", "esphome_dsmr"} & controlling)
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
        (lambda driver: driver.update(permissions=["nonsense.write"]), "unknown permission"),
        # A read-only driver handed a write path, and a manifest whose Lua
        # metadata disagrees with it: both would read as safe to something
        # checking only one field.
        (
            lambda driver: driver.update(
                read_only=True, control_enabled=False, permissions=["modbus.write"]
            ),
            "read-only driver has a write-capable permission",
        ),
        # http.post is the one write permission a read-only driver may hold,
        # and only when its metadata declares the sign-in it was granted for.
        # Undeclared, it is refused like any other write path.
        (
            lambda driver: driver.update(
                read_only=True, control_enabled=False,
                permissions=["http.get", "http.post"],
            ),
            "read-only driver has a write-capable permission",
        ),
        (
            lambda driver: driver["metadata"].update(read_only=False),
            "Lua metadata read_only must match the manifest",
        ),
        (
            lambda driver: driver.update(read_only=True, control_enabled=True),
            "contradict each other",
        ),
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
    # Every mutation below starts from a read-only entry (grant a write
    # permission, flip metadata.read_only, …). Pick one explicitly rather
    # than trusting drivers[0]: the catalog sorts by id, and a control
    # driver whose id happens to sort first would make these mutations
    # trip a different, earlier check than the one being tested.
    read_only_driver = next(
        driver for driver in envelope["payload"]["drivers"]
        if driver["read_only"] and driver["permissions"] == ["modbus.read"]
    )
    change(read_only_driver)
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


def single_driver_repo(tmp_path: Path, driver_id: str = "goodwe") -> tuple[Path, Path]:
    """A repository holding one real driver, for rules that need a whole channel."""
    repo = tmp_path / "repo"
    (repo / "drivers" / "lua").mkdir(parents=True)
    (repo / "manifests").mkdir()
    (repo / "drivers" / "lua" / f"{driver_id}.lua").write_bytes(
        (ROOT / "drivers" / "lua" / f"{driver_id}.lua").read_bytes()
    )
    (repo / "manifests" / f"{driver_id}.yaml").write_bytes(
        (ROOT / "manifests" / f"{driver_id}.yaml").read_bytes()
    )
    config_path = repo / "ftw-channel.json"
    config_path.write_text(
        json.dumps(
            {"schema_version": 1, "include_all": True, "release_mode": "per_driver"}
        )
    )
    return repo, config_path


def publish_once(
    tmp_path: Path, keypair: tuple[str, str], repo: Path, config_path: Path
) -> Path:
    """Publish the repository as it stands and keep the signed manifest."""
    _, output = build(
        tmp_path / "first", keypair, repo_root=repo, config_path=config_path
    )
    previous_path = tmp_path / "previous.json"
    previous_path.write_bytes((output / "manifest.json").read_bytes())
    return previous_path


def test_changed_final_artifact_requires_a_higher_driver_version(
    tmp_path: Path, keypair: tuple[str, str]
) -> None:
    repo, config_path = single_driver_repo(tmp_path)
    source_path = repo / "drivers" / "lua" / "goodwe.lua"
    previous_path = publish_once(tmp_path, keypair, repo, config_path)
    source_path.write_text(source_path.read_text() + "\n-- source changed\n")

    with pytest.raises(RepositoryError, match="needs a higher version"):
        build(
            tmp_path / "second",
            keypair,
            repo_root=repo,
            config_path=config_path,
            previous_manifest_path=previous_path,
        )


def check(
    keypair: tuple[str, str], repo: Path, config_path: Path, previous_path: Path
) -> dict:
    return check_publication(
        repo_root=repo,
        config_path=config_path,
        previous_manifest_path=previous_path,
        key_id=KEY_ID,
        expected_public_key_base64=keypair[1],
    )


def test_check_versions_answers_what_the_release_would_answer(
    tmp_path: Path, keypair: tuple[str, str]
) -> None:
    """The pull request check is worth nothing unless it agrees with the release.

    Same tree, same published manifest: whatever `build` decides while signing,
    `check_publication` has to decide without a key. Both read one rule so they
    cannot drift apart, and this is what says so.
    """
    repo, config_path = single_driver_repo(tmp_path)
    source_path = repo / "drivers" / "lua" / "goodwe.lua"
    previous_path = publish_once(tmp_path, keypair, repo, config_path)

    # Unchanged tree: the release publishes it, so the check passes it.
    report = check(keypair, repo, config_path, previous_path)
    assert report["changed"] == []
    assert report["drivers"] == 1
    build(
        tmp_path / "unchanged",
        keypair,
        repo_root=repo,
        config_path=config_path,
        previous_manifest_path=previous_path,
    )

    # Changed bytes under a published version: both refuse.
    source_path.write_text(source_path.read_text() + "\n-- source changed\n")
    with pytest.raises(RepositoryError, match="needs a higher version"):
        check(keypair, repo, config_path, previous_path)
    with pytest.raises(RepositoryError, match="needs a higher version"):
        build(
            tmp_path / "second",
            keypair,
            repo_root=repo,
            config_path=config_path,
            previous_manifest_path=previous_path,
        )


def test_check_versions_catches_a_manifest_only_edit(
    tmp_path: Path, keypair: tuple[str, str]
) -> None:
    """The failure this check exists to stop, in the shape it actually arrived in.

    #53 corrected a manifest's `ders` and left the version alone, reading the
    field as catalog-only. It is not: the signed artifact carries the manifest
    metadata beside the Lua source, so the published bytes moved and the release
    refused them on main. No Lua is touched here either.
    """
    repo, config_path = single_driver_repo(tmp_path)
    manifest_path = repo / "manifests" / "goodwe.yaml"
    lua_path = repo / "drivers" / "lua" / "goodwe.lua"
    lua_before = lua_path.read_bytes()
    previous_path = publish_once(tmp_path, keypair, repo, config_path)

    edited, replaced = re.subn(
        r"^ders: \[.*\]$", "ders: [heatpump]", manifest_path.read_text(), flags=re.M
    )
    assert replaced == 1, "the manifest edit must land"
    manifest_path.write_text(edited)
    assert lua_path.read_bytes() == lua_before, "no Lua source may change"

    with pytest.raises(RepositoryError, match="needs a higher version"):
        check(keypair, repo, config_path, previous_path)


def test_check_versions_accepts_a_changed_driver_that_took_a_version(
    tmp_path: Path, keypair: tuple[str, str]
) -> None:
    repo, config_path = single_driver_repo(tmp_path)
    manifest_path = repo / "manifests" / "goodwe.yaml"
    source_path = repo / "drivers" / "lua" / "goodwe.lua"
    published_version = re.search(
        r'^version:\s*"([^"]+)"', manifest_path.read_text(), re.M
    ).group(1)
    previous_path = publish_once(tmp_path, keypair, repo, config_path)

    source_path.write_text(source_path.read_text() + "\n-- source changed\n")
    major, minor, patch = (int(part) for part in published_version.split("."))
    manifest_path.write_text(
        re.sub(
            r'^version:\s*"[^"]+"',
            f'version: "{major}.{minor}.{patch + 1}"',
            manifest_path.read_text(),
            count=1,
            flags=re.M,
        )
    )

    report = check(keypair, repo, config_path, previous_path)
    assert report["changed"] == ["goodwe"]
    assert report["added"] == []


def test_check_versions_reports_every_colliding_driver(
    tmp_path: Path, keypair: tuple[str, str]
) -> None:
    """The release stops at the first; someone fixing a branch wants the list."""
    repo, config_path = single_driver_repo(tmp_path)
    for driver_id in ("sofar", "solis"):
        (repo / "drivers" / "lua" / f"{driver_id}.lua").write_bytes(
            (ROOT / "drivers" / "lua" / f"{driver_id}.lua").read_bytes()
        )
        (repo / "manifests" / f"{driver_id}.yaml").write_bytes(
            (ROOT / "manifests" / f"{driver_id}.yaml").read_bytes()
        )
    previous_path = publish_once(tmp_path, keypair, repo, config_path)

    for driver_id in ("goodwe", "sofar", "solis"):
        source_path = repo / "drivers" / "lua" / f"{driver_id}.lua"
        source_path.write_text(source_path.read_text() + "\n-- source changed\n")

    with pytest.raises(RepositoryError) as raised:
        check(keypair, repo, config_path, previous_path)
    message = str(raised.value)
    for driver_id in ("goodwe", "sofar", "solis"):
        assert driver_id in message, f"{driver_id} is missing from the report"
    assert "make bump-driver ID=goodwe" in message


def test_check_versions_reports_a_driver_the_channel_has_never_published(
    tmp_path: Path, keypair: tuple[str, str]
) -> None:
    repo, config_path = single_driver_repo(tmp_path)
    previous_path = publish_once(tmp_path, keypair, repo, config_path)
    (repo / "drivers" / "lua" / "sofar.lua").write_bytes(
        (ROOT / "drivers" / "lua" / "sofar.lua").read_bytes()
    )
    (repo / "manifests" / "sofar.yaml").write_bytes(
        (ROOT / "manifests" / "sofar.yaml").read_bytes()
    )

    report = check(keypair, repo, config_path, previous_path)
    assert report["added"] == ["sofar"]
    assert report["changed"] == []


def test_check_versions_rejects_a_manifest_the_signing_key_did_not_sign(
    tmp_path: Path, keypair: tuple[str, str]
) -> None:
    """It reads the channel over the network, so the signature still has to hold."""
    repo, config_path = single_driver_repo(tmp_path)
    previous_path = publish_once(tmp_path, keypair, repo, config_path)
    envelope = json.loads(previous_path.read_text())
    envelope["payload"]["drivers"][0]["sha256"] = "0" * 64
    previous_path.write_bytes(canonical_json(envelope) + b"\n")

    with pytest.raises(RepositoryError):
        check(keypair, repo, config_path, previous_path)


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
        "driver_count": len(list((ROOT / "manifests").glob("*.yaml"))),
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


def test_a_control_driver_keeps_the_control_path_it_was_ported_with(
    tmp_path: Path, keypair: tuple[str, str]
) -> None:
    # The channel copy and the bundled copy are built from one source. Denying
    # writes here made the same driver behave two ways depending on where its
    # file came from: bundled it could drive a battery, downloaded it could not.
    manifest, output = build(tmp_path, keypair)
    sungrow = next(driver for driver in manifest["drivers"] if driver["id"] == "sungrow")
    artifact = (output / Path(sungrow["url"]).name).read_text()

    assert "__sourceful_ftw_write_denied" not in artifact
    assert "function driver_command(" in artifact
    assert "function driver_command(action, value, context) return false end" not in artifact
    assert sungrow["permissions"] == ["modbus.read", "modbus.write"]
    assert sungrow["read_only"] is False
    assert sungrow["control_enabled"] is True
    # The signed identity is reasserted after the source loads, so a driver
    # without declared controls keeps the published artifact bytes unchanged.
    assert artifact.rstrip().endswith("DRIVER = __sourceful_ftw_metadata")
    entry = next(
        entry for entry in _load_channel(ROOT / "ftw-channel.json", ROOT)
        if entry["id"] == "sungrow"
    )
    expected = _ftw_artifact(
        (ROOT / "drivers" / "lua" / "sungrow.lua").read_bytes(),
        entry["metadata"],
        read_only=False,
    ).decode("utf-8")
    assert artifact == expected


def test_nested_or_commented_controls_do_not_change_a_control_artifact(
    tmp_path: Path,
) -> None:
    repo, config_path = single_driver_repo(tmp_path, "sungrow")
    source = repo / "drivers" / "lua" / "sungrow.lua"
    source.write_text(
        source.read_text(encoding="utf-8").replace(
            '  capabilities = { "meter", "pv", "battery", "pv-curtail" },\n',
            '  capabilities = { "meter", "pv", "battery", "pv-curtail" },\n'
            '  -- controls = { { id = "commented_control" } },\n'
            '  --[[ controls = { { id = "block_comment_control" } } ]]\n'
            '  --[=[ controls = { { id = "long_block_comment_control" } } ]=]\n'
            '  connection_defaults = {\n'
            '    controls = { { id = "nested_control" } },\n'
            '  },\n',
        ),
        encoding="utf-8",
    )

    entry = _load_channel(config_path, repo)[0]
    expected = _ftw_artifact(
        source.read_bytes(), entry["metadata"], read_only=False
    )

    assert entry["controls"] is True
    assert entry["raw"] == expected
    assert "__sourceful_ftw_controls" not in entry["raw"].decode("utf-8")


def test_driver_locator_skips_non_module_decoys() -> None:
    source = '''-- DRIVER = { id = "commented" }
--[=[ DRIVER = { id = "long-commented" } ]=]
local example = "DRIVER = { id = 'quoted' }"
local nested = { DRIVER = { id = "nested" } }
DRIVER = {
  id = "real",
  controls = { { id = "set_limit" } },
}
'''

    body = _lua_named_table_body(source, "DRIVER")

    assert body is not None
    assert 'id = "real"' in body
    assert _lua_has_top_level_field(body, "controls")


@pytest.mark.parametrize(
    "comment",
    (
        "-- line comment\n  ",
        "--[[ block comment ]] ",
        "--[=[ long block comment ]=] ",
    ),
)
def test_controls_field_skips_comments_before_assignment(comment: str) -> None:
    body = f'''\
  controls {comment}= {{ {{ id = "set_limit" }} }},
'''

    assert _lua_has_top_level_field(body, "controls")


@pytest.mark.parametrize(
    "driver_assignment_comment",
    (
        "-- line comment\n  ",
        "--[[ block comment ]] ",
        "--[=[ long block comment ]=] ",
    ),
)
def test_driver_locator_skips_comments_around_assignment(
    driver_assignment_comment: str,
) -> None:
    source = f'''DRIVER {driver_assignment_comment}= {{
  id = "real",
  controls = {{ {{ id = "set_limit" }} }},
}}
'''

    body = _lua_named_table_body(source, "DRIVER")

    assert body is not None
    assert 'id = "real"' in body
    assert _lua_has_top_level_field(body, "controls")


@pytest.mark.parametrize(
    "scoped_decoy",
    (
        'local function helper()\n  DRIVER = { id = "function" }\nend\n',
        'do\n  local hidden = true\n  DRIVER = { id = "block" }\nend\n',
        'if false then\n  DRIVER = { id = "if" }\nend\n',
        'repeat\n  DRIVER = { id = "repeat" }\nuntil true\n',
    ),
)
def test_driver_locator_skips_block_scoped_decoys(scoped_decoy: str) -> None:
    source = scoped_decoy + '''DRIVER = {
  id = "real",
  controls = { { id = "set_limit" } },
}
'''

    body = _lua_named_table_body(source, "DRIVER")

    assert body is not None
    assert 'id = "real"' in body
    assert _lua_has_top_level_field(body, "controls")


@pytest.mark.parametrize(
    "controls_assignment_comment",
    (
        "-- line comment\n  ",
        "--[[ block comment ]] ",
        "--[=[ long block comment ]=] ",
    ),
)
@pytest.mark.skipif(not (ROOT / "lua55").exists(), reason="run make check to build ./lua55")
def test_evaluated_controls_survive_source_scope(
    tmp_path: Path,
    controls_assignment_comment: str,
) -> None:
    repo, config_path = single_driver_repo(tmp_path, "sungrow")
    source = repo / "drivers" / "lua" / "sungrow.lua"
    original = source.read_text(encoding="utf-8")
    decoys = '''-- DRIVER = { id = "commented_driver" }
local example = "DRIVER = { id = 'quoted_driver' }"
local function helper()
  DRIVER = { id = "function_driver" }
end
do
  local hidden = true
  DRIVER = { id = "block_driver" }
end

'''
    controls = '''local MINIMUM = -3
local SPAN = 13
local type = false
local declared_controls = {
  {
    id       = "set_test_limit",
    label    = "Test limit",
    evidence = "write_ack",
    input    = { type = "number", min = MINIMUM, max = MINIMUM + SPAN, step = 1, unit = "W" },
  },
}

'''
    source_with_controls = decoys + original.replace(
        "DRIVER = {\n", controls + "DRIVER = {\n"
    )
    source.write_text(
        source_with_controls.replace(
            '  capabilities = { "meter", "pv", "battery", "pv-curtail" },\n',
            '  capabilities = { "meter", "pv", "battery", "pv-curtail" },\n'
            '  -- controls = { { id = "commented_control" } },\n'
            '  connection_defaults = {\n'
            '    controls = { { id = "nested_control" } },\n'
            '  },\n'
            f"  controls {controls_assignment_comment}= declared_controls,\n",
        ),
        encoding="utf-8",
    )

    artifact = _load_channel(config_path, repo)[0]["raw"].decode("utf-8")
    source_marker = "-- Sungrow SH Hybrid Inverter Driver"
    prefix, source_and_suffix = artifact.split(source_marker, 1)
    source_body, suffix = source_and_suffix.rsplit(
        "-- Reassert the signed FTW identity after source load.", 1
    )

    assert "nested_control" not in prefix
    assert "commented_control" not in prefix
    assert "MINIMUM" not in prefix
    assert "nested_control" in source_body
    assert source_body.index("local MINIMUM") < source_body.index("DRIVER = {")
    assert "declared_controls" in source_body
    assert "local type = false" in source_body
    assert "DRIVER.controls = __sourceful_ftw_controls" in suffix
    assert "local __sourceful_ftw_controls" in suffix
    assert suffix.index("local __sourceful_ftw_controls") < suffix.index(
        "DRIVER = __sourceful_ftw_metadata"
    )

    artifact_path = tmp_path / "sungrow.lua"
    artifact_path.write_text(artifact, encoding="utf-8")
    runtime = subprocess.run(
        [
            str(ROOT / "lua55"),
            "-e",
            "\n".join(
                (
                    "host = { log = function() end }",
                    f"dofile({json.dumps(str(artifact_path))})",
                    'assert(DRIVER.controls[1].id == "set_test_limit")',
                    "assert(DRIVER.controls[1].input.min == -3)",
                    "assert(DRIVER.controls[1].input.max == 10)",
                )
            ),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert runtime.returncode == 0, runtime.stderr


def test_declared_controls_do_not_turn_a_reader_into_a_controller(
    tmp_path: Path,
) -> None:
    repo, config_path = single_driver_repo(tmp_path, "sdm630")
    source = repo / "drivers" / "lua" / "sdm630.lua"
    original = source.read_text(encoding="utf-8")
    source.write_text(
        original.replace(
            '    capabilities = { "meter" },\n',
            '    capabilities = { "meter" },\n'
            '    controls = {\n'
            '        { id = "unsafe_claim", evidence = "write_ack" },\n'
            '    },\n',
        ),
        encoding="utf-8",
    )

    entry = _load_channel(config_path, repo)[0]
    artifact = entry["raw"].decode("utf-8")
    signed_identity = artifact.split("-- Eastron SDM630", 1)[0]

    assert entry["controls"] is False
    assert "controls = {" not in signed_identity


def test_a_driver_that_declares_read_only_keeps_its_write_guards(
    tmp_path: Path, keypair: tuple[str, str]
) -> None:
    # A meter saying what it is. That statement outranks anything else, and it
    # still gets the guards so a shared source cannot write through it.
    manifest, output = build(tmp_path, keypair)
    sdm630 = next(driver for driver in manifest["drivers"] if driver["id"] == "sdm630")
    artifact = (output / Path(sdm630["url"]).name).read_text()

    assert "host.modbus_write = __sourceful_ftw_write_denied" in artifact
    assert "function driver_command(action, value, context) return false end" in artifact
    assert sdm630["permissions"] == ["modbus.read"]
    assert sdm630["read_only"] is True
    assert sdm630["control_enabled"] is False


def test_a_read_only_driver_may_still_sign_in(
    tmp_path: Path, keypair: tuple[str, str]
) -> None:
    """Reading after authenticating is still reading.

    myuplink cannot actuate anything -- driver_command refuses every command it
    is handed -- but it reads nothing until it has exchanged a refresh token,
    and it exchanges it with a POST. Denying that POST would have cost a
    read-only driver every reading it takes, so read-only would have been
    unusable for the drivers that most obviously deserve it.
    """
    manifest, output = build(tmp_path, keypair)
    myuplink = next(d for d in manifest["drivers"] if d["id"] == "myuplink")
    artifact = (output / Path(myuplink["url"]).name).read_text()

    assert myuplink["read_only"] is True
    assert myuplink["control_enabled"] is False
    assert myuplink["metadata"]["auth_post_path"] == "/oauth/token"
    assert "http.post" in myuplink["permissions"]

    # The exemption is scoped, not a hole: POST reaches the real host function
    # only for a URL ending in the declared path.
    assert 'local __sourceful_ftw_auth_path = "/oauth/token"' in artifact
    assert "path:sub(-#__sourceful_ftw_auth_path) == __sourceful_ftw_auth_path" in artifact
    assert "POST is allowed only for authentication" in artifact
    # Everything else a read-only driver must not do is still refused.
    for denied in ("modbus_write", "modbus_write_multi", "mqtt_publish", "serial_write"):
        assert f"host.{denied} = __sourceful_ftw_write_denied" in artifact


def test_signing_in_is_declared_or_it_does_not_happen(
    tmp_path: Path, keypair: tuple[str, str]
) -> None:
    """A read-only driver that declares nothing keeps the blanket denial."""
    manifest, output = build(tmp_path, keypair)
    exempt = []
    for driver in manifest["drivers"]:
        if not driver["read_only"]:
            continue
        artifact = (output / Path(driver["url"]).name).read_text()
        if "host.http_post = __sourceful_ftw_write_denied" not in artifact:
            exempt.append(driver["id"])
        else:
            assert "auth_post_path" not in driver["metadata"], driver["id"]
            assert "http.post" not in driver["permissions"], driver["id"]
    assert exempt == ["myuplink"], f"unexpected drivers allowed to POST: {exempt}"


def test_auth_post_path_must_be_a_path_and_must_mean_something(
    tmp_path: Path
) -> None:
    """Two ways to declare it wrongly, both refused while building."""
    repo, config_path = single_driver_repo(tmp_path, "myuplink")
    source = repo / "drivers" / "lua" / "myuplink.lua"
    original = source.read_text(encoding="utf-8")

    # A whole URL rather than a path: the guard matches on the path, so a URL
    # here would silently never match and the driver could not sign in.
    source.write_text(
        original.replace('auth_post_path = "/oauth/token"',
                         'auth_post_path = "https://api.myuplink.com/oauth/token"'),
        encoding="utf-8")
    with pytest.raises(RepositoryError, match="must be a path beginning with"):
        _load_channel(config_path, repo)

    # Declared on a driver that is not read-only, where it exempts nothing.
    source.write_text(
        original.replace("  read_only    = true,\n", ""), encoding="utf-8")
    with pytest.raises(RepositoryError, match="only means anything with read_only"):
        _load_channel(config_path, repo)

    source.write_text(original, encoding="utf-8")
