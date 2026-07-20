#!/usr/bin/env python3
"""Build one deterministic unsigned driver-package candidate."""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path

from driver_package import PackageError, build_package


ROOT = Path(__file__).resolve().parents[1]


def git(*args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--id", required=True)
    parser.add_argument("--target")
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()

    source = ROOT / "packages" / "v1" / args.id / "package-source.json"
    if not source.is_file():
        raise SystemExit(f"package source not found: {source.relative_to(ROOT)}")
    payload = json.loads(source.read_text(encoding="utf-8"))
    targets = {item["target"] for item in payload["compatibility"]}
    if args.target and args.target not in targets:
        raise SystemExit(
            f"{args.id} does not declare target {args.target}; available: {', '.join(sorted(targets))}"
        )

    try:
        candidate = build_package(
            source,
            ROOT,
            args.output_dir,
            "https://packages.example.invalid/candidate",
            git("rev-parse", "HEAD"),
            int(git("show", "-s", "--format=%ct", "HEAD")),
            ROOT / "luac55" if any(
                item["transform"] == "lua55-strip" for item in payload["artifact_inputs"]
            ) else None,
        )
    except PackageError as exc:
        raise SystemExit(str(exc)) from exc
    print(
        f"unsigned candidate {candidate['package_id']}@{candidate['version']} "
        f"for {', '.join(sorted(targets))}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
