"""ctc_ecozenith decodes what an EcoZenith i255 actually returned."""

from pathlib import Path
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"
DRIVER = ROOT / "drivers" / "lua" / "ctc_ecozenith.lua"


def _lua51_compiler():
    for name in ("luac5.1", "luac"):
        path = shutil.which(name)
        if not path:
            continue
        version = subprocess.run(
            [path, "-v"], text=True, capture_output=True, check=False)
        if "Lua 5.1" in version.stdout + version.stderr:
            return path
    return None


def test_ctc_ecozenith_parses_as_lua51():
    """FTW runs drivers on gopher-lua, which only knows Lua 5.1 syntax."""
    compiler = _lua51_compiler()
    if compiler is None:
        pytest.skip("no Lua 5.1 luac on PATH")
    result = subprocess.run(
        [compiler, "-p", str(DRIVER)], text=True, capture_output=True, check=False)
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.skipif(not LUA.exists(), reason="run make check to build ./lua55")
def test_ctc_ecozenith_decodes_i255_registers():
    result = subprocess.run(
        [str(LUA), "drivers/tests/lua_harness/test_ctc_ecozenith.lua"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "PASS" in result.stdout
