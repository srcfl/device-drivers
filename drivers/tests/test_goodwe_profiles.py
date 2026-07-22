"""Replay synthetic GoodWe fixtures and pin each Modbus batch."""

from pathlib import Path
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize("profile", ["community-v1", "gw8kn-et-hk3000"])
@pytest.mark.parametrize("mode", ["import-charge", "export-discharge"])
def test_goodwe_profile_fixture(profile, mode):
    result = subprocess.run(
        [
            str(ROOT / "lua55"),
            "drivers/tests/lua_harness/test_goodwe_profiles.lua",
            profile,
            mode,
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_goodwe_rejects_unknown_register_profile():
    result = subprocess.run(
        [
            str(ROOT / "lua55"),
            "-e",
            (
                'dofile("drivers/tests/lua_harness/host_mock.lua");'
                'dofile("drivers/lua/goodwe.lua");'
                'driver_init({profile="auto"})'
            ),
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode != 0
    assert "unsupported GoodWe register profile" in result.stderr


def test_goodwe_empty_legacy_config_selects_community_v1():
    result = subprocess.run(
        [
            str(ROOT / "lua55"),
            "drivers/tests/lua_harness/test_goodwe_profiles.lua",
            "community-v1",
            "import-charge",
            "legacy-default",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_goodwe_zero_voltage_omits_derived_phase_current():
    result = subprocess.run(
        [
            str(ROOT / "lua55"),
            "drivers/tests/lua_harness/test_goodwe_profiles.lua",
            "gw8kn-et-hk3000",
            "zero-voltage",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_goodwe_raw_zero_pv_is_valid_at_night():
    result = subprocess.run(
        [
            str(ROOT / "lua55"),
            "drivers/tests/lua_harness/test_goodwe_profiles.lua",
            "gw8kn-et-hk3000",
            "night-zero",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
