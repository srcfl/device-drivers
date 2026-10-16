"""Home Assistant vehicle driver: telemetry only, cable and place from the automation."""
from pathlib import Path
import subprocess


def test_home_assistant_vehicle_recorded_messages():
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(
        [str(root / "lua55"), "drivers/tests/lua_harness/test_home_assistant_vehicle.lua"],
        cwd=root, text=True, capture_output=True, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
