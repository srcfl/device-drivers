"""A saved battery level needs the current hardware session, not its history."""
from pathlib import Path
import subprocess


def test_easee_cloud_current_session_identity():
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(
        [str(root / "lua55"), "drivers/tests/lua_harness/test_easee_cloud_session.lua"],
        cwd=root, text=True, capture_output=True, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
