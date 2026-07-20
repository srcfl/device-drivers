#!/usr/bin/env python3
"""Build, validate, sign, and verify Sourceful driver packages.

The published payload is deterministic for the same source recipe, source
commit, source epoch, compiler, and input bytes. Ed25519 signs canonical JSON
payload bytes; neither a database nor an API response participates in trust.
"""

from __future__ import annotations

import argparse
import base64
import copy
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import urlparse

try:
    from jsonschema import Draft202012Validator, FormatChecker
    from referencing import Registry, Resource
except ImportError as exc:  # pragma: no cover - exercised by CLI environments
    raise SystemExit(
        "driver_package.py requires the package extra: uv run --extra package ..."
    ) from exc


ROOT = Path(__file__).resolve().parents[1]
SCHEMA_DIR = ROOT / "spec" / "schemas"
SCHEMA_FILES = {
    "sourceful.driver-package/v1": "sourceful.driver-package.v1.schema.json",
    "sourceful.driver-package-envelope/v1":
        "sourceful.driver-package-envelope.v1.schema.json",
    "sourceful.driver-package-source/v1":
        "sourceful.driver-package-source.v1.schema.json",
    "sourceful.driver-index/v1": "sourceful.driver-index.v1.schema.json",
    "sourceful.driver-index-envelope/v1":
        "sourceful.driver-index-envelope.v1.schema.json",
    "sourceful.driver-inventory/v1": "sourceful.driver-inventory.v1.schema.json",
    "sourceful.driver-command/v1": "sourceful.driver-command.v1.schema.json",
    "sourceful.driver-command-result/v1":
        "sourceful.driver-command-result.v1.schema.json",
}
KNOWN_TARGETS = {
    "ftw-core",
    "blixt-l1",
    "zap-firmware",
}
SEMVER_RE = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-((?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
    r"(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)
SENSITIVE_KEY_RE = re.compile(
    r"(?:^|_)(?:api_key|access_token|credential|password|private_key|secret)(?:$|_)",
    re.IGNORECASE,
)
WRITE_PERMISSIONS = {"http.post", "modbus.write", "mqtt.publish", "serial.write"}
CONTROL_RUNTIME_V2 = {
    "ftw-core": {
        "abi": "gopher-lua-source-v2",
        "host_api_profile": "sourceful.host/ftw-core/v2",
        "host_api_min": 2,
    },
    "blixt-l1": {
        "abi": "mlua-0.10-luajit21-source-v2",
        "host_api_profile": "sourceful.host/blixt-l1/v2",
        "host_api_min": 2,
    },
}
LUA_WRITE_CALL_RE = re.compile(
    r"\bhost\.(?:http_post|modbus_write(?:_multi)?|mqtt_publish|serial_write)\s*\("
)
LUA_ENTRYPOINT_RE = re.compile(r"\bfunction\s+(driver_[a-z0-9_]+)\s*\(")


class PackageError(ValueError):
    """A deterministic package validation or build failure."""


def canonical_json(value: Any) -> bytes:
    """Return Sourceful Canonical JSON v1 bytes (UTF-8, sorted, compact)."""
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def _read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise PackageError(f"cannot read JSON from {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise PackageError(f"{path}: top-level JSON value must be an object")
    return value


def _write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    data = canonical_json(value) + b"\n"
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_bytes(data)
    temporary.replace(path)


def _schemas() -> tuple[dict[str, dict[str, Any]], Registry]:
    schemas: dict[str, dict[str, Any]] = {}
    resources: list[tuple[str, Resource]] = []
    for schema_version, filename in SCHEMA_FILES.items():
        schema = _read_json(SCHEMA_DIR / filename)
        schemas[schema_version] = schema
        resources.append((schema["$id"], Resource.from_contents(schema)))
    return schemas, Registry().with_resources(resources)


def _format_path(parts: Iterable[Any]) -> str:
    rendered = "$"
    for part in parts:
        rendered += f"[{part}]" if isinstance(part, int) else f".{part}"
    return rendered


def _validate_schema(document: dict[str, Any], schema_version: str) -> None:
    schemas, registry = _schemas()
    schema = schemas[schema_version]
    validator = Draft202012Validator(
        schema,
        registry=registry,
        format_checker=FormatChecker(),
    )
    errors = sorted(
        validator.iter_errors(document),
        key=lambda error: (_format_path(error.absolute_path), error.message),
    )
    if errors:
        details = "; ".join(
            f"{_format_path(error.absolute_path)}: {error.message}" for error in errors
        )
        raise PackageError(details)


def _scan_for_secrets(value: Any, path: str = "$") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            child_path = f"{path}.{key}"
            if SENSITIVE_KEY_RE.search(key):
                raise PackageError(f"{child_path}: secrets are forbidden in packages")
            _scan_for_secrets(child, child_path)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            _scan_for_secrets(child, f"{path}[{index}]")
    elif isinstance(value, str) and re.search(
        r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----", value
    ):
        raise PackageError(f"{path}: private key material is forbidden in packages")


def _parse_semver(version: str) -> tuple[tuple[int, int, int], tuple[str, ...] | None]:
    match = SEMVER_RE.fullmatch(version)
    if not match:
        raise PackageError(f"invalid SemVer: {version!r}")
    prerelease = tuple(match.group(4).split(".")) if match.group(4) else None
    return (int(match.group(1)), int(match.group(2)), int(match.group(3))), prerelease


def _compare_semver(left: str, right: str) -> int:
    left_core, left_pre = _parse_semver(left)
    right_core, right_pre = _parse_semver(right)
    if left_core != right_core:
        return -1 if left_core < right_core else 1
    if left_pre is None or right_pre is None:
        if left_pre is right_pre:
            return 0
        return 1 if left_pre is None else -1
    for left_part, right_part in zip(left_pre, right_pre):
        if left_part == right_part:
            continue
        left_numeric = left_part.isdigit()
        right_numeric = right_part.isdigit()
        if left_numeric and right_numeric:
            return -1 if int(left_part) < int(right_part) else 1
        if left_numeric != right_numeric:
            return -1 if left_numeric else 1
        return -1 if left_part < right_part else 1
    if len(left_pre) == len(right_pre):
        return 0
    return -1 if len(left_pre) < len(right_pre) else 1


def _unique(values: Iterable[str], label: str) -> set[str]:
    items = list(values)
    if len(items) != len(set(items)):
        raise PackageError(f"{label}: values must be unique")
    return set(items)


def _validate_policy(document: dict[str, Any], *, source: bool) -> None:
    _scan_for_secrets(document)

    capabilities = document["capabilities"]
    telemetry_capabilities = set(capabilities["telemetry"])
    stream_capabilities = _unique(
        (stream["kind"] for stream in document["telemetry"]["streams"]),
        "$.telemetry.streams",
    )
    if telemetry_capabilities != stream_capabilities:
        raise PackageError(
            "$.telemetry.streams: stream kinds must exactly match telemetry capabilities"
        )

    command_ids = _unique((item["id"] for item in document["commands"]), "$.commands")
    control_capabilities = set(capabilities["control"])
    for command in document["commands"]:
        if command["capability"] not in control_capabilities:
            raise PackageError(
                f"$.commands: {command['id']} references undeclared control capability "
                f"{command['capability']}"
            )
    if control_capabilities != {item["capability"] for item in document["commands"]}:
        raise PackageError("$.capabilities.control: every capability needs a command")

    read_only = document["read_only"]
    if read_only and WRITE_PERMISSIONS.intersection(document["permissions"]):
        raise PackageError("$.permissions: read-only packages cannot request write permissions")
    if read_only and (control_capabilities or command_ids):
        raise PackageError("$.commands: read-only packages cannot declare control")
    if not read_only and not command_ids:
        raise PackageError("$.commands: controllable packages need at least one command")

    lease = document["lease_policy"]
    default_mode = document["default_mode"]
    if read_only:
        if default_mode.get("strategy") != "not_applicable" or "entrypoint" in default_mode:
            raise PackageError("$.default_mode: read-only packages have no default mode")
        if (
            lease.get("required_for_control") is not False
            or lease.get("expiry_action") != "not_applicable"
            or "max_duration_seconds" in lease
            or "heartbeat_interval_seconds" in lease
        ):
            raise PackageError("$.lease_policy: read-only packages cannot declare a lease")
    else:
        if (
            default_mode.get("strategy") != "vendor_autonomous"
            or default_mode.get("entrypoint")
            not in {"driver_default_mode", "driver_default_mode_v2"}
        ):
            raise PackageError(
                "$.default_mode: controllable packages require a supported default entrypoint"
            )
        if (
            lease.get("required_for_control") is not True
            or lease.get("expiry_action") != "return_to_default"
            or not isinstance(lease.get("heartbeat_interval_seconds"), int)
            or not isinstance(lease.get("max_duration_seconds"), int)
        ):
            raise PackageError("$.lease_policy: controllable packages require a bounded lease")
        heartbeat = lease["heartbeat_interval_seconds"]
        duration = lease["max_duration_seconds"]
        if heartbeat >= duration:
            raise PackageError(
                "$.lease_policy: heartbeat interval must be shorter than lease duration"
            )

    compatibility = document["compatibility"]
    targets = _unique((item["target"] for item in compatibility), "$.compatibility")
    for item in compatibility:
        runtime = item["runtime"]
        if runtime["host_api"]["min"] > runtime["host_api"]["max"]:
            raise PackageError(
                f"$.compatibility[{item['target']}].runtime.host_api: min exceeds max"
            )
        maximum = item["host"].get("max_version_exclusive")
        if maximum and _compare_semver(item["host"]["min_version"], maximum) >= 0:
            raise PackageError(
                f"$.compatibility[{item['target']}].host: empty version range"
            )
        if item["control_enabled"] and read_only:
            raise PackageError(
                f"$.compatibility[{item['target']}]: read-only package enables control"
            )
        if item["control_enabled"]:
            if default_mode.get("entrypoint") != "driver_default_mode_v2":
                raise PackageError(
                    f"$.compatibility[{item['target']}]: control requires "
                    "driver_default_mode_v2"
                )
            required = CONTROL_RUNTIME_V2.get(item["target"])
            if required is None:
                raise PackageError(
                    f"$.compatibility[{item['target']}]: control has no approved v2 runtime"
                )
            host_api = runtime["host_api"]
            if (
                runtime["abi"] != required["abi"]
                or host_api["profile"] != required["host_api_profile"]
                or host_api["min"] < required["host_api_min"]
            ):
                raise PackageError(
                    f"$.compatibility[{item['target']}]: control requires "
                    f"{required['abi']} and {required['host_api_profile']}"
                )

    artifact_key = "artifact_inputs" if source else "artifacts"
    artifacts = document[artifact_key]
    artifact_ids = _unique((item["artifact_id"] for item in artifacts), f"$.{artifact_key}")
    artifact_by_id = {item["artifact_id"]: item for item in artifacts}
    referenced_artifact_ids = {item["artifact_id"] for item in compatibility}
    if artifact_ids != referenced_artifact_ids:
        raise PackageError(f"$.{artifact_key}: every artifact must be referenced exactly once")
    for item in compatibility:
        artifact_id = item["artifact_id"]
        if artifact_id not in artifact_ids:
            raise PackageError(
                f"$.compatibility[{item['target']}]: unknown artifact_id {artifact_id}"
            )
        if artifact_by_id[artifact_id]["target"] != item["target"]:
            raise PackageError(
                f"$.compatibility[{item['target']}]: artifact target does not match"
            )
    if targets != {item["target"] for item in artifacts}:
        raise PackageError(f"$.{artifact_key}: every target needs exactly one artifact")

    if source:
        for item in artifacts:
            if item["input_path"] != document["source"]["path"]:
                raise PackageError(
                    f"$.{artifact_key}: v1 artifacts must derive from the declared source path"
                )
        return

    for item in artifacts:
        if item["sha256"] not in item["filename"]:
            raise PackageError(
                f"$.artifacts[{item['artifact_id']}].filename: full content hash required"
            )
        if not item["url"].endswith(f"/{item['filename']}"):
            raise PackageError(
                f"$.artifacts[{item['artifact_id']}].url: must end in filename"
            )
        compatibility_item = next(
            entry for entry in compatibility if entry["artifact_id"] == item["artifact_id"]
        )
        maximum_size = compatibility_item.get("constraints", {}).get("max_artifact_bytes")
        if maximum_size is not None and item["size_bytes"] > maximum_size:
            raise PackageError(
                f"$.artifacts[{item['artifact_id']}]: exceeds target size constraint"
            )


def validate_document(document: dict[str, Any]) -> dict[str, Any]:
    schema_version = document.get("schema_version")
    if schema_version not in SCHEMA_FILES:
        raise PackageError(f"$.schema_version: unsupported schema {schema_version!r}")
    _validate_schema(document, schema_version)
    if schema_version == "sourceful.driver-package-envelope/v1":
        _validate_policy(document["payload"], source=False)
    elif schema_version in {
        "sourceful.driver-package/v1",
        "sourceful.driver-package-source/v1",
    }:
        _validate_policy(
            document,
            source=schema_version == "sourceful.driver-package-source/v1",
        )
    elif schema_version == "sourceful.driver-index-envelope/v1":
        _validate_index_policy(document["payload"])
    elif schema_version == "sourceful.driver-inventory/v1":
        _validate_inventory_policy(document)
    elif schema_version in {
        "sourceful.driver-command/v1",
        "sourceful.driver-command-result/v1",
    }:
        _scan_for_secrets(document)
    else:
        _validate_index_policy(document)
    return document


def _validate_inventory_policy(document: dict[str, Any]) -> None:
    _scan_for_secrets(document)
    identities: set[tuple[str, str, str, str, str, str, str, str]] = set()
    for driver in document["drivers"]:
        health = driver["health"]
        if sum(health.values()) != driver["configured_instances"]:
            raise PackageError(
                "$.drivers.health: counts must equal configured_instances"
            )
        if driver["running_instances"] > driver["configured_instances"]:
            raise PackageError(
                "$.drivers.running_instances: exceeds configured_instances"
            )
        identity = (
            driver["driver_id"],
            driver["version"],
            driver["source"],
            driver.get("package_id", ""),
            driver.get("repository_id", ""),
            driver.get("package_channel", ""),
            driver.get("artifact_sha256", ""),
            driver.get("source_sha256", ""),
        )
        if identity in identities:
            raise PackageError("$.drivers: duplicate driver inventory identity")
        identities.add(identity)


def _validate_index_policy(document: dict[str, Any]) -> None:
    _scan_for_secrets(document)
    identities: set[tuple[str, str]] = set()
    for package in document["packages"]:
        identity = (package["package_id"], package["version"])
        if identity in identities:
            raise PackageError(
                f"$.packages: duplicate package {package['package_id']}@{package['version']}"
            )
        identities.add(identity)
        parsed = urlparse(package["envelope_url"])
        if parsed.scheme != "https" or not parsed.netloc or parsed.query or parsed.fragment:
            raise PackageError("$.packages.envelope_url: HTTPS URL without query required")


def _safe_input(repo_root: Path, relative_path: str) -> Path:
    root = repo_root.resolve()
    candidate = (root / relative_path).resolve()
    try:
        candidate.relative_to(root)
    except ValueError as exc:
        raise PackageError(f"input escapes repository root: {relative_path}") from exc
    if not candidate.is_file():
        raise PackageError(f"input is not a file: {relative_path}")
    return candidate


def _compile_lua55(compiler: Path, source: Path, source_date_epoch: int) -> bytes:
    if not compiler.is_file():
        raise PackageError(f"Lua 5.5 compiler not found: {compiler}")
    with tempfile.TemporaryDirectory(prefix="sourceful-driver-package-") as temp_dir:
        output = Path(temp_dir) / "driver.luac"
        environment = os.environ.copy()
        environment.update(
            {
                "LC_ALL": "C",
                "SOURCE_DATE_EPOCH": str(source_date_epoch),
                "TZ": "UTC",
            }
        )
        result = subprocess.run(
            [str(compiler.resolve()), "-s", "-o", str(output), str(source)],
            check=False,
            capture_output=True,
            env=environment,
            text=True,
        )
        if result.returncode != 0:
            detail = result.stderr.strip() or result.stdout.strip() or "unknown compiler error"
            raise PackageError(f"Lua 5.5 compilation failed: {detail}")
        bytecode = output.read_bytes()
    if not bytecode.startswith(b"\x1bLua"):
        raise PackageError("Lua 5.5 compiler did not produce Lua bytecode")
    return bytecode


def _lua_named_table_body(source: str, name: str) -> str | None:
    """Return one Lua assignment table body without crossing into another block."""
    assignment = re.search(rf"\b{re.escape(name)}\s*=\s*{{", source)
    if not assignment:
        return None
    start = assignment.end() - 1
    depth = 0
    quote: str | None = None
    i = start
    while i < len(source):
        char = source[i]
        if quote is not None:
            if char == "\\":
                i += 2
                continue
            if char == quote:
                quote = None
            i += 1
            continue
        if source.startswith("--", i):
            long_comment = re.match(r"--\[(=*)\[", source[i:])
            if long_comment:
                close = "]" + long_comment.group(1) + "]"
                end = source.find(close, i + long_comment.end())
                if end < 0:
                    return None
                i = end + len(close)
                continue
            newline = source.find("\n", i + 2)
            i = len(source) if newline < 0 else newline + 1
            continue
        long_string = re.match(r"\[(=*)\[", source[i:])
        if long_string:
            close = "]" + long_string.group(1) + "]"
            end = source.find(close, i + long_string.end())
            if end < 0:
                return None
            i = end + len(close)
            continue
        if char in {'"', "'"}:
            quote = char
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[start + 1 : i]
        i += 1
    return None


def _validate_lua_source_for_target(
    source_bytes: bytes,
    *,
    target: str,
    read_only: bool,
    package_version: str,
    runtime_abi: str | None = None,
    default_entrypoint: str | None = None,
) -> None:
    """Reject a Lua artifact that cannot satisfy its declared target contract.

    This is deliberately a small source-contract check, not a Lua parser or a
    substitute for executing the target's contract tests and HIL suite.
    """
    try:
        source = source_bytes.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise PackageError(f"{target}: Lua source must be UTF-8") from exc

    entrypoints = set(LUA_ENTRYPOINT_RE.findall(source))
    required_entrypoints = {"driver_init", "driver_poll"}
    if read_only:
        required_entrypoints.update({"driver_command", "driver_default_mode"})
    else:
        if runtime_abi in {profile["abi"] for profile in CONTROL_RUNTIME_V2.values()}:
            required_entrypoints.add("driver_command_v2")
        else:
            required_entrypoints.add("driver_command")
        required_entrypoints.add(default_entrypoint or "driver_default_mode")
    if target == "blixt-l1":
        required_entrypoints.add("driver_cleanup")
        metadata_body = _lua_named_table_body(source, "DRIVER_MANIFEST")
        if metadata_body is None:
            raise PackageError("blixt-l1: Lua source must declare DRIVER_MANIFEST")
    elif target == "ftw-core":
        metadata_body = _lua_named_table_body(source, "DRIVER")
        if metadata_body is None:
            raise PackageError("ftw-core: Lua source must declare DRIVER")
        if not re.search(r"\bhost_api_min\s*=", source) or not re.search(
            r"\bhost_api_max\s*=", source
        ):
            raise PackageError("ftw-core: DRIVER must declare host_api_min and host_api_max")
    elif target == "zap-firmware":
        return
    else:
        raise PackageError(f"unsupported Lua target: {target}")

    declared_version = re.search(
        r"\bversion\s*=\s*[\"'](?P<version>[^\"']+)[\"']",
        metadata_body,
    )
    if not declared_version or declared_version.group("version") != package_version:
        raise PackageError(
            f"{target}: Lua metadata version must equal package version {package_version}"
        )

    declared_read_only = re.search(
        r"\bread_only\s*=\s*(?P<value>true|false)\b", metadata_body
    )
    if target == "ftw-core" and read_only and not declared_read_only:
        raise PackageError(f"{target}: read-only Lua source must declare read_only = true")
    if declared_read_only and (declared_read_only.group("value") == "true") != read_only:
        raise PackageError(f"{target}: Lua read_only metadata must match the package")

    missing = sorted(required_entrypoints - entrypoints)
    if missing:
        raise PackageError(f"{target}: Lua source is missing {', '.join(missing)}")
    if read_only and LUA_WRITE_CALL_RE.search(source):
        raise PackageError(f"{target}: read-only Lua source calls a write-capable host API")


def _normalise_source(source: dict[str, Any]) -> dict[str, Any]:
    value = copy.deepcopy(source)
    value["permissions"] = sorted(value["permissions"])
    value["capabilities"]["telemetry"] = sorted(value["capabilities"]["telemetry"])
    value["capabilities"]["control"] = sorted(value["capabilities"]["control"])
    value["device_matches"] = sorted(
        value["device_matches"], key=lambda item: (item["manufacturer"], item["model_family"])
    )
    for match in value["device_matches"]:
        match["variants"] = sorted(match["variants"])
        match["regions"] = sorted(match["regions"])
    value["telemetry"]["streams"] = sorted(
        value["telemetry"]["streams"], key=lambda item: item["kind"]
    )
    value["commands"] = sorted(value["commands"], key=lambda item: item["id"])
    value["compatibility"] = sorted(value["compatibility"], key=lambda item: item["target"])
    value["artifact_inputs"] = sorted(
        value["artifact_inputs"], key=lambda item: item["artifact_id"]
    )
    return value


def build_package(
    source_path: Path,
    repo_root: Path,
    output_dir: Path,
    base_url: str,
    source_commit: str,
    source_date_epoch: int,
    lua55_compiler: Path | None,
) -> dict[str, Any]:
    source = _normalise_source(validate_document(_read_json(source_path)))
    if not re.fullmatch(r"[0-9a-f]{40}", source_commit):
        raise PackageError("source commit must be a 40-character lowercase Git SHA")
    if source_date_epoch < 0:
        raise PackageError("source date epoch cannot be negative")
    parsed_base = urlparse(base_url)
    if parsed_base.scheme != "https" or not parsed_base.netloc or parsed_base.query:
        raise PackageError("base URL must be an HTTPS URL without a query string")

    artifacts: list[dict[str, Any]] = []
    materials: dict[str, dict[str, str]] = {}
    artifact_bytes: dict[str, bytes] = {}
    package_name = source["package_id"].rsplit(".", 1)[-1]
    for artifact_input in source["artifact_inputs"]:
        relative_path = artifact_input["input_path"]
        input_path = _safe_input(repo_root, relative_path)
        input_bytes = input_path.read_bytes()
        compatibility_item = next(
            item
            for item in source["compatibility"]
            if item["artifact_id"] == artifact_input["artifact_id"]
        )
        if artifact_input["media_type"] in {
            "application/vnd.sourceful.lua.source",
            "application/vnd.sourceful.lua.bytecode",
        }:
            _validate_lua_source_for_target(
                input_bytes,
                target=artifact_input["target"],
                read_only=source["read_only"],
                package_version=source["version"],
                runtime_abi=compatibility_item["runtime"]["abi"],
                default_entrypoint=source["default_mode"].get("entrypoint"),
            )
        input_hash = hashlib.sha256(input_bytes).hexdigest()
        material_uri = (
            f"git+{source['source']['repository']}@{source_commit}#{relative_path}"
        )
        materials[material_uri] = {"uri": material_uri, "sha256": input_hash}

        if artifact_input["transform"] == "copy":
            content = input_bytes
        else:
            if lua55_compiler is None:
                raise PackageError("--lua55-compiler is required for lua55-strip artifacts")
            compiler_path = lua55_compiler.resolve()
            if not compiler_path.is_file():
                raise PackageError(f"Lua 5.5 compiler not found: {lua55_compiler}")
            compiler_bytes = compiler_path.read_bytes()
            compiler_uri = "tool:sourceful.lua55-compiler"
            materials[compiler_uri] = {
                "uri": compiler_uri,
                "sha256": hashlib.sha256(compiler_bytes).hexdigest(),
            }
            content = _compile_lua55(lua55_compiler, input_path, source_date_epoch)

        digest = hashlib.sha256(content).hexdigest()
        filename = (
            f"{package_name}-{source['version']}-{artifact_input['target']}-"
            f"{artifact_input['artifact_id']}-{digest}.{artifact_input['extension']}"
        )
        artifact = {
            "artifact_id": artifact_input["artifact_id"],
            "target": artifact_input["target"],
            "media_type": artifact_input["media_type"],
            "filename": filename,
            "url": f"{base_url.rstrip('/')}/{filename}",
            "sha256": digest,
            "size_bytes": len(content),
        }
        artifacts.append(artifact)
        artifact_bytes[filename] = content

    excluded = {"schema_version", "builder_id", "source", "artifact_inputs"}
    payload = {key: value for key, value in source.items() if key not in excluded}
    payload.update(
        {
            "schema_version": "sourceful.driver-package/v1",
            "source": {
                "repository": source["source"]["repository"],
                "commit": source_commit,
                "path": source["source"]["path"],
            },
            "provenance": {
                "builder_id": source["builder_id"],
                "build_type": "sourceful.driver-package/v1",
                "source_date_epoch": source_date_epoch,
                "materials": sorted(materials.values(), key=lambda item: item["uri"]),
            },
            "artifacts": sorted(artifacts, key=lambda item: item["artifact_id"]),
        }
    )
    validate_document(payload)

    output_dir.mkdir(parents=True, exist_ok=True)
    for filename, content in artifact_bytes.items():
        (output_dir / filename).write_bytes(content)
    _write_json(output_dir / "manifest.json", payload)
    return payload


def _load_private_key(path: Path):
    try:
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    except ImportError as exc:  # pragma: no cover
        raise PackageError("cryptography is required for signing") from exc
    key = serialization.load_pem_private_key(path.read_bytes(), password=None)
    if not isinstance(key, Ed25519PrivateKey):
        raise PackageError("private key must be Ed25519 PKCS8 PEM")
    return key


def _load_public_key(path: Path):
    try:
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    except ImportError as exc:  # pragma: no cover
        raise PackageError("cryptography is required for verification") from exc
    key = serialization.load_pem_public_key(path.read_bytes())
    if not isinstance(key, Ed25519PublicKey):
        raise PackageError("public key must be Ed25519 SPKI PEM")
    return key


def sign_payload(payload: dict[str, Any], private_key_path: Path, key_id: str) -> dict[str, Any]:
    validate_document(payload)
    private_key = _load_private_key(private_key_path)
    envelope = {
        "schema_version": "sourceful.driver-package-envelope/v1",
        "payload_type": "application/vnd.sourceful.driver-package.v1+json",
        "canonicalization": "sourceful.canonical-json/v1",
        "key_id": key_id,
        "algorithm": "Ed25519",
        "payload": payload,
        "signature": base64.b64encode(private_key.sign(canonical_json(payload))).decode("ascii"),
    }
    return validate_document(envelope)


def promote_payload(
    payload: dict[str, Any],
    *,
    source_channel: str = "beta",
    target_channel: str = "stable",
) -> dict[str, Any]:
    """Return a stable payload without rebuilding or changing artifacts."""
    validate_document(payload)
    if payload["schema_version"] != "sourceful.driver-package/v1":
        raise PackageError("promotion requires sourceful.driver-package/v1")
    if source_channel != "beta" or target_channel != "stable":
        raise PackageError("v1 only allows beta-to-stable promotion")
    if payload["channel"] != source_channel:
        raise PackageError(
            f"promotion requires a {source_channel} package, got {payload['channel']}"
        )
    promoted = copy.deepcopy(payload)
    promoted["channel"] = target_channel
    return validate_document(promoted)


def sign_index_payload(
    payload: dict[str, Any],
    private_key_path: Path,
    key_id: str,
) -> dict[str, Any]:
    validate_document(payload)
    if payload["schema_version"] != "sourceful.driver-index/v1":
        raise PackageError("index signer requires sourceful.driver-index/v1")
    private_key = _load_private_key(private_key_path)
    envelope = {
        "schema_version": "sourceful.driver-index-envelope/v1",
        "payload_type": "application/vnd.sourceful.driver-index.v1+json",
        "canonicalization": "sourceful.canonical-json/v1",
        "key_id": key_id,
        "algorithm": "Ed25519",
        "payload": payload,
        "signature": base64.b64encode(
            private_key.sign(canonical_json(payload))
        ).decode("ascii"),
    }
    return validate_document(envelope)


def verify_index_envelope(
    envelope: dict[str, Any],
    public_key_path: Path,
) -> dict[str, Any]:
    validate_document(envelope)
    if envelope["schema_version"] != "sourceful.driver-index-envelope/v1":
        raise PackageError("index verifier requires sourceful.driver-index-envelope/v1")
    try:
        signature = base64.b64decode(envelope["signature"], validate=True)
        _load_public_key(public_key_path).verify(
            signature, canonical_json(envelope["payload"])
        )
    except Exception as exc:
        raise PackageError("index envelope signature verification failed") from exc
    return envelope["payload"]


def build_index(
    envelope_paths: list[Path],
    envelope_urls: list[str],
    channel: str,
    source_date_epoch: int,
    public_key_path: Path,
) -> dict[str, Any]:
    if len(envelope_paths) != len(envelope_urls) or not envelope_paths:
        raise PackageError("index requires matching non-empty envelope paths and URLs")
    packages: list[dict[str, Any]] = []
    for path, url in zip(envelope_paths, envelope_urls, strict=True):
        raw = path.read_bytes()
        envelope = _read_json(path)
        payload = verify_envelope(envelope, public_key_path)
        if payload["channel"] != channel:
            package_ref = f"{payload['package_id']}@{payload['version']}"
            raise PackageError(
                f"{package_ref}: package channel does not match index"
            )
        packages.append(
            {
                "package_id": payload["package_id"],
                "version": payload["version"],
                "envelope_url": url,
                "envelope_sha256": hashlib.sha256(raw).hexdigest(),
                "targets": sorted(item["target"] for item in payload["compatibility"]),
            }
        )
    index = {
        "schema_version": "sourceful.driver-index/v1",
        "channel": channel,
        "source_date_epoch": source_date_epoch,
        "packages": sorted(
            packages,
            key=lambda item: (item["package_id"], item["version"]),
        ),
    }
    return validate_document(index)


def verify_envelope(
    envelope: dict[str, Any],
    public_key_path: Path,
    artifact_dir: Path | None = None,
) -> dict[str, Any]:
    validate_document(envelope)
    try:
        signature = base64.b64decode(envelope["signature"], validate=True)
        _load_public_key(public_key_path).verify(
            signature, canonical_json(envelope["payload"])
        )
    except Exception as exc:
        raise PackageError("envelope signature verification failed") from exc

    if artifact_dir is not None:
        root = artifact_dir.resolve()
        for artifact in envelope["payload"]["artifacts"]:
            path = (root / artifact["filename"]).resolve()
            try:
                path.relative_to(root)
            except ValueError as exc:
                raise PackageError("artifact path escapes artifact directory") from exc
            if not path.is_file():
                raise PackageError(f"artifact is missing: {artifact['filename']}")
            content = path.read_bytes()
            if len(content) != artifact["size_bytes"]:
                raise PackageError(f"artifact size mismatch: {artifact['filename']}")
            if hashlib.sha256(content).hexdigest() != artifact["sha256"]:
                raise PackageError(f"artifact hash mismatch: {artifact['filename']}")
    return envelope["payload"]


def compatible_target(
    payload: dict[str, Any],
    *,
    target: str | None,
    host_product: str | None,
    host_version: str | None,
    runtime_name: str | None,
    runtime_semantics: str | None,
    runtime_version: str | None,
    runtime_abi: str | None,
    host_api_profile: str | None,
    host_api: int | None,
) -> dict[str, Any] | None:
    """Resolve exact compatibility; every unknown host/runtime input fails closed."""
    if (
        target not in KNOWN_TARGETS
        or not host_product
        or not host_version
        or not runtime_name
        or not runtime_semantics
        or not runtime_version
        or not runtime_abi
        or not host_api_profile
        or host_api is None
    ):
        return None
    try:
        _parse_semver(host_version)
    except PackageError:
        return None
    match = next(
        (item for item in payload["compatibility"] if item["target"] == target),
        None,
    )
    if match is None or match["host"]["product"] != host_product:
        return None
    if _compare_semver(host_version, match["host"]["min_version"]) < 0:
        return None
    maximum = match["host"].get("max_version_exclusive")
    if maximum and _compare_semver(host_version, maximum) >= 0:
        return None
    runtime = match["runtime"]
    if (
        runtime["name"] != runtime_name
        or runtime["semantics"] != runtime_semantics
        or runtime["version"] != runtime_version
        or runtime["abi"] != runtime_abi
        or runtime["host_api"]["profile"] != host_api_profile
        or not runtime["host_api"]["min"] <= host_api <= runtime["host_api"]["max"]
    ):
        return None
    return match


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate = subparsers.add_parser("validate", help="validate JSON against v1")
    validate.add_argument("document", type=Path)

    package = subparsers.add_parser("package", help="build deterministic artifacts")
    package.add_argument("--source", required=True, type=Path)
    package.add_argument("--repo-root", required=True, type=Path)
    package.add_argument("--output-dir", required=True, type=Path)
    package.add_argument("--base-url", required=True)
    package.add_argument("--source-commit", required=True)
    package.add_argument("--source-date-epoch", required=True, type=int)
    package.add_argument("--lua55-compiler", type=Path)
    package.add_argument("--key", type=Path)
    package.add_argument("--key-id")

    verify = subparsers.add_parser("verify", help="verify envelope and local artifacts")
    verify.add_argument("--envelope", required=True, type=Path)
    verify.add_argument("--public-key", required=True, type=Path)
    verify.add_argument("--artifact-dir", type=Path)

    index = subparsers.add_parser("index", help="build and sign a discovery index")
    index.add_argument("--package-envelope", action="append", required=True, type=Path)
    index.add_argument("--package-url", action="append", required=True)
    index.add_argument("--channel", choices=["beta", "stable"], required=True)
    index.add_argument("--source-date-epoch", required=True, type=int)
    index.add_argument("--public-key", required=True, type=Path)
    index.add_argument("--key", required=True, type=Path)
    index.add_argument("--key-id", required=True)
    index.add_argument("--output", required=True, type=Path)

    promote = subparsers.add_parser(
        "promote", help="promote a verified beta package to stable"
    )
    promote.add_argument("--envelope", required=True, type=Path)
    promote.add_argument("--public-key", required=True, type=Path)
    promote.add_argument("--key", required=True, type=Path)
    promote.add_argument("--key-id", required=True)
    promote.add_argument("--output", required=True, type=Path)

    compatible = subparsers.add_parser("compatible", help="resolve host compatibility")
    compatible.add_argument("--manifest", required=True, type=Path)
    compatible.add_argument("--target", required=True)
    compatible.add_argument("--host-product", required=True)
    compatible.add_argument("--host-version", required=True)
    compatible.add_argument("--runtime-name", required=True)
    compatible.add_argument("--runtime-semantics", required=True)
    compatible.add_argument("--runtime-version", required=True)
    compatible.add_argument("--runtime-abi", required=True)
    compatible.add_argument("--host-api-profile", required=True)
    compatible.add_argument("--host-api", required=True, type=int)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        if args.command == "validate":
            document = validate_document(_read_json(args.document))
            print(f"OK {args.document}: {document['schema_version']}")
        elif args.command == "package":
            if bool(args.key) != bool(args.key_id):
                raise PackageError("--key and --key-id must be provided together")
            payload = build_package(
                args.source,
                args.repo_root,
                args.output_dir,
                args.base_url,
                args.source_commit,
                args.source_date_epoch,
                args.lua55_compiler,
            )
            if args.key:
                envelope = sign_payload(payload, args.key, args.key_id)
                _write_json(args.output_dir / "manifest.envelope.json", envelope)
            print(f"OK {payload['package_id']}@{payload['version']} -> {args.output_dir}")
        elif args.command == "verify":
            payload = verify_envelope(
                _read_json(args.envelope), args.public_key, args.artifact_dir
            )
            print(f"OK {payload['package_id']}@{payload['version']}: signature valid")
        elif args.command == "index":
            index_payload = build_index(
                args.package_envelope,
                args.package_url,
                args.channel,
                args.source_date_epoch,
                args.public_key,
            )
            index_envelope = sign_index_payload(index_payload, args.key, args.key_id)
            _write_json(args.output, index_envelope)
            print(f"OK {len(index_payload['packages'])} packages -> {args.output}")
        elif args.command == "promote":
            beta = verify_envelope(_read_json(args.envelope), args.public_key)
            stable = promote_payload(beta)
            envelope = sign_payload(stable, args.key, args.key_id)
            _write_json(args.output, envelope)
            print(f"OK {stable['package_id']}@{stable['version']}: beta -> stable")
        else:
            document = validate_document(_read_json(args.manifest))
            payload = document.get("payload", document)
            match = compatible_target(
                payload,
                target=args.target,
                host_product=args.host_product,
                host_version=args.host_version,
                runtime_name=args.runtime_name,
                runtime_semantics=args.runtime_semantics,
                runtime_version=args.runtime_version,
                runtime_abi=args.runtime_abi,
                host_api_profile=args.host_api_profile,
                host_api=args.host_api,
            )
            if match is None:
                print("INCOMPATIBLE")
                return 3
            print(f"COMPATIBLE control_enabled={str(match['control_enabled']).lower()}")
    except PackageError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
