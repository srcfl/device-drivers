"""Easee's own limit reset is undone by re-sending the order as a command."""
from pathlib import Path
import subprocess


def test_easee_cloud_resend():
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(
        [str(root / "lua55"), "drivers/tests/lua_harness/test_easee_cloud_resend.lua"],
        cwd=root, text=True, capture_output=True, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
