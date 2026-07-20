#!/usr/bin/env python3
"""Fail when private service or secret material crosses the public boundary."""

from __future__ import annotations

import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN_TOP_LEVEL = {
    "admin-ui",
    "alembic",
    "app",
    "infra",
    "kubernetes",
    "scripts",
    "signing",
}
FORBIDDEN_TEXT = {
    "srcfl/" + "srcful-device-support",
    "DRIVER_PACKAGE_" + "SIGNING_SECRET_ARN",
    "DRIVER_PUBLISH_" + "ROLE_ARN",
}
SECRET_PATTERNS = (
    re.compile(rb"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"),
    re.compile(rb"\bgh[opsu]_[A-Za-z0-9]{20,}\b"),
    re.compile(rb"\bAKIA[0-9A-Z]{16}\b"),
)
TEXT_SUFFIXES = {
    ".c", ".h", ".json", ".lua", ".md", ".py", ".sh", ".txt", ".yaml", ".yml"
}
PROVENANCE_EXCEPTIONS = {Path("SOURCE_IMPORT.md"), Path("source-import-delta.json")}
SECRET_PATTERN_EXCEPTIONS = {
    Path("tools/check_public_boundary.py"),
    Path("tools/driver_package.py"),
}


def main() -> int:
    errors: list[str] = []
    present = sorted(name for name in FORBIDDEN_TOP_LEVEL if (ROOT / name).exists())
    if present:
        errors.append("private top-level paths present: " + ", ".join(present))

    for path in sorted(item for item in ROOT.rglob("*") if item.is_file()):
        if {".git", ".venv", ".artifacts"}.intersection(path.parts) or path.stat().st_size > 2_000_000:
            continue
        raw = path.read_bytes()
        relative = path.relative_to(ROOT)
        if relative not in SECRET_PATTERN_EXCEPTIONS:
            for pattern in SECRET_PATTERNS:
                if pattern.search(raw):
                    errors.append(f"{relative}: possible secret material")
        if path.suffix in TEXT_SUFFIXES or path.name in {"Makefile", "LICENSE"}:
            text = raw.decode("utf-8", errors="replace")
            if relative not in PROVENANCE_EXCEPTIONS:
                for value in FORBIDDEN_TEXT:
                    if value in text:
                        errors.append(f"{relative}: forbidden private reference {value}")

    for source in sorted((ROOT / "packages" / "v1").glob("*/package-source.json")):
        payload = json.loads(source.read_text(encoding="utf-8"))
        if payload["source"]["repository"] != "https://github.com/srcfl/device-drivers":
            errors.append(f"{source.relative_to(ROOT)}: public source repository mismatch")
        if payload["builder_id"] != "https://github.com/srcfl/device-drivers/blob/main/tools/driver_package.py":
            errors.append(f"{source.relative_to(ROOT)}: public builder id mismatch")

    if errors:
        for error in errors:
            print(f"FAIL {error}")
        return 1
    print("public repository boundary verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
