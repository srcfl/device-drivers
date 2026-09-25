"""A steady Easee charge must not look like a stale power reading."""
from pathlib import Path
import subprocess


def test_easee_cloud_reports_poll_time_for_steady_power():
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(
        [str(root / "lua55"), "drivers/tests/lua_harness/test_easee_cloud_power_time.lua"],
        cwd=root, text=True, capture_output=True, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
