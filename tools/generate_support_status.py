#!/usr/bin/env python3
"""Generate the human and machine driver-by-target support matrix."""

from __future__ import annotations

import json
from pathlib import Path

from manifest_parser import parse_yaml_simple


ROOT = Path(__file__).resolve().parents[1]
TARGETS = ("ftw-core", "blixt-l1")


def main() -> int:
    overrides = json.loads(
        (ROOT / "support-status-overrides.json").read_text(encoding="utf-8")
    )
    drivers: list[dict] = []
    rows: list[list[str]] = []
    for manifest_path in sorted((ROOT / "manifests").glob("*.yaml")):
        manifest = parse_yaml_simple(manifest_path.read_text(encoding="utf-8"))
        driver_id = manifest["name"]
        target_status: dict[str, dict] = {}
        for target in TARGETS:
            status = {
                "target_conformance": "not_assessed",
                "historical_signed_beta_version": None,
                "hil": "not_recorded",
                "legacy_parity": "not_assessed",
                "note": "",
            }
            status.update(overrides.get(driver_id, {}).get(target, {}))
            target_status[target] = status
            rows.append(
                [
                    driver_id,
                    str(manifest["version"]),
                    target,
                    status["target_conformance"],
                    status["historical_signed_beta_version"] or "—",
                    status["hil"],
                    status["legacy_parity"],
                ]
            )
        drivers.append(
            {
                "driver_id": driver_id,
                "catalog_version": str(manifest["version"]),
                "catalog_source": True,
                "targets": target_status,
            }
        )

    payload = {
        "schema_version": "sourceful.driver-support-status/v1",
        "targets": list(TARGETS),
        "drivers": drivers,
    }
    (ROOT / "support-status.json").write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    headers = [
        "Driver", "Catalog", "Target", "Conformance", "Signed beta", "HIL",
        "Legacy parity",
    ]
    lines = [
        "# Driver support status",
        "",
        "Catalog source is not proof that a target can install or run a driver.",
        "",
        "| " + " | ".join(headers) + " |",
        "| " + " | ".join("---" for _ in headers) + " |",
    ]
    lines.extend("| " + " | ".join(row) + " |" for row in rows)
    lines.append("")
    (ROOT / "SUPPORT_STATUS.md").write_text("\n".join(lines), encoding="utf-8")
    print(f"generated support status for {len(drivers)} drivers and {len(TARGETS)} targets")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
