"""Contract tests for sourceful.driver-package/v1."""

from __future__ import annotations

import copy
import json
import sys
from pathlib import Path

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from driver_package import (  # noqa: E402
    PackageError,
    _compare_semver,
    _validate_lua_source_for_target,
    build_index,
    build_package,
    canonical_json,
    compatible_target,
    promote_payload,
    sign_index_payload,
    sign_payload,
    validate_document,
    verify_envelope,
    verify_index_envelope,
)


PILOTS = {
    "sdm630": ROOT / "packages" / "v1" / "sdm630" / "package-source.json",
    "sungrow": ROOT / "packages" / "v1" / "sungrow" / "package-source.json",
}
CONTROLLABLE = ROOT / "packages" / "v1" / "pixii" / "package-source.json"
SOURCE_COMMIT = "a" * 40
SOURCE_DATE_EPOCH = 1_700_000_000
BASE_URL = "https://github.com/srcfl/device-drivers/releases/download/test"


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


@pytest.fixture
def fake_luac55(tmp_path: Path) -> Path:
    compiler = tmp_path / "luac55"
    compiler.write_text(
        "#!/usr/bin/env python3\n"
        "import pathlib, sys\n"
        "output = pathlib.Path(sys.argv[sys.argv.index('-o') + 1])\n"
        "source = pathlib.Path(sys.argv[-1])\n"
        "output.write_bytes(b'\\x1bLua\\x55' + source.read_bytes())\n",
        encoding="utf-8",
    )
    compiler.chmod(0o755)
    return compiler


@pytest.fixture
def keypair(tmp_path: Path) -> tuple[Path, Path]:
    private_key = Ed25519PrivateKey.generate()
    private_path = tmp_path / "private.pem"
    public_path = tmp_path / "public.pem"
    private_path.write_bytes(
        private_key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        )
    )
    public_path.write_bytes(
        private_key.public_key().public_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PublicFormat.SubjectPublicKeyInfo,
        )
    )
    return private_path, public_path


def build_pilot(name: str, output: Path, compiler: Path) -> dict:
    return build_package(
        PILOTS[name],
        ROOT,
        output,
        BASE_URL,
        SOURCE_COMMIT,
        SOURCE_DATE_EPOCH,
        compiler,
    )


@pytest.mark.parametrize("name", sorted(PILOTS))
def test_pilot_source_is_valid(name: str) -> None:
    validated = validate_document(load_json(PILOTS[name]))
    assert validated["schema_version"] == "sourceful.driver-package-source/v1"


def test_pilot_safety_metadata_is_explicit() -> None:
    sdm630 = load_json(PILOTS["sdm630"])
    sdm_targets = {item["target"] for item in sdm630["compatibility"]}
    assert sdm630["read_only"] is True
    assert sdm630["commands"] == []
    assert sdm_targets == {"ftw-core", "blixt-l1"}
    assert all(not target["control_enabled"] for target in sdm630["compatibility"])

    sungrow = load_json(PILOTS["sungrow"])
    targets = {item["target"]: item for item in sungrow["compatibility"]}
    assert sungrow["read_only"] is True
    assert sungrow["version"] == "1.3.2"
    assert sungrow["commands"] == []
    assert sungrow["capabilities"]["control"] == []
    assert sungrow["permissions"] == ["modbus.read"]
    assert sungrow["default_mode"]["strategy"] == "not_applicable"
    assert set(targets) == {"ftw-core"}
    assert targets["ftw-core"]["control_enabled"] is False
    assert sungrow["lease_policy"]["expiry_action"] == "not_applicable"
    assert [item["model_family"] for item in sungrow["device_matches"]] == [
        "SH-RT (Three-Phase Hybrid)"
    ]


