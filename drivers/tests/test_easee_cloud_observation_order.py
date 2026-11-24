"""Late cloud packets must not replace a newer power observation."""
from pathlib import Path
import subprocess


def test_easee_cloud_preserves_power_source_order():
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(
        [str(root / "lua55"), "drivers/tests/lua_harness/test_easee_cloud_observation_order.lua"],
        cwd=root, text=True, capture_output=True, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
