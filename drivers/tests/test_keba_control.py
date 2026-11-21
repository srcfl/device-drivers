"""KEBA P30 turns orders into a safe current and enable, pauses, resumes and stands down once."""
from pathlib import Path
import subprocess


def test_keba_control():
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(
        [str(root / "lua55"), "drivers/tests/lua_harness/test_keba_control.lua"],
        cwd=root, text=True, capture_output=True, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
