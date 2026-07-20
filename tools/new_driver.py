#!/usr/bin/env python3
"""Create a read-only community driver and package recipe."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
KINDS = {"meter", "pv", "battery", "v2x_charger"}
PROTOCOLS = {"http", "modbus", "mqtt", "serial", "standalone"}
READ_PERMISSION = {
    "http": "http.get",
    "modbus": "modbus.read",
    "mqtt": "mqtt.subscribe",
    "serial": "serial.read",
}


def write_new(path: Path, content: str) -> None:
    if path.exists():
        raise SystemExit(f"refusing to replace existing file: {path.relative_to(ROOT)}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--id", required=True)
    parser.add_argument("--protocol", default="modbus", choices=sorted(PROTOCOLS))
    parser.add_argument("--kind", default="meter", choices=sorted(KINDS))
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z0-9]+(?:_[a-z0-9]+)*", args.id):
        raise SystemExit("id must use lowercase letters, digits and single underscores")

    version = "0.1.0"
    driver = f'''DRIVER = {{
  id = "{args.id}",
  name = "{args.id.replace('_', ' ').title()}",
  manufacturer = "TODO",
  version = "{version}",
  host_api_min = 1,
  host_api_max = 1,
  protocols = {{ "{args.protocol}" }},
  capabilities = {{ "{args.kind}" }},
  description = "TODO",
  authors = {{ "TODO" }},
  tested_models = {{}},
  verification_status = "experimental",
  read_only = true,
}}

PROTOCOL = "{args.protocol}"

function driver_init(config)
  -- TODO: validate config and report make/serial when known.
end

function driver_poll()
  -- TODO: read the device and emit fresh {args.kind} telemetry.
  return 5000
end

function driver_cleanup()
end
'''
    manifest = f'''name: "{args.id}"
version: "{version}"
tier: community
author: "TODO"
protocol: {args.protocol}
ders: [{args.kind}]
control: false
tested_devices:
  - manufacturer: "TODO"
    model_family: "TODO"
    variants: []
    regions: []
    firmware_versions: ""
    notes: ""
    min_driver_version: "{version}"
min_host_version: "1.5.0"
size_bytes: 0
dkb_id: ""
sha256: ""
signature: ""
bytecode_sha256: ""
bytecode_signature: ""
bytecode_size: 0
changelog: ""
'''
    package = {
        "schema_version": "sourceful.driver-package-source/v1",
        "package_id": f"com.sourceful.driver.{args.id.replace('_', '-')}",
        "version": version,
        "channel": "beta",
        "display_name": args.id.replace("_", " ").title(),
        "identity": {
            "schema": "sourceful.hardware-identity/v1",
            "make": "driver_reported",
            "serial": "driver_reported_when_available",
            "host_fallbacks": ["mac", "endpoint"],
            "persistent_state_owner": "host",
        },
        "source": {
            "repository": "https://github.com/srcfl/device-drivers",
            "path": f"drivers/lua/{args.id}.lua",
        },
        "builder_id": "https://github.com/srcfl/device-drivers/blob/main/tools/driver_package.py",
        "device_matches": [
            {"manufacturer": "TODO", "model_family": "TODO", "variants": [], "regions": []}
        ],
        "capabilities": {"telemetry": [args.kind], "control": []},
        "permissions": [READ_PERMISSION[args.protocol]] if args.protocol in READ_PERMISSION else [],
        "telemetry": {
            "schema": "sourceful.telemetry/v2",
            "sign_convention": "sourceful.site-import-positive/v1",
            "streams": [
                {"kind": args.kind, "power_field": "w", "meaning": "TODO"}
            ],
        },
        "commands": [],
        "read_only": True,
        "default_mode": {"strategy": "not_applicable", "description": "Read-only driver."},
        "lease_policy": {"required_for_control": False, "expiry_action": "not_applicable"},
        "rollback": {
            "strategy": "install_previous_verified_package",
            "state_owner": "host",
            "automatic": False,
        },
        "compatibility": [
            {
                "target": "ftw-core",
                "artifact_id": "ftw.lua51.source",
                "host": {"product": "ftw", "min_version": "1.5.0", "max_version_exclusive": "2.0.0"},
                "runtime": {
                    "name": "gopher-lua", "semantics": "lua-5.1", "version": "1.1.2",
                    "abi": "gopher-lua-source-v1",
                    "host_api": {"profile": "sourceful.host/ftw-core/v1", "min": 1, "max": 1},
                },
                "control_enabled": False,
            },
            {
                "target": "blixt-l1",
                "artifact_id": "blixt.lua51.source",
                "host": {"product": "blixt-gateway", "min_version": "0.1.0", "max_version_exclusive": "1.0.0"},
                "runtime": {
                    "name": "luajit", "semantics": "lua-5.1", "version": "2.1",
                    "abi": "mlua-0.10-luajit21-source-v1",
                    "host_api": {"profile": "sourceful.host/blixt-l1/v1", "min": 1, "max": 1},
                },
                "control_enabled": False,
            },
        ],
        "artifact_inputs": [
            {
                "artifact_id": "ftw.lua51.source", "target": "ftw-core",
                "media_type": "application/vnd.sourceful.lua.source",
                "input_path": f"drivers/lua/{args.id}.lua", "transform": "copy", "extension": "lua",
            },
            {
                "artifact_id": "blixt.lua51.source", "target": "blixt-l1",
                "media_type": "application/vnd.sourceful.lua.source",
                "input_path": f"drivers/lua/{args.id}.lua", "transform": "copy", "extension": "lua",
            },
        ],
    }

    write_new(ROOT / "drivers" / "lua" / f"{args.id}.lua", driver)
    write_new(ROOT / "manifests" / f"{args.id}.yaml", manifest)
    write_new(
        ROOT / "packages" / "v1" / args.id / "package-source.json",
        json.dumps(package, indent=2, sort_keys=False) + "\n",
    )
    print(f"created read-only community driver {args.id}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
