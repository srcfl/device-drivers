"""Exercise remne_p1ib against a /meterData-shaped payload."""

from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[2]


def test_remne_p1ib_meter_data():
    result = subprocess.run(
        [str(ROOT / "lua55"), "drivers/tests/lua_harness/test_remne_p1ib.lua"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
