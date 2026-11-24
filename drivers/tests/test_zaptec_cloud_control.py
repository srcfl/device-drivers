"""Zaptec Cloud control stays inside Core's budget and settles when standing down."""
from pathlib import Path
import subprocess


def test_zaptec_cloud_control():
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(
        [str(root / "lua55"), "drivers/tests/lua_harness/test_zaptec_cloud_control.lua"],
        cwd=root, text=True, capture_output=True, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
