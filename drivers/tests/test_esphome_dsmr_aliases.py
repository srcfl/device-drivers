"""Exercise ESPHome DSMR aliases against the canonical public driver."""

from pathlib import Path
import subprocess
import sys

import pytest


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

from driver_package import _validate_lua_source_for_target  # noqa: E402


def test_esphome_dsmr_source_has_ftw_read_only_contract():
    source = (ROOT / "drivers/lua/esphome-dsmr.lua").read_bytes()
    _validate_lua_source_for_target(
        source,
        target="ftw-core",
        read_only=True,
        package_version="1.0.1",
        runtime_abi="gopher-lua-source-v1",
    )


@pytest.mark.parametrize("scenario", ["name-derived", "delivered-returned"])
def test_esphome_dsmr_aliases(scenario):
    result = subprocess.run(
        [
            str(ROOT / "lua55"),
            "drivers/tests/lua_harness/test_esphome_dsmr_aliases.lua",
            scenario,
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
