"""Easee's coarse session counter must be declared, and stay reported."""
from pathlib import Path
import subprocess


def test_easee_cloud_declares_its_coarse_session_counter():
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(
        [str(root / "lua55"), "drivers/tests/lua_harness/test_easee_cloud_session_counter.lua"],
        cwd=root, text=True, capture_output=True, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