def test_packaging_is_byte_for_byte_deterministic(
    tmp_path: Path, fake_luac55: Path
) -> None:
    first = tmp_path / "first"
    second = tmp_path / "second"
    first_payload = build_pilot("sdm630", first, fake_luac55)
    second_payload = build_pilot("sdm630", second, fake_luac55)

    assert first_payload == second_payload
    assert (first / "manifest.json").read_bytes() == (second / "manifest.json").read_bytes()
    assert sorted(path.name for path in first.iterdir()) == sorted(
        path.name for path in second.iterdir()
    )
    for path in first.iterdir():
        assert path.read_bytes() == (second / path.name).read_bytes()


def test_sungrow_package_uses_the_observe_only_ftw_target(
    tmp_path: Path, fake_luac55: Path
) -> None:
    source = load_json(PILOTS["sungrow"])
    assert source["source"]["path"] == "packages/v1/sungrow/targets/ftw-observe.lua"
    assert source["artifact_inputs"][0]["input_path"] == source["source"]["path"]

    payload = build_pilot("sungrow", tmp_path / "package", fake_luac55)
    artifact = tmp_path / "package" / payload["artifacts"][0]["filename"]
    lua = artifact.read_text(encoding="utf-8")
    assert "host.modbus_write" not in lua
    assert "host.modbus_write_multi" not in lua
    assert "function driver_command_v2(" not in lua
    assert "function driver_default_mode_v2(" not in lua
    assert "function driver_command(" in lua
    assert "function driver_default_mode(" in lua
    assert payload["read_only"] is True
    assert payload["permissions"] == ["modbus.read"]
    assert payload["compatibility"][0]["control_enabled"] is False


def test_signed_envelope_and_artifacts_verify(
    tmp_path: Path, fake_luac55: Path, keypair: tuple[Path, Path]
) -> None:
    private_key, public_key = keypair
    output = tmp_path / "package"
    payload = build_pilot("sdm630", output, fake_luac55)
    envelope = sign_payload(payload, private_key, "sourceful-driver-test-1")

    assert verify_envelope(envelope, public_key, output) == payload

    tampered_envelope = copy.deepcopy(envelope)
    tampered_envelope["payload"]["display_name"] = "Tampered"
    with pytest.raises(PackageError, match="signature verification failed"):
        verify_envelope(tampered_envelope, public_key, output)

    artifact = output / payload["artifacts"][0]["filename"]
    artifact.write_bytes(artifact.read_bytes() + b"tampered")
    with pytest.raises(PackageError, match="artifact size mismatch"):
        verify_envelope(envelope, public_key, output)


def test_signed_driver_index_binds_verified_package_envelopes(
    tmp_path: Path, fake_luac55: Path, keypair: tuple[Path, Path]
) -> None:
    private_key, public_key = keypair
    output = tmp_path / "package"
    payload = build_pilot("sdm630", output, fake_luac55)
    package_envelope = sign_payload(payload, private_key, "sourceful-driver-test-1")
    package_envelope_path = output / "manifest.envelope.json"
    package_envelope_path.write_bytes(canonical_json(package_envelope) + b"\n")

    index = build_index(
        [package_envelope_path],
        ["https://packages.example/sdm630/1.1.1/manifest.envelope.json"],
        "beta",
        SOURCE_DATE_EPOCH,
        public_key,
    )
    assert index["packages"][0]["targets"] == ["blixt-l1", "ftw-core"]
    index_envelope = sign_index_payload(index, private_key, "sourceful-driver-test-1")
    assert verify_index_envelope(index_envelope, public_key) == index

    tampered = copy.deepcopy(index_envelope)
    tampered["payload"]["packages"][0]["version"] = "9.9.9"
    with pytest.raises(PackageError, match="signature verification failed"):
        verify_index_envelope(tampered, public_key)


def test_promotion_keeps_reviewed_bytes_and_provenance(
    tmp_path: Path, fake_luac55: Path, keypair: tuple[Path, Path]
) -> None:
    private_key, public_key = keypair
    beta = build_pilot("sdm630", tmp_path / "package", fake_luac55)
    stable = promote_payload(beta)

    assert stable["channel"] == "stable"
    assert stable["artifacts"] == beta["artifacts"]
    assert stable["source"] == beta["source"]
    assert stable["provenance"] == beta["provenance"]
    assert verify_envelope(
        sign_payload(stable, private_key, "sourceful-driver-test-1"), public_key
    ) == stable


