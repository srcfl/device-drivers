"""Easee's load balancing below FTW's order is reported as a limit."""
from pathlib import Path
import subprocess


def test_easee_cloud_reports_allocated_limit():
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(
        [str(root / "lua55"), "drivers/tests/lua_harness/test_easee_cloud_allocated_limit.lua"],
        cwd=root, text=True, capture_output=True, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
