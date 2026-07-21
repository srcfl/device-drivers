"""GoodWe must not turn failed Modbus reads into fresh zero data."""

from pathlib import Path
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize("scenario", ["all", "pv", "battery", "meter"])
def test_goodwe_suppresses_stream_with_failed_primary_read(scenario):
    result = subprocess.run(
        [
            str(ROOT / "lua55"),
            "drivers/tests/lua_harness/test_goodwe_failures.lua",
            scenario,
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
