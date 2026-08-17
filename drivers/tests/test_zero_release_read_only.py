"""A Core 0 W battery command must never release a hybrid to vendor control."""

from pathlib import Path
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize("driver_name", ["huawei", "ferroamp_modbus"])
def test_zero_release_drivers_are_write_inert(driver_name: str) -> None:
    result = subprocess.run(
        [
            str(ROOT / "lua55"),
            "drivers/tests/lua_harness/test_zero_release_read_only.lua",
            driver_name,
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
