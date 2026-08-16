#!/usr/bin/env python3
"""Build and verify the signed FTW driver channel from public source."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

try:
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import (
        Ed25519PrivateKey,
        Ed25519PublicKey,
    )
except ImportError as exc:  # pragma: no cover - exercised by CLI environments
    raise SystemExit(
        "ftw_repository.py requires the package extra: uv run --extra package ..."
    ) from exc

from manifest_parser import parse_tested_devices, parse_yaml_simple


ROOT = Path(__file__).resolve().parents[1]
SCHEMA_VERSION = 1
MAX_DRIVER_BYTES = 2 << 20
SEMVER_RE = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
SAFE_ID_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9._-]*$")
ENTRYPOINT_RE = re.compile(r"\bfunction\s+(driver_[a-z0-9_]+)\s*\(")
PROTOCOL_PERMISSIONS = {
    "": [],
    "standalone": [],
    "http": ["http.get"],
    "modbus": ["modbus.read"],
    "mqtt": ["mqtt.subscribe"],
    "serial": ["serial.read"],
}

# What a controlling driver additionally needs. A driver whose catalog manifest
# says control: true has ported control logic, and the channel copy is the same
# source as the bundled copy -- which has always been allowed to write. Denying
# it here only made the same driver behave differently depending on where its
# file came from.
PROTOCOL_WRITE_PERMISSIONS = {
    "": [],
    "standalone": [],
    "http": ["http.post"],
    "modbus": ["modbus.write"],
    "mqtt": ["mqtt.publish"],
    "serial": ["serial.write"],
}



def _identifies_same_driver(metadata_id: str, driver_id: str) -> bool:
    """Whether a DRIVER table's id names the catalog driver holding it.

    FTW spells ids with hyphens and is usually more specific than the catalog
    name, sometimes by inserting a word rather than appending one:

        ctek        <- ctek-chargestorm
        ctek_hybrid <- ctek-chargestorm-hybrid
        sungrow     <- sungrow-shx
        huawei      <- huawei-sun2000
        zap         <- sourceful-zap

    So require the catalog name's words to appear in the declared id in order,
    which all of those satisfy while a driver dropped into the wrong file --
    "deye" holding a growatt table -- still does not.
    """
    def words(value: str) -> list[str]:
        return value.replace("-", "_").split("_")

    remaining = iter(words(metadata_id))
    return all(word in remaining for word in words(driver_id))


class RepositoryError(ValueError):
    """A driver channel build or verification error."""


def canonical_json(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def _semver_tuple(value: str) -> tuple[int, int, int]:
    match = SEMVER_RE.fullmatch(value)
    if not match:
        raise RepositoryError(f"invalid semantic version: {value!r}")
    return tuple(int(part) for part in match.groups())


def _artifact_digest(entry: dict[str, Any]) -> str:
    """The name a published artifact answers to.

    The channel identifies a driver by the SHA-256 of the bytes it publishes,
    which are the Lua source *and* the generated metadata header. Both the
    release and the pull request check hash through here so neither can decide
    a driver is unchanged the other would call changed.
    """
    return hashlib.sha256(entry["raw"]).hexdigest()


def _version_collisions(
    drivers: list[dict[str, Any]], previous_drivers: list[dict[str, Any]]
) -> list[tuple[dict[str, Any], dict[str, Any]]]:
    """Every driver whose artifact bytes moved without a higher version.

    A published version names a set of bytes that runs on hardware, so the
    channel refuses to republish different bytes under one it has already
    shipped. That refusal is the whole rule, and it is stated here once: the
    release enforces it while signing, `check_publication` enforces it on a
    pull request, and a rule stated twice is a rule that drifts -- at which
    point the check that exists to agree with the release stops agreeing.
    """
    previous_by_id = {driver["id"]: driver for driver in previous_drivers}
    collisions = []
    for driver in drivers:
        prior = previous_by_id.get(driver["id"])
        if (
            prior
            and prior["sha256"] != driver["sha256"]
            and _semver_tuple(driver["version"]) <= _semver_tuple(prior["version"])
        ):
            collisions.append((driver, prior))
    return collisions


def _read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RepositoryError(f"cannot read JSON from {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise RepositoryError(f"{path}: top-level value must be an object")
    return value


def _write_bytes(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_bytes(data)
    temporary.replace(path)


def _lua_named_table_body(source: str, name: str) -> str | None:
    match = re.search(rf"\b{re.escape(name)}\s*=\s*\{{", source)
    if not match:
        return None
    start = match.end() - 1
    depth = 0
    quote: str | None = None
    i = start
    while i < len(source):
        char = source[i]
        if quote:
            if char == "\\":
                i += 2
                continue
            if char == quote:
                quote = None
            i += 1
            continue
        if source.startswith("--", i):
            newline = source.find("\n", i + 2)
            i = len(source) if newline < 0 else newline + 1
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


def _string_field(body: str, name: str, *, required: bool = False) -> str:
    match = re.search(rf"\b{re.escape(name)}\s*=\s*[\"']([^\"']*)[\"']", body)
    if match:
        return match.group(1)
    if required:
        raise RepositoryError(f"DRIVER must declare {name}")
    return ""


def _integer_field(body: str, name: str) -> int:
    match = re.search(rf"\b{re.escape(name)}\s*=\s*([0-9]+)\b", body)
    if not match:
        raise RepositoryError(f"DRIVER must declare {name}")
    return int(match.group(1))


def _boolean_field(body: str, name: str) -> bool | None:
    match = re.search(rf"\b{re.escape(name)}\s*=\s*(true|false)\b", body)
    if not match:
        return None
    return match.group(1) == "true"


def _string_list_field(body: str, name: str) -> list[str]:
    match = re.search(rf"\b{re.escape(name)}\s*=\s*\{{([^{{}}]*)\}}", body)
    if not match:
        return []
    return re.findall(r"[\"']([^\"']+)[\"']", match.group(1))


def _decode_private_key(encoded: str) -> Ed25519PrivateKey:
    try:
        raw = base64.b64decode(encoded.strip(), validate=True)
    except ValueError as exc:
        raise RepositoryError("invalid base64 Ed25519 private key") from exc
    if len(raw) == 64:
        raw = raw[:32]
    if len(raw) != 32:
        raise RepositoryError("Ed25519 private key must be a 32-byte seed or 64-byte key")
    return Ed25519PrivateKey.from_private_bytes(raw)


def _decode_public_key(encoded: str) -> Ed25519PublicKey:
    try:
        raw = base64.b64decode(encoded.strip(), validate=True)
    except ValueError as exc:
        raise RepositoryError("invalid base64 Ed25519 public key") from exc
    if len(raw) != 32:
        raise RepositoryError("Ed25519 public key must be 32 bytes")
    return Ed25519PublicKey.from_public_bytes(raw)


def _public_key_bytes(key: Ed25519PublicKey) -> bytes:
    return key.public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )


def _validate_https(value: str, label: str) -> str:
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.netloc:
        raise RepositoryError(f"{label} must be an absolute HTTPS URL")
    return value.rstrip("/")


def _lua_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def _lua_string_list(values: list[str]) -> str:
    return "{ " + ", ".join(_lua_string(value) for value in values) + " }"


def _ftw_artifact(
    raw: bytes,
    metadata: dict[str, Any],
    read_only: bool,
    auth_post_path: str = "",
    controls_body: str | None = None,
) -> bytes:
    """Add FTW metadata and the host-call polyfills older hosts lack.

    A driver the catalog marks control: true keeps its control functions. The
    channel copy and the bundled copy are built from one source, so denying
    writes here made the same driver behave differently depending on where its
    file came from -- the bundled one could drive a battery and the downloaded
    one could not.

    A driver that declares read_only in its own DRIVER table still gets the
    write guards: those are meters and telemetry gateways saying what they are,
    not a policy imposed on them.

    `auth_post_path` is for a driver that can only read once it has signed in.
    Over HTTP a POST is not evidence of actuation -- it is also how a driver
    exchanges a refresh token -- so denying it outright would cost such a
    driver every reading it takes. The exemption is scoped rather than trusted:
    POST is permitted only to a URL ending in the declared path, and denied
    everywhere else, so the flag enforces "this POST is authentication" instead
    of merely asserting it. Matching the path rather than a whole URL survives
    a site pointing the driver at its own base URL.
    """
    protocols = metadata.get("protocols", [])
    capabilities = metadata.get("capabilities", [])
    tested_models = metadata.get("tested_models", [])
    fields = [
        f"    id = {_lua_string(metadata['id'])},",
        f"    name = {_lua_string(metadata['name'])},",
        f"    version = {_lua_string(metadata['version'])},",
        "    host_api_min = 1,",
        "    host_api_max = 1,",
        f"    protocols = {_lua_string_list(protocols)},",
        f"    capabilities = {_lua_string_list(capabilities)},",
    ]
    if read_only:
        fields.append("    read_only = true,")
    for name in (
        "manufacturer",
        "description",
        "homepage",
        "verification_status",
        "verification_notes",
    ):
        value = metadata.get(name)
        if isinstance(value, str) and value:
            fields.append(f"    {name} = {_lua_string(value)},")
    if tested_models:
        fields.append(f"    tested_models = {_lua_string_list(tested_models)},")
    if controls_body is not None:
        fields.append("    controls = {" + controls_body + "},")

    # A driver that declares itself read-only keeps the guards: those are
    # meters and telemetry gateways stating what they are. A driver the catalog
    # marks control: true keeps the control path it was ported with.
    write_guards = ""
    if read_only:
        if auth_post_path:
            # Sign in, then read. Anything else this driver tries to POST is
            # refused exactly as if it had no exemption at all.
            http_post_guard = (
                "local __sourceful_ftw_http_post = host.http_post\n"
                f"local __sourceful_ftw_auth_path = {_lua_string(auth_post_path)}\n"
                "host.http_post = function(url, ...)\n"
                "    local path = type(url) == \"string\" and url:match(\"^[^?]*\") or \"\"\n"
                "    if path:sub(-#__sourceful_ftw_auth_path) == __sourceful_ftw_auth_path then\n"
                "        return __sourceful_ftw_http_post(url, ...)\n"
                "    end\n"
                "    error(\"this driver declares itself read-only: "
                "POST is allowed only for authentication\")\n"
                "end\n"
            )
        else:
            http_post_guard = "host.http_post = __sourceful_ftw_write_denied\n"
        write_guards = (
            "local function __sourceful_ftw_write_denied()\n"
            "    error(\"this driver declares itself read-only\")\n"
            "end\n"
            + http_post_guard +
            "host.modbus_write = __sourceful_ftw_write_denied\n"
            "host.modbus_write_multi = __sourceful_ftw_write_denied\n"
            "host.modbus_write_multiple = __sourceful_ftw_write_denied\n"
            "host.mqtt_pub = __sourceful_ftw_write_denied\n"
            "host.mqtt_publish = __sourceful_ftw_write_denied\n"
            "host.serial_write = __sourceful_ftw_write_denied\n"
        )
    prefix = (
        "-- Generated by tools/ftw_repository.py from the public source and catalog.\n"
        "-- Metadata and host-call polyfills; control follows the catalog.\n"
        "local __sourceful_ftw_metadata = {\n"
        + "\n".join(fields)
        + "\n}\n"
        "DRIVER = __sourceful_ftw_metadata\n"
        + write_guards
        + "local __sourceful_ftw_log = host.log\n"
        "host.log = function(level, message)\n"
        "    if message == nil then return __sourceful_ftw_log(\"info\", tostring(level)) end\n"
        "    return __sourceful_ftw_log(level, message)\n"
        "end\n"
        "host.decode_u32 = host.decode_u32 or host.decode_u32_be\n"
        "host.decode_i32 = host.decode_i32 or host.decode_i32_be\n"
        "host.scale = host.scale or function(value, scale_factor)\n"
        "    return value * (10 ^ scale_factor)\n"
        "end\n"
        "host.decode_f32 = host.decode_f32 or function(hi, lo)\n"
        "    local bits = hi * 65536 + lo\n"
        "    if bits == 0 then return 0 end\n"
        "    local sign = bits >= 2147483648 and -1 or 1\n"
        "    local exponent = math.floor(bits / 8388608) % 256\n"
        "    local mantissa = bits % 8388608\n"
        "    if exponent == 0 then return sign * mantissa * (2 ^ -149) end\n"
        "    if exponent == 255 then return 0 end\n"
        "    return sign * (1 + mantissa / 8388608) * (2 ^ (exponent - 127))\n"
        "end\n"
        "host.decode_u64 = host.decode_u64 or function(w1, w2, w3, w4)\n"
        "    return w1 * 281474976710656 + w2 * 4294967296 + w3 * 65536 + w4\n"
        "end\n\n"
    ).encode("utf-8")
    # Reassert the identity the artifact was signed under. A driver must not be
    # able to rename itself by assigning DRIVER at the end of its own source.
    # The control entrypoints are the driver's own, and stay that way.
    suffix = "\n-- Reassert the signed FTW identity after source load.\nDRIVER = __sourceful_ftw_metadata\n"
    if read_only:
        suffix += (
            "function driver_command(action, value, context) return false end\n"
            "function driver_default_mode() end\n"
        )
    return prefix + raw.rstrip(b"\n") + b"\n" + suffix.encode("utf-8")


def _load_channel(config_path: Path, repo_root: Path) -> list[dict[str, Any]]:
    config = _read_json(config_path)
    if config.get("schema_version") != SCHEMA_VERSION:
        raise RepositoryError("FTW channel schema_version must be 1")
    # Each driver's own manifest decides whether it controls; the channel just
    # has to publish all of them.
    if config.get("include_all") is not True or config.get("release_mode") != "per_driver":
        raise RepositoryError("FTW channel must include the full catalog in per_driver mode")
    manifests_root = repo_root / "manifests"
    configured = [
        {"id": path.stem, "source": f"drivers/lua/{path.stem}.lua"}
        for path in sorted(manifests_root.glob("*.yaml"))
    ]
    if not configured:
        raise RepositoryError("FTW channel has no catalog manifests")

    entries: list[dict[str, Any]] = []
    seen: set[str] = set()
    for item in configured:
        if not isinstance(item, dict):
            raise RepositoryError("FTW channel driver entry must be an object")
        driver_id = item.get("id")
        source_value = item.get("source")
        if not isinstance(driver_id, str) or not SAFE_ID_RE.fullmatch(driver_id):
            raise RepositoryError(f"invalid FTW driver id: {driver_id!r}")
        if driver_id in seen:
            raise RepositoryError(f"duplicate FTW driver id: {driver_id}")
        seen.add(driver_id)
        if not isinstance(source_value, str):
            raise RepositoryError(f"{driver_id}: source must be a path")
        source_path = (repo_root / source_value).resolve()
        drivers_root = (repo_root / "drivers" / "lua").resolve()
        if source_path.parent != drivers_root or source_path.suffix != ".lua":
            raise RepositoryError(f"{driver_id}: source must be a direct drivers/lua file")
        if source_path.stem != driver_id or not source_path.is_file():
            raise RepositoryError(f"{driver_id}: source file does not match its id")

        raw = source_path.read_bytes()
        if len(raw) > MAX_DRIVER_BYTES:
            raise RepositoryError(f"{driver_id}: driver exceeds {MAX_DRIVER_BYTES} bytes")
        try:
            source = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise RepositoryError(f"{driver_id}: Lua source must be UTF-8") from exc
        body = _lua_named_table_body(source, "DRIVER")
        # A meter or telemetry gateway saying what it is. That statement wins
        # over the catalog, so a stray control: true cannot hand a P1 reader a
        # write path it has no code for.
        declares_read_only = bool(body) and re.search(
            r"^\s*read_only\s*=\s*true", body, re.MULTILINE
        ) is not None

        # A read-only driver that has to sign in before it can read anything.
        # It names the path its token exchange goes to, and the generated guard
        # holds it to exactly that -- see _ftw_artifact.
        auth_post_path = _string_field(body, "auth_post_path") if body else ""
        if auth_post_path and not auth_post_path.startswith("/"):
            raise RepositoryError(
                f"{driver_id}: auth_post_path must be a path beginning with '/'")
        if auth_post_path and not declares_read_only:
            raise RepositoryError(
                f"{driver_id}: auth_post_path only means anything with read_only")

        has_driver_command = "driver_command" in set(ENTRYPOINT_RE.findall(source))

        required_entrypoints = {"driver_init", "driver_poll"}
        missing = sorted(required_entrypoints - set(ENTRYPOINT_RE.findall(source)))
        if missing:
            raise RepositoryError(f"{driver_id}: missing {', '.join(missing)}")

        catalog_path = repo_root / "manifests" / f"{driver_id}.yaml"
        if not catalog_path.is_file():
            raise RepositoryError(f"{driver_id}: catalog manifest is missing")
        catalog_text = catalog_path.read_text(encoding="utf-8")
        catalog = parse_yaml_simple(catalog_text)
        version = catalog.get("version")
        protocol = catalog.get("protocol", "")
        capabilities = catalog.get("ders", [])
        if catalog.get("name") != driver_id:
            raise RepositoryError(f"{driver_id}: catalog name does not match its filename")
        if not isinstance(version, str) or not SEMVER_RE.fullmatch(version):
            raise RepositoryError(f"{driver_id}: catalog version must be X.Y.Z")
        if protocol not in PROTOCOL_PERMISSIONS:
            raise RepositoryError(f"{driver_id}: protocol {protocol!r} has no FTW permission map")
        # A driver may legitimately have no DER: myuplink reads a heat pump and
        # publishes only metrics, saying so in its own header. Requiring one
        # would force it to claim telemetry it never emits. A missing list is
        # still an error -- that is a manifest someone forgot to fill in.
        if not isinstance(capabilities, list):
            raise RepositoryError(f"{driver_id}: catalog must declare its DERs, even if none")

        if body is not None:
            metadata_id = _string_field(body, "id")
            metadata_version = _string_field(body, "version")
            # A driver promoted from FTW keeps its own DRIVER table verbatim, so
            # that it stays byte-identical to the baseline it came from and any
            # later edit shows up. That table states FTW's identity, which need
            # not be this catalog's:
            #
            #   id      FTW is more specific -- "sungrow-shx" for what this
            #           catalog publishes as "sungrow". The catalog name is the
            #           one operators use, so it wins; a name that is neither
            #           the catalog id nor a prefix of the declared one is still
            #           an error.
            #   version two lineages. The manifest counts releases from this
            #           repository; DRIVER.version counts FTW's. Forcing them
            #           equal would mean rewriting a field inside a file we
            #           deliberately keep unmodified.
            if metadata_id and not _identifies_same_driver(metadata_id, driver_id):
                raise RepositoryError(f"{driver_id}: DRIVER id is {metadata_id!r}")

        filename = source_path.name
        logical_path = f"drivers/{filename}"
        native_name = _string_field(body, "name") if body else ""
        tested_devices = parse_tested_devices(catalog_text)
        manufacturer = _string_field(body, "manufacturer") if body else ""
        if not manufacturer and tested_devices:
            manufacturer = str(tested_devices[0].get("manufacturer", ""))
        tested_models: list[str] = []
        for device in tested_devices:
            model = device.get("model_family") or device.get("model")
            if isinstance(model, str) and model and model not in tested_models:
                tested_models.append(model)
        # The code decides, not the manifest. Sixteen battery drivers carried a
        # working driver_command while their manifests still said control:
        # false, so trusting the manifest published them unable to do the one
        # thing they were ported for.
        #
        # A driver that declares read_only in its own DRIVER table overrides
        # this: a meter saying what it is outranks an entrypoint it may only
        # have inherited from a shared source.
        controls = has_driver_command and not declares_read_only
        # The DRIVER block's verification claim reaches the artifact only
        # when it is one the review actually gated: a driver declaring
        # production or beta made a checkable statement that a reviewer
        # accepted, so the channel repeats it (with the driver's own notes
        # when present). Anything else -- absent, experimental, or a value
        # outside the vocabulary -- keeps the conservative default, which
        # also keeps every already-published untested driver's bytes
        # unchanged.
        default_verification_notes = (
            "Signed community source; check the catalog for current hardware evidence."
        )
        declared_verification = _string_field(body, "verification_status") if body else ""
        if declared_verification in ("production", "beta"):
            verification_status = declared_verification
            verification_notes = (
                _string_field(body, "verification_notes") or default_verification_notes
            )
        else:
            verification_status = "experimental"
            verification_notes = default_verification_notes
        metadata: dict[str, Any] = {
            "path": logical_path,
            "filename": filename,
            "id": driver_id,
            "name": native_name or driver_id.replace("_", " ").title(),
            "version": version,
            "host_api_min": 1,
            "host_api_max": 1,
            "source": "upstream",
            "read_only": not controls,
            "protocols": [protocol] if protocol and protocol != "standalone" else [],
            "capabilities": capabilities,
            "verification_status": verification_status,
            "verification_notes": verification_notes,
        }
        if manufacturer:
            metadata["manufacturer"] = manufacturer
        if tested_models:
            metadata["tested_models"] = tested_models
        if body:
            for output_name in ("description", "homepage"):
                value = _string_field(body, output_name)
                if value:
                    metadata[output_name] = value

        if auth_post_path and not controls:
            metadata["auth_post_path"] = auth_post_path

        controls_body = (
            _lua_named_table_body(body, "controls") if body and controls else None
        )
        artifact = _ftw_artifact(
            raw,
            metadata,
            read_only=not controls,
            auth_post_path=auth_post_path if not controls else "",
            controls_body=controls_body,
        )
        if len(artifact) > MAX_DRIVER_BYTES:
            raise RepositoryError(f"{driver_id}: generated FTW artifact is too large")

        permissions = list(PROTOCOL_PERMISSIONS[protocol])
        if controls:
            permissions += PROTOCOL_WRITE_PERMISSIONS[protocol]
        elif auth_post_path:
            # Read-only, but it cannot read a thing until it has signed in.
            permissions += PROTOCOL_WRITE_PERMISSIONS[protocol]

        entries.append(
            {
                "id": driver_id,
                "raw": artifact,
                "path": logical_path,
                "filename": filename,
                "version": version,
                "host_api": {"min": 1, "max": 1},
                "metadata": metadata,
                "permissions": permissions,
                "controls": controls,
            }
        )
    return sorted(entries, key=lambda entry: entry["id"])


def _validate_manifest(manifest: dict[str, Any]) -> None:
    if manifest.get("schema_version") != SCHEMA_VERSION:
        raise RepositoryError("manifest schema_version must be 1")
    _validate_https(str(manifest.get("repository", "")), "manifest repository")
    commit = manifest.get("commit")
    if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise RepositoryError("manifest commit must be a full lowercase Git SHA")
    if not isinstance(manifest.get("generated_at"), str):
        raise RepositoryError("manifest generated_at is required")
    drivers = manifest.get("drivers")
    if not isinstance(drivers, list) or not drivers:
        raise RepositoryError("manifest must contain drivers")
    history = manifest.get("history", [])
    if not isinstance(history, list):
        raise RepositoryError("manifest history must be an array")
    seen: set[str] = set()
    for current, driver in [
        *((True, driver) for driver in drivers),
        *((False, driver) for driver in history),
    ]:
        if not isinstance(driver, dict):
            raise RepositoryError("manifest driver entry must be an object")
        driver_id = driver.get("id")
        version = driver.get("version")
        if not isinstance(driver_id, str) or not SAFE_ID_RE.fullmatch(driver_id):
            raise RepositoryError(f"manifest has invalid driver id: {driver_id!r}")
        if current and driver_id in seen:
            raise RepositoryError(f"manifest repeats current driver id: {driver_id}")
        if current:
            seen.add(driver_id)
        if not isinstance(version, str) or not SEMVER_RE.fullmatch(version):
            raise RepositoryError(f"{driver_id}: invalid version")
        if driver.get("path") != f"drivers/{driver.get('filename')}":
            raise RepositoryError(f"{driver_id}: path and filename do not match")
        digest = driver.get("sha256")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise RepositoryError(f"{driver_id}: invalid SHA-256")
        size = driver.get("size_bytes")
        if not isinstance(size, int) or not (0 < size <= MAX_DRIVER_BYTES):
            raise RepositoryError(f"{driver_id}: invalid size_bytes")
        _validate_https(str(driver.get("url", "")), f"{driver_id} artifact URL")
        host_api = driver.get("host_api")
        if not isinstance(host_api, dict) or not (
            isinstance(host_api.get("min"), int)
            and isinstance(host_api.get("max"), int)
            and host_api["min"] <= 1 <= host_api["max"]
        ):
            raise RepositoryError(f"{driver_id}: invalid FTW host API range")
        # read_only and control_enabled are two spellings of one fact, so they
        # must not disagree: a driver that may control while claiming to be
        # read-only would read as safe to anything checking only one of them.
        read_only = driver.get("read_only")
        control_enabled = driver.get("control_enabled")
        if not isinstance(read_only, bool) or not isinstance(control_enabled, bool):
            raise RepositoryError(f"{driver_id}: read_only and control_enabled must be booleans")
        if read_only is control_enabled:
            raise RepositoryError(f"{driver_id}: read_only and control_enabled contradict each other")
        metadata = driver.get("metadata")
        if not isinstance(metadata, dict) or metadata.get("read_only") is not read_only:
            raise RepositoryError(f"{driver_id}: Lua metadata read_only must match the manifest")
        if metadata.get("id") != driver_id or metadata.get("version") != version:
            raise RepositoryError(f"{driver_id}: Lua metadata identity does not match")
        permissions = driver.get("permissions")
        if not isinstance(permissions, list) or len(permissions) != len(set(permissions)):
            raise RepositoryError(f"{driver_id}: permissions must be a unique array")
        allowed_permissions = {
            permission
            for mapping in (PROTOCOL_PERMISSIONS, PROTOCOL_WRITE_PERMISSIONS)
            for values in mapping.values()
            for permission in values
        }
        if not all(
            isinstance(permission, str) and permission in allowed_permissions
            for permission in permissions
        ):
            raise RepositoryError(f"{driver_id}: manifest has an unknown permission")
        write_permissions = {
            permission
            for values in PROTOCOL_WRITE_PERMISSIONS.values()
            for permission in values
        }
        # A read-only driver may hold exactly one write-capable permission, and
        # only the one its declared sign-in needs: the artifact's guard confines
        # that POST to auth_post_path, so the permission cannot reach further
        # than the token exchange it was granted for.
        allowed_write = set()
        if metadata.get("auth_post_path"):
            allowed_write = {"http.post"}
        if read_only and write_permissions.intersection(permissions) - allowed_write:
            raise RepositoryError(f"{driver_id}: read-only driver has a write-capable permission")
        if driver.get("channel") not in {"beta", "stable"}:
            raise RepositoryError(f"{driver_id}: invalid channel")
        artifact_name = Path(urlparse(str(driver.get("url", ""))).path).name
        expected_name = f"driver-{driver_id}-v{version}-{digest[:16]}.lua"
        if artifact_name != expected_name:
            raise RepositoryError(
                f"{driver_id}: artifact name does not match its identity and hash"
            )
        if not re.fullmatch(r"[0-9a-f]{40}", str(driver.get("source_commit", ""))):
            raise RepositoryError(f"{driver_id}: invalid source_commit")
        if current and driver["source_commit"] != commit:
            raise RepositoryError(f"{driver_id}: source_commit does not match manifest commit")


def verify_manifest(
    manifest_path: Path,
    *,
    key_id: str,
    public_key_base64: str,
) -> dict[str, Any]:
    try:
        raw = manifest_path.read_bytes()
    except OSError as exc:
        raise RepositoryError(f"cannot read manifest from {manifest_path}: {exc}") from exc
    envelope = _read_json(manifest_path)
    if raw != canonical_json(envelope) + b"\n":
        raise RepositoryError("manifest envelope must use exact canonical JSON bytes")
    if envelope.get("schema_version") != SCHEMA_VERSION or envelope.get("key_id") != key_id:
        raise RepositoryError("manifest envelope schema or key id does not match")
    payload = envelope.get("payload")
    signature_value = envelope.get("signature")
    if not isinstance(payload, dict) or not isinstance(signature_value, str):
        raise RepositoryError("manifest envelope payload or signature is invalid")
    try:
        signature = base64.b64decode(signature_value, validate=True)
    except ValueError as exc:
        raise RepositoryError("manifest signature is not valid base64") from exc
    try:
        _decode_public_key(public_key_base64).verify(signature, canonical_json(payload))
    except InvalidSignature as exc:
        raise RepositoryError("manifest signature verification failed") from exc
    _validate_manifest(payload)
    return payload


def verify_artifacts(manifest: dict[str, Any], artifacts_dir: Path) -> None:
    for driver in manifest["drivers"]:
        filename = Path(urlparse(driver["url"]).path).name
        artifact = artifacts_dir / filename
        try:
            raw = artifact.read_bytes()
        except OSError as exc:
            raise RepositoryError(f"{driver['id']}: cannot read artifact: {exc}") from exc
        if len(raw) != driver["size_bytes"]:
            raise RepositoryError(f"{driver['id']}: artifact size mismatch")
        if hashlib.sha256(raw).hexdigest() != driver["sha256"]:
            raise RepositoryError(f"{driver['id']}: artifact SHA-256 mismatch")


def _artifact_filename(driver: dict[str, Any]) -> str:
    return Path(urlparse(driver["url"]).path).name


def _require_channel_release_urls(manifest: dict[str, Any], channel: str) -> None:
    expected_base = (
        f"{manifest['repository'].rstrip('/')}/releases/download/drivers-{channel}"
    )
    for driver in manifest["drivers"]:
        if driver["channel"] != channel:
            raise RepositoryError(
                f"{driver['id']}: expected {channel} channel, got {driver['channel']}"
            )
        expected_url = f"{expected_base}/{_artifact_filename(driver)}"
        if driver["url"] != expected_url:
            raise RepositoryError(
                f"{driver['id']}: {channel} URL does not use its channel release"
            )


def _promotion_driver(driver: dict[str, Any]) -> dict[str, Any]:
    normalized = dict(driver)
    normalized.pop("channel", None)
    normalized["url"] = _artifact_filename(driver)
    return normalized


def _catalog_driver(driver: dict[str, Any]) -> dict[str, Any]:
    normalized = _promotion_driver(driver)
    normalized.pop("source_commit", None)
    return normalized


def _driver_delta(
    previous: dict[str, Any], current: dict[str, Any]
) -> dict[str, list[str]]:
    previous_by_id = {driver["id"]: driver for driver in previous["drivers"]}
    current_by_id = {driver["id"]: driver for driver in current["drivers"]}
    previous_ids = set(previous_by_id)
    current_ids = set(current_by_id)
    changed = sorted(
        driver_id
        for driver_id in previous_ids & current_ids
        if _catalog_driver(previous_by_id[driver_id])
        != _catalog_driver(current_by_id[driver_id])
    )
    return {
        "added": sorted(current_ids - previous_ids),
        "removed": sorted(previous_ids - current_ids),
        "changed": changed,
    }


def _verify_complete_publication(
    manifest: dict[str, Any], manifest_path: Path, artifacts_dir: Path
) -> None:
    verify_artifacts(manifest, artifacts_dir)
    payload_path = artifacts_dir / "manifest.payload.json"
    expected_payload = (
        json.dumps(
            manifest, ensure_ascii=False, allow_nan=False, indent=2, sort_keys=True
        ).encode("utf-8")
        + b"\n"
    )
    try:
        actual_payload = payload_path.read_bytes()
    except OSError as exc:
        raise RepositoryError(f"cannot read manifest payload: {exc}") from exc
    if actual_payload != expected_payload:
        raise RepositoryError("manifest.payload.json does not match the signed payload")

    expected_files = {
        "manifest.json",
        "manifest.payload.json",
        *(_artifact_filename(driver) for driver in manifest["drivers"]),
    }
    try:
        actual_files = {path.name for path in artifacts_dir.iterdir() if path.is_file()}
    except OSError as exc:
        raise RepositoryError(f"cannot list prospective publication: {exc}") from exc
    if actual_files != expected_files:
        missing = sorted(expected_files - actual_files)
        unexpected = sorted(actual_files - expected_files)
        raise RepositoryError(
            f"prospective publication file set differs: missing={missing}, "
            f"unexpected={unexpected}"
        )
    if manifest_path.resolve() != (artifacts_dir / "manifest.json").resolve():
        raise RepositoryError("candidate manifest must be part of the prospective publication")


def verify_stable_promotion(
    *,
    beta_manifest_path: Path,
    beta_artifacts_dir: Path,
    previous_stable_manifest_path: Path,
    candidate_manifest_path: Path,
    candidate_artifacts_dir: Path,
    key_id: str,
    public_key_base64: str,
) -> dict[str, Any]:
    """Verify a complete stable candidate before any release write."""
    beta = verify_manifest(
        beta_manifest_path,
        key_id=key_id,
        public_key_base64=public_key_base64,
    )
    previous_stable = verify_manifest(
        previous_stable_manifest_path,
        key_id=key_id,
        public_key_base64=public_key_base64,
    )
    candidate = verify_manifest(
        candidate_manifest_path,
        key_id=key_id,
        public_key_base64=public_key_base64,
    )
    _require_channel_release_urls(beta, "beta")
    _require_channel_release_urls(previous_stable, "stable")
    _require_channel_release_urls(candidate, "stable")
    verify_artifacts(beta, beta_artifacts_dir)
    _verify_complete_publication(
        candidate, candidate_manifest_path, candidate_artifacts_dir
    )

    if candidate["commit"] != beta["commit"]:
        raise RepositoryError(
            f"stable candidate commit {candidate['commit']} does not match signed beta "
            f"commit {beta['commit']}"
        )
    for field in ("schema_version", "repository", "generated_at"):
        if candidate[field] != beta[field]:
            raise RepositoryError(f"stable candidate {field} differs from beta")

    beta_by_id = {driver["id"]: driver for driver in beta["drivers"]}
    candidate_by_id = {driver["id"]: driver for driver in candidate["drivers"]}
    if set(candidate_by_id) != set(beta_by_id):
        missing = sorted(set(beta_by_id) - set(candidate_by_id))
        unexpected = sorted(set(candidate_by_id) - set(beta_by_id))
        raise RepositoryError(
            f"stable current driver IDs differ from beta: missing={missing}, "
            f"unexpected={unexpected}"
        )

    for driver_id in sorted(beta_by_id):
        beta_driver = beta_by_id[driver_id]
        candidate_driver = candidate_by_id[driver_id]
        beta_current = _promotion_driver(beta_driver)
        candidate_current = _promotion_driver(candidate_driver)
        if candidate_current != beta_current:
            fields = sorted(
                field
                for field in set(beta_current) | set(candidate_current)
                if beta_current.get(field) != candidate_current.get(field)
            )
            raise RepositoryError(
                f"{driver_id}: stable current entry differs from beta in "
                f"{', '.join(fields)}"
            )
        beta_artifact = beta_artifacts_dir / _artifact_filename(beta_driver)
        candidate_artifact = candidate_artifacts_dir / _artifact_filename(
            candidate_driver
        )
        try:
            if candidate_artifact.read_bytes() != beta_artifact.read_bytes():
                raise RepositoryError(
                    f"{driver_id}: stable artifact bytes differ from beta"
                )
        except OSError as exc:
            raise RepositoryError(
                f"{driver_id}: cannot compare stable and beta artifacts: {exc}"
            ) from exc

    stable_delta = _driver_delta(previous_stable, candidate)
    beta_delta = _driver_delta(previous_stable, beta)
    if stable_delta != beta_delta:
        raise RepositoryError("old stable to candidate delta differs from tested beta")
    return {
        "commit": candidate["commit"],
        "driver_count": len(candidate["drivers"]),
        "delta": stable_delta,
    }


def build_publication(
    *,
    repo_root: Path,
    config_path: Path,
    output_dir: Path,
    base_url: str,
    repository: str,
    commit: str,
    channel: str,
    key_id: str,
    private_key_base64: str,
    expected_public_key_base64: str,
    generated_at: datetime,
    previous_manifest_path: Path | None = None,
) -> dict[str, Any]:
    base_url = _validate_https(base_url, "publication base URL")
    repository = _validate_https(repository, "repository URL")
    if channel not in {"beta", "stable"}:
        raise RepositoryError("channel must be beta or stable")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise RepositoryError("commit must be a full lowercase Git SHA")
    if not key_id:
        raise RepositoryError("key id is required")
    private_key = _decode_private_key(private_key_base64)
    expected_public = _decode_public_key(expected_public_key_base64)
    if _public_key_bytes(private_key.public_key()) != _public_key_bytes(expected_public):
        raise RepositoryError("signing private key does not match the expected public key")

    configured = _load_channel(config_path, repo_root)
    parent = output_dir.resolve().parent
    parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".ftw-publication-", dir=parent))
    try:
        manifest: dict[str, Any] = {
            "schema_version": SCHEMA_VERSION,
            "repository": repository,
            "commit": commit,
            "generated_at": generated_at.astimezone(timezone.utc)
            .isoformat(timespec="seconds")
            .replace("+00:00", "Z"),
            "drivers": [],
        }
        for entry in configured:
            digest = _artifact_digest(entry)
            artifact_name = (
                f"driver-{entry['id']}-v{entry['version']}-{digest[:16]}.lua"
            )
            _write_bytes(staging / artifact_name, entry["raw"])
            manifest["drivers"].append(
                {
                    "id": entry["id"],
                    "path": entry["path"],
                    "filename": entry["filename"],
                    "version": entry["version"],
                    "sha256": digest,
                    "size_bytes": len(entry["raw"]),
                    "url": f"{base_url}/{artifact_name}",
                    "host_api": entry["host_api"],
                    "metadata": entry["metadata"],
                    "channel": channel,
                    "control_enabled": entry["controls"],
                    "read_only": not entry["controls"],
                    "permissions": entry["permissions"],
                    "source_commit": commit,
                }
            )

        if previous_manifest_path:
            previous = verify_manifest(
                previous_manifest_path,
                key_id=key_id,
                public_key_base64=expected_public_key_base64,
            )
            current = {
                (driver["id"], driver["version"], driver["sha256"])
                for driver in manifest["drivers"]
            }
            collisions = _version_collisions(manifest["drivers"], previous["drivers"])
            if collisions:
                driver, prior = collisions[0]
                raise RepositoryError(
                    f"{driver['id']}: changed artifact needs a higher version than "
                    f"{prior['version']}"
                )
            history: list[dict[str, Any]] = []
            history_keys: set[tuple[str, str, str]] = set()
            for driver in [*previous["drivers"], *previous.get("history", [])]:
                key = (driver["id"], driver["version"], driver["sha256"])
                if key in current or key in history_keys:
                    continue
                history_keys.add(key)
                history.append(driver)
            if history:
                manifest["history"] = sorted(
                    history,
                    key=lambda driver: (driver["id"], driver["version"], driver["sha256"]),
                )

        _validate_manifest(manifest)
        payload_bytes = canonical_json(manifest)
        envelope = {
            "schema_version": SCHEMA_VERSION,
            "key_id": key_id,
            "payload": manifest,
            "signature": base64.b64encode(private_key.sign(payload_bytes)).decode("ascii"),
        }
        _write_bytes(staging / "manifest.json", canonical_json(envelope) + b"\n")
        pretty_payload = json.dumps(
            manifest, ensure_ascii=False, allow_nan=False, indent=2, sort_keys=True
        ).encode("utf-8")
        _write_bytes(staging / "manifest.payload.json", pretty_payload + b"\n")

        verified = verify_manifest(
            staging / "manifest.json",
            key_id=key_id,
            public_key_base64=expected_public_key_base64,
        )
        verify_artifacts(verified, staging)
        if output_dir.exists():
            shutil.rmtree(output_dir)
        staging.replace(output_dir)
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    return manifest


def check_publication(
    *,
    repo_root: Path,
    config_path: Path,
    previous_manifest_path: Path,
    key_id: str,
    expected_public_key_base64: str,
) -> dict[str, Any]:
    """Ask the release's question of a tree nobody has merged yet.

    The version rule is the one release check no pull request could run, because
    running it needed the signed channel -- so it ran on main, after the merge,
    where a failure has already replaced the thing it was meant to guard. #53
    merged green and broke the release that way: it corrected a manifest field
    and read it as catalog-only, not knowing the signed artifact carries it.

    Nothing about the question actually needs the signing key. The published
    manifest is a release asset, its signature verifies with the public key, and
    the bytes a driver would publish as come from the tree. So this builds the
    artifacts in memory, signs nothing, and answers exactly what the release
    would answer -- early enough to be a review comment rather than a red main.

    Reports every colliding driver instead of the first. The release stops at
    one because it has nothing else to do; someone fixing a branch wants the
    whole list in one run.
    """
    configured = _load_channel(config_path, repo_root)
    previous = verify_manifest(
        previous_manifest_path,
        key_id=key_id,
        public_key_base64=expected_public_key_base64,
    )
    drivers = [
        {
            "id": entry["id"],
            "version": entry["version"],
            "sha256": _artifact_digest(entry),
        }
        for entry in configured
    ]
    previous_by_id = {driver["id"]: driver for driver in previous["drivers"]}
    added = sorted(
        driver["id"] for driver in drivers if driver["id"] not in previous_by_id
    )
    changed = sorted(
        driver["id"]
        for driver in drivers
        if driver["id"] in previous_by_id
        and previous_by_id[driver["id"]]["sha256"] != driver["sha256"]
    )
    collisions = _version_collisions(drivers, previous["drivers"])
    if collisions:
        lines = "\n".join(
            f"  {driver['id']}: changed artifact needs a higher version than "
            f"{prior['version']} (published) -- "
            f"make bump-driver ID={driver['id']} LEVEL=patch"
            for driver, prior in collisions
        )
        raise RepositoryError(
            "the signed channel would refuse this tree:\n"
            f"{lines}\n"
            "A published version names a set of bytes, so changed bytes need a "
            "new version. The signed artifact carries the manifest metadata as "
            "well as the Lua source, so a manifest-only edit can move them."
        )
    return {
        "published_commit": previous["commit"],
        "drivers": len(drivers),
        "added": added,
        "changed": changed,
    }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    build = subparsers.add_parser("build", help="build a signed FTW publication")
    build.add_argument("--repo-root", type=Path, default=ROOT)
    build.add_argument("--config", type=Path, default=ROOT / "ftw-channel.json")
    build.add_argument("--output", type=Path, required=True)
    build.add_argument("--base-url", required=True)
    build.add_argument("--repository", required=True)
    build.add_argument("--commit", required=True)
    build.add_argument("--channel", choices=("beta", "stable"), required=True)
    build.add_argument("--key-id", required=True)
    build.add_argument("--source-date-epoch", type=int, required=True)
    build.add_argument("--previous-manifest", type=Path)

    check = subparsers.add_parser(
        "check-versions",
        help="check a tree against the published channel without signing anything",
    )
    check.add_argument("--repo-root", type=Path, default=ROOT)
    check.add_argument("--config", type=Path, default=ROOT / "ftw-channel.json")
    check.add_argument("--previous-manifest", type=Path, required=True)
    check.add_argument("--key-id", required=True)

    verify = subparsers.add_parser("verify", help="verify a signed FTW publication")
    verify.add_argument("--manifest", type=Path, required=True)
    verify.add_argument("--artifacts", type=Path, required=True)
    verify.add_argument("--key-id", required=True)

    commit = subparsers.add_parser(
        "manifest-commit", help="verify a signed manifest and print its source commit"
    )
    commit.add_argument("--manifest", type=Path, required=True)
    commit.add_argument("--key-id", required=True)

    promotion = subparsers.add_parser(
        "verify-stable-promotion",
        help="verify a complete stable candidate against signed beta and old stable",
    )
    promotion.add_argument("--beta-manifest", type=Path, required=True)
    promotion.add_argument("--beta-artifacts", type=Path, required=True)
    promotion.add_argument("--previous-stable-manifest", type=Path, required=True)
    promotion.add_argument("--candidate-manifest", type=Path, required=True)
    promotion.add_argument("--candidate-artifacts", type=Path, required=True)
    promotion.add_argument("--key-id", required=True)
    return parser


def main() -> int:
    args = _parser().parse_args()
    try:
        public_key = os.environ.get("FTW_DRIVER_SIGNING_PUBLIC_KEY", "")
        if not public_key:
            raise RepositoryError("FTW_DRIVER_SIGNING_PUBLIC_KEY is required")
        if args.command == "build":
            private_key = os.environ.get("FTW_DRIVER_SIGNING_KEY", "")
            if not private_key:
                raise RepositoryError("FTW_DRIVER_SIGNING_KEY is required")
            build_publication(
                repo_root=args.repo_root.resolve(),
                config_path=args.config.resolve(),
                output_dir=args.output.resolve(),
                base_url=args.base_url,
                repository=args.repository,
                commit=args.commit,
                channel=args.channel,
                key_id=args.key_id,
                private_key_base64=private_key,
                expected_public_key_base64=public_key,
                generated_at=datetime.fromtimestamp(args.source_date_epoch, tz=timezone.utc),
                previous_manifest_path=(
                    args.previous_manifest.resolve() if args.previous_manifest else None
                ),
            )
            return 0
        if args.command == "check-versions":
            report = check_publication(
                repo_root=args.repo_root.resolve(),
                config_path=args.config.resolve(),
                previous_manifest_path=args.previous_manifest.resolve(),
                key_id=args.key_id,
                expected_public_key_base64=public_key,
            )
            print(json.dumps(report, sort_keys=True))
            return 0
        if args.command == "verify-stable-promotion":
            report = verify_stable_promotion(
                beta_manifest_path=args.beta_manifest.resolve(),
                beta_artifacts_dir=args.beta_artifacts.resolve(),
                previous_stable_manifest_path=args.previous_stable_manifest.resolve(),
                candidate_manifest_path=args.candidate_manifest.resolve(),
                candidate_artifacts_dir=args.candidate_artifacts.resolve(),
                key_id=args.key_id,
                public_key_base64=public_key,
            )
            print(json.dumps(report, sort_keys=True))
            return 0
        manifest = verify_manifest(
            args.manifest.resolve(),
            key_id=args.key_id,
            public_key_base64=public_key,
        )
        if args.command == "manifest-commit":
            print(manifest["commit"])
            return 0
        verify_artifacts(manifest, args.artifacts.resolve())
        return 0
    except RepositoryError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
