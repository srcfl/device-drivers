"""go-e HTTP: power orders become whole amps, written only on change, and a refused write fails."""
from pathlib import Path
import subprocess


def test_goe_http_control():
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(
        [str(root / "lua55"), "drivers/tests/lua_harness/test_goe_http_control.lua"],
        cwd=root, text=True, capture_output=True, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
