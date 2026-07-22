"""Run the public GoodWe source against the FTW v1 driver contract."""

from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

from driver_package import _validate_lua_source_for_target  # noqa: E402


def test_goodwe_public_source_has_ftw_managed_metadata():
    source = (ROOT / "drivers/lua/goodwe.lua").read_bytes()
    _validate_lua_source_for_target(
        source,
        target="ftw-core",
        read_only=True,
        package_version="1.0.2",
        runtime_abi="gopher-lua-source-v1",
    )


def test_goodwe_public_source_runs_with_ftw_v1_host_names():
    source = (ROOT / "drivers/lua/goodwe.lua").read_text(encoding="utf-8")
    assert "host.decode_u32(" not in source
    assert "host.decode_i32(" not in source

    result = subprocess.run(
        [str(ROOT / "lua55"), "drivers/tests/lua_harness/test_goodwe_ftw_contract.lua"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
