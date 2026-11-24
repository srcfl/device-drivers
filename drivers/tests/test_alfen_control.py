"""Alfen sets amps per phase, refreshes inside the validity time and stands down once."""
from pathlib import Path
import subprocess


def test_alfen_control():
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(
        [str(root / "lua55"), "drivers/tests/lua_harness/test_alfen_control.lua"],
        cwd=root, text=True, capture_output=True, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
