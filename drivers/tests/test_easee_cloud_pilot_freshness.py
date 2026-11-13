from pathlib import Path
import subprocess

def test_easee_cloud_pilot_freshness():
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run([str(root / "lua55"), "drivers/tests/lua_harness/test_easee_cloud_pilot_freshness.lua"], cwd=root, capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
