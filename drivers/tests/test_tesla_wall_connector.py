"""Tesla Wall Connector reports charge power only through a closed contactor."""
from pathlib import Path
import subprocess


def test_tesla_wall_connector_charge_power():
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(
        [str(root / "lua55"), "drivers/tests/lua_harness/test_tesla_wall_connector.lua"],
        cwd=root, text=True, capture_output=True, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
