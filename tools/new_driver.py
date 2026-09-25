#!/usr/bin/env python3
"""Create a read-only community driver and its manifest."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
KINDS = {"meter", "pv", "battery", "v2x_charger"}
PROTOCOLS = {"http", "modbus", "mqtt", "serial", "standalone"}


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
connectivity: local
# What a human must obtain before this driver can connect at all -- even when
# it only ever talks to the LAN. Leave the line out rather than guessing:
# absent means nobody recorded it, [none] claims nothing is needed. One or
# more of: none, device_screen, device_ui, vendor_app, vendor_portal,
# installer, vendor_approval, bridge
# setup: [device_ui]
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
    write_new(ROOT / "drivers" / "lua" / f"{args.id}.lua", driver)
    write_new(ROOT / "manifests" / f"{args.id}.yaml", manifest)
    print(f"created read-only community driver {args.id}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
