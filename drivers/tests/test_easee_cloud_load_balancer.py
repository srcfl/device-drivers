"""A charging Easee car cut by the load balancer must say so."""
from pathlib import Path
import subprocess


def test_easee_cloud_reports_load_balancer_limit_while_charging():
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(
        [str(root / "lua55"), "drivers/tests/lua_harness/test_easee_cloud_load_balancer.lua"],
        cwd=root, text=True, capture_output=True, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "Easee load balancer: passed" in result.stdout
