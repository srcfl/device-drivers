"""TeslaMate MQTT vehicle driver: telemetry only, no wake or car control."""
from pathlib import Path
import subprocess


def test_teslamate_vehicle_telemetry_and_staleness():
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(
        [str(root / "lua55"), "drivers/tests/lua_harness/test_teslamate_vehicle.lua"],
        cwd=root, text=True, capture_output=True, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_teslamate_vehicle_cable_and_place():
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(
        [str(root / "lua55"), "drivers/tests/lua_harness/test_teslamate_vehicle_plug.lua"],
        cwd=root, text=True, capture_output=True, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
