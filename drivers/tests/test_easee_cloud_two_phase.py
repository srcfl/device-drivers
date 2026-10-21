"""Two-phase car current differs from the charger's phase-mode enum."""
from pathlib import Path
import subprocess


def test_easee_cloud_two_phase_commands():
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(
        [str(root / "lua55"), "drivers/tests/lua_harness/test_easee_cloud_two_phase.lua"],
        cwd=root, text=True, capture_output=True, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
