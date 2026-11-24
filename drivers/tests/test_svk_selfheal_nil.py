"""A failed battery-power read with control on skips the Solis self-heal.

50-125k-svk and 50-125k-svk-slew compared the battery reading (34755) with
the setpoint without checking that the read answered, so a missed read
raised inside driver_poll and the whole poll failed.
"""

from pathlib import Path
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")

# Driver id and its SELF_HEAL_RUN_REQUIRED.
CASES = [("50-125k-svk", 2), ("50-125k-svk-slew", 4)]


@pytest.mark.parametrize("driver,run_required", CASES, ids=[c[0] for c in CASES])
def test_selfheal_skips_missing_battery_reading(driver: str, run_required: int) -> None:
    result = subprocess.run(
        [str(LUA), "drivers/tests/lua_harness/test_svk_selfheal_nil.lua",
         f"drivers/lua/{driver}.lua", str(run_required)],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
