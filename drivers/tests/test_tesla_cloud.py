"""Tesla Fleet API vehicle driver: telemetry only, no wake or car control."""
from pathlib import Path
import subprocess


def test_tesla_cloud_telemetry_and_staleness():
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(
        [str(root / "lua55"), "drivers/tests/lua_harness/test_tesla_cloud.lua"],
        cwd=root, text=True, capture_output=True, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
