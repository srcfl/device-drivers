"""What the battery can do now, for the Solis 50-125 kW and Konja SvK drivers.

Each driver reports its BMS temperature and live charge/discharge limits
(docs/WRITING-A-DRIVER.md, "What a battery can do now"): with the right
scale and sign when the device answers, left out when a read fails or a
value is out of range, and never replayed from an earlier read.
"""

from pathlib import Path
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")

CASES = [
    ("50-125k-svk", "test_battery_limits_solis_svk.lua"),
    ("50-125k-svk-slew", "test_battery_limits_solis_svk.lua"),
    ("50-125k-svk-ac-slew", "test_battery_limits_solis_svk.lua"),
    ("konja-261-svk", "test_battery_limits_konja.lua"),
]


@pytest.mark.parametrize("driver,script", CASES, ids=[c[0] for c in CASES])
def test_battery_limits(driver: str, script: str) -> None:
    result = subprocess.run(
        [str(LUA), f"drivers/tests/lua_harness/{script}", f"drivers/lua/{driver}.lua"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