def test_promotion_is_only_beta_to_stable(
    tmp_path: Path, fake_luac55: Path
) -> None:
    beta = build_pilot("sdm630", tmp_path / "package", fake_luac55)
    with pytest.raises(PackageError, match="only allows beta-to-stable"):
        promote_payload(beta, source_channel="beta", target_channel="beta")

    stable = promote_payload(beta)
    with pytest.raises(PackageError, match="requires a beta package"):
        promote_payload(stable)


def test_compatibility_requires_a_fully_known_host(
    tmp_path: Path, fake_luac55: Path
) -> None:
    payload = build_pilot("sdm630", tmp_path / "package", fake_luac55)
    known_host = {
        "target": "ftw-core",
        "host_product": "ftw",
        "host_version": "1.4.0",
        "runtime_name": "gopher-lua",
        "runtime_semantics": "lua-5.1",
        "runtime_version": "1.1.2",
        "runtime_abi": "gopher-lua-source-v1",
        "host_api_profile": "sourceful.host/ftw-core/v1",
        "host_api": 1,
    }
    assert compatible_target(payload, **known_host) is not None

    for field in known_host:
        unknown = dict(known_host)
        unknown[field] = None
        assert compatible_target(payload, **unknown) is None
    assert compatible_target(payload, **{**known_host, "target": "future-host"}) is None
    assert compatible_target(payload, **{**known_host, "host_version": "1.3.9"}) is None
    assert compatible_target(payload, **{**known_host, "host_version": "2.0.0"}) is None
    assert compatible_target(payload, **{**known_host, "runtime_abi": "unknown"}) is None


def test_sdm630_binds_distinct_hosts_to_the_same_reviewed_source(
    tmp_path: Path, fake_luac55: Path
) -> None:
    payload = build_pilot("sdm630", tmp_path / "package", fake_luac55)
    artifacts = {item["target"]: item for item in payload["artifacts"]}
    assert set(artifacts) == {"ftw-core", "blixt-l1"}
    assert artifacts["ftw-core"]["sha256"] == artifacts["blixt-l1"]["sha256"]

    blixt = compatible_target(
        payload,
        target="blixt-l1",
        host_product="blixt-gateway",
        host_version="0.1.0",
        runtime_name="luajit",
        runtime_semantics="lua-5.1",
        runtime_version="2.1",
        runtime_abi="mlua-0.10-luajit21-source-v1",
        host_api_profile="sourceful.host/blixt-l1/v1",
        host_api=1,
    )
    assert blixt is not None
    assert blixt["control_enabled"] is False


def test_target_source_contracts_fail_closed() -> None:
    lifecycle = b"""
function driver_init(config) end
function driver_poll() end
function driver_command(action, value, context) end
function driver_default_mode() end
function driver_cleanup() end
"""
    with pytest.raises(PackageError, match="DRIVER_MANIFEST"):
        _validate_lua_source_for_target(
            lifecycle,
            target="blixt-l1",
            read_only=True,
            package_version="1.0.0",
        )
    with pytest.raises(PackageError, match="must declare DRIVER"):
        _validate_lua_source_for_target(
            lifecycle,
            target="ftw-core",
            read_only=True,
            package_version="1.0.0",
        )
    missing_read_only = (
        lifecycle
        + b'DRIVER = { version = "1.0.0", host_api_min = 1, host_api_max = 1 }\n'
    )
    with pytest.raises(PackageError, match="must declare read_only = true"):
        _validate_lua_source_for_target(
            missing_read_only,
            target="ftw-core",
            read_only=True,
            package_version="1.0.0",
        )
    other_metadata_is_not_ftw_metadata = (
        missing_read_only
        + b'DRIVER_MANIFEST = { version = "1.0.0", read_only = true }\n'
        + b'-- read_only = true\n'
    )
    with pytest.raises(PackageError, match="must declare read_only = true"):
        _validate_lua_source_for_target(
            other_metadata_is_not_ftw_metadata,
            target="ftw-core",
            read_only=True,
            package_version="1.0.0",
        )
    wrong_read_only = missing_read_only.replace(b" }", b", read_only = false }")
    with pytest.raises(PackageError, match="must match the package"):
        _validate_lua_source_for_target(
            wrong_read_only,
            target="ftw-core",
            read_only=True,
            package_version="1.0.0",
        )
    unsafe = (
        lifecycle
        + b'DRIVER_MANIFEST = { version = "1.0.0", read_only = true }\n'
        + b"host.modbus_write(1, 2)\n"
    )
    with pytest.raises(PackageError, match="read-only"):
        _validate_lua_source_for_target(
            unsafe,
            target="blixt-l1",
            read_only=True,
            package_version="1.0.0",
        )

    ftw_v1 = lifecycle + b'DRIVER = { version = "1.0.0", host_api_min = 1, host_api_max = 1 }\n'
    with pytest.raises(PackageError, match="driver_command_v2"):
        _validate_lua_source_for_target(
            ftw_v1,
            target="ftw-core",
            read_only=False,
            package_version="1.0.0",
            runtime_abi="gopher-lua-source-v2",
            default_entrypoint="driver_default_mode_v2",
        )


