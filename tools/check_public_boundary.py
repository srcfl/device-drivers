#!/usr/bin/env python3
"""Fail when private service or secret material crosses the public boundary."""

from __future__ import annotations

import json
import re
import subprocess
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
# baselines/ftw holds byte-exact copies of FTW's bundled drivers. Some of them
# carry a comment pointing at the private repository the canonical drivers came
# from. We must not edit a baseline to remove it, and naming that repository is
# already allowed in the provenance files above for the same reason. Only the
# name check is relaxed here; secret material is still rejected everywhere.
PROVENANCE_TREES = (Path("baselines"),)
SECRET_PATTERN_EXCEPTIONS = {
    Path("tools/check_public_boundary.py"),
    Path("tools/driver_package.py"),
}


def repository_files(root: Path) -> list[Path]:
    """Every file the public repository carries, as paths relative to root.

    Ask git rather than walk the disk. A walk descends into ignored paths too,
    and a git worktree under .claude/worktrees/ is a second full checkout whose
    copies of the provenance files then fail the checks below, naming paths the
    contributor never edited. Ignored means not part of this repository.

    Untracked files that are not ignored are included: a secret must be caught
    before it is staged, not after.
    """
    result = subprocess.run(
        ("git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"),
        cwd=root, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"git ls-files failed in {root}: {result.stderr.strip()}")
    return sorted({Path(name) for name in result.stdout.split("\0") if name})


def main(root: Path = ROOT) -> int:
    errors: list[str] = []
    present = sorted(name for name in FORBIDDEN_TOP_LEVEL if (root / name).exists())
    if present:
        errors.append("private top-level paths present: " + ", ".join(present))

    for relative in repository_files(root):
        path = root / relative
        # git also lists a tracked file deleted from the disk, and a submodule.
        if not path.is_file() or path.stat().st_size > 2_000_000:
            continue
        raw = path.read_bytes()
        if relative not in SECRET_PATTERN_EXCEPTIONS:
            for pattern in SECRET_PATTERNS:
                if pattern.search(raw):
                    errors.append(f"{relative}: possible secret material")
        if path.suffix in TEXT_SUFFIXES or path.name in {"Makefile", "LICENSE"}:
            text = raw.decode("utf-8", errors="replace")
            quotes_external_source = any(
                tree in relative.parents for tree in PROVENANCE_TREES)
            if relative not in PROVENANCE_EXCEPTIONS and not quotes_external_source:
                for value in FORBIDDEN_TEXT:
                    if value in text:
                        errors.append(f"{relative}: forbidden private reference {value}")

    for source in sorted((root / "packages" / "v1").glob("*/package-source.json")):
        payload = json.loads(source.read_text(encoding="utf-8"))
        if payload["source"]["repository"] != "https://github.com/srcfl/device-drivers":
            errors.append(f"{source.relative_to(root)}: public source repository mismatch")
        if payload["builder_id"] != "https://github.com/srcfl/device-drivers/blob/main/tools/driver_package.py":
            errors.append(f"{source.relative_to(root)}: public builder id mismatch")

    if errors:
        for error in errors:
            print(f"FAIL {error}")
        return 1
    print("public repository boundary verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
