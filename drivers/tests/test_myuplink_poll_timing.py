"""myuplink retries a failed read soon and stores a rotated token later."""

from pathlib import Path
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")


def test_myuplink_poll_timing_and_token_store():
    result = subprocess.run(
        [str(LUA), "drivers/tests/lua_harness/test_myuplink_poll_timing.lua"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "PASS" in result.stdout
