"""wiser_heat decodes what a Wiser Hub R gen 2 actually returned."""

from pathlib import Path
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")


def test_wiser_heat_decodes_hub_domain():
    result = subprocess.run(
        [str(LUA), "drivers/tests/lua_harness/test_wiser_heat.lua"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "PASS" in result.stdout
