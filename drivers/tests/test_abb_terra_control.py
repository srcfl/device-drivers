"""ABB Terra AC sets amps per phase through 0x4100 and stands down once."""
from pathlib import Path
import subprocess


def test_abb_terra_control():
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(
        [str(root / "lua55"), "drivers/tests/lua_harness/test_abb_terra_control.lua"],
        cwd=root, text=True, capture_output=True, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
