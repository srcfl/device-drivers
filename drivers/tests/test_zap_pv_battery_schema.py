"""Exercise zap.lua's read_pv and read_battery on the 1.x and data model v2 APIs."""

from pathlib import Path
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize(
    "scenario",
    [
        "v1",
        "v2",
        "v2_panels_rating",
        "v2_ac_side",
        "v2_null",
        "v2_null_soc",
        "v2_not_opted_in",
    ],
)
def test_zap_pv_battery_schema(scenario):
    result = subprocess.run(
        [
            str(ROOT / "lua55"),
            "drivers/tests/lua_harness/test_zap_pv_battery_schema.lua",
            scenario,
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
