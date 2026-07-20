#!/usr/bin/env python3
"""Reject common private-key and service-token forms in Git history patches."""

from __future__ import annotations

import re
import sys


PATTERNS = {
    "private key": re.compile(
        b"-----BEGIN [A-Z0-9 ]*" + b"PRIVATE KEY-----\\r?\\n"
        + b"[A-Za-z0-9+/=\\r\\n]{100,}"
        + b"-----END [A-Z0-9 ]*PRIVATE KEY-----"
    ),
    "GitHub token": re.compile(b"gh" + b"[opsu]_[A-Za-z0-9]{20,}"),
    "AWS access key": re.compile(b"AK" + b"IA[0-9A-Z]{16}"),
    "OpenAI key": re.compile(b"sk" + b"-[A-Za-z0-9_-]{32,}"),
}


def main() -> int:
    history = sys.stdin.buffer.read()
    found = [name for name, pattern in PATTERNS.items() if pattern.search(history)]
    if found:
        for name in found:
            print(f"FAIL possible {name} in Git history", file=sys.stderr)
        return 1
    print("Git history secret patterns verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
