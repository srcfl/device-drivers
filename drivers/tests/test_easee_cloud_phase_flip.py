"""A mid-session Easee phase flip resumes only after charging has stopped."""
from pathlib import Path
import subprocess


def test_easee_cloud_resumes_phase_flip_after_charging_stops():
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(
        [str(root / "lua55"), "drivers/tests/lua_harness/test_easee_cloud_phase_flip.lua"],
        cwd=root, text=True, capture_output=True, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
