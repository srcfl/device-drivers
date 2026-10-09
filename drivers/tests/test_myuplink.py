"""MyUplink driver regression tests for NIBE F750 telemetry."""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")


def test_myuplink_f750_telemetry():
    result = subprocess.run(
        [str(LUA), "drivers/tests/lua_harness/test_myuplink_f750.lua"],
        capture_output=True, text=True, cwd=ROOT)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "PASS" in result.stdout