def test_unknown_package_target_is_rejected() -> None:
    source = load_json(PILOTS["sdm630"])
    source["compatibility"][0]["target"] = "future-host"
    source["artifact_inputs"][0]["target"] = "future-host"
    with pytest.raises(PackageError, match="future-host"):
        validate_document(source)


def test_secrets_are_rejected_from_package_source() -> None:
    source = load_json(PILOTS["sdm630"])
    source["password"] = "must-not-ship"
    with pytest.raises(PackageError):
        validate_document(source)


def test_policy_rejects_unsafe_read_only_and_lease_combinations() -> None:
    read_only = load_json(PILOTS["sdm630"])
    read_only["permissions"].append("modbus.write")
    with pytest.raises(PackageError, match="read-only"):
        validate_document(read_only)

    read_only = load_json(PILOTS["sdm630"])
    read_only["default_mode"] = {
        "strategy": "vendor_autonomous",
        "entrypoint": "driver_default_mode",
        "description": "Unsafe for a read-only package.",
    }
    with pytest.raises(PackageError, match="default mode"):
        validate_document(read_only)

    controllable = load_json(CONTROLLABLE)
    controllable["lease_policy"]["heartbeat_interval_seconds"] = 30
    with pytest.raises(PackageError, match="heartbeat interval"):
        validate_document(controllable)

    controllable = load_json(CONTROLLABLE)
    del controllable["lease_policy"]["heartbeat_interval_seconds"]
    with pytest.raises(PackageError, match="bounded lease"):
        validate_document(controllable)


def test_control_target_requires_approved_v2_runtime() -> None:
    controllable = load_json(CONTROLLABLE)
    controllable["compatibility"][0]["control_enabled"] = True
    validate_document(controllable)

    target = controllable["compatibility"][0]
    target["runtime"]["abi"] = "gopher-lua-source-v1"
    target["runtime"]["host_api"] = {
        "profile": "sourceful.host/ftw-core/v1",
        "min": 1,
        "max": 1,
    }
    with pytest.raises(PackageError, match="control requires gopher-lua-source-v2"):
        validate_document(controllable)

    controllable = load_json(CONTROLLABLE)
    controllable["compatibility"][0]["control_enabled"] = True
    controllable["default_mode"]["entrypoint"] = "driver_default_mode"
    with pytest.raises(PackageError, match="driver_default_mode_v2"):
        validate_document(controllable)


def test_semver_precedence_supports_prereleases_and_ignores_build_metadata() -> None:
    assert _compare_semver("1.2.3-beta.1", "1.2.3-beta.2") < 0
    assert _compare_semver("1.2.3-beta.2", "1.2.3") < 0
    assert _compare_semver("1.2.3+build.1", "1.2.3+build.2") == 0
