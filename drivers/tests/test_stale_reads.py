"""Drivers must not emit fresh telemetry from failed or empty reads."""

from pathlib import Path
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[2]


def run_lua(script, value):
    result = subprocess.run(
        [str(ROOT / "lua55"), script, value],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.parametrize(
    "driver_name",
    ["ambibox", "ferroamp", "ferroamp_dc2_v2x", "opendtu_mqtt", "victron_mqtt"],
)
def test_mqtt_driver_does_not_emit_cached_data_on_idle_poll(driver_name):
    run_lua("drivers/tests/lua_harness/test_mqtt_stale.lua", driver_name)


@pytest.mark.parametrize("app", ["ProEM", "MiniPMG3", "Plus2PM"])
def test_shelly_poll_emits_nothing_when_all_reads_fail(app):
    run_lua("drivers/tests/lua_harness/test_shelly_failures.lua", app)


@pytest.mark.parametrize("app", ["ProEM", "Plus2PM", "Pro4PM"])
def test_shelly_multichannel_poll_emits_nothing_when_one_read_fails(app):
    result = subprocess.run(
        [
            str(ROOT / "lua55"),
            "drivers/tests/lua_harness/test_shelly_failures.lua",
            app,
            "partial",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
