"""Etrel INCH turns orders into a safe current setpoint, pauses, resumes and stands down once."""
from pathlib import Path
import subprocess


def test_etrel_control():
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(
        [str(root / "lua55"), "drivers/tests/lua_harness/test_etrel_control.lua"],
        cwd=root, text=True, capture_output=True, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
