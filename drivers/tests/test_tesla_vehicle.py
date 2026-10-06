"""Tesla BLE telemetry recovery without starting a charge."""
from pathlib import Path
import subprocess


def test_tesla_vehicle_recovery():
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(
        [str(root / "lua55"), "drivers/tests/lua_harness/test_tesla_vehicle.lua"],
        cwd=root, text=True, capture_output=True, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
