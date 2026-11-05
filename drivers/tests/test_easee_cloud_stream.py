"""Easee's SignalR stream feeds the same readings as REST, which stays the fallback."""
from pathlib import Path
import subprocess


def test_easee_cloud_streams_with_rest_fallback():
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(
        [str(root / "lua55"), "drivers/tests/lua_harness/test_easee_cloud_stream.lua"],
        cwd=root, text=True, capture_output=True, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
