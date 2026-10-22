"""A 6 A Easee start is offered 7 A until it charges, then 6 A."""
from pathlib import Path
import subprocess


def test_easee_cloud_start_boost():
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(
        [str(root / "lua55"), "drivers/tests/lua_harness/test_easee_cloud_start_boost.lua"],
        cwd=root, text=True, capture_output=True, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
