"""victron_mqtt sends the Venus keep-alive and drops system battery values a
full republish leaves out (srcfl/device-drivers#256).

Venus OS publishes only while some client sends R/<portal ID>/keepalive
(victronenergy/dbus-flashmq README, "Keep-alive"). The driver learns the
portal ID from the retained N/<portal ID>/system/0/Serial, sends a
keep-alive every 30 s, asks for a full republish every 120 s and when the GX
speaks again after a silent link, and keeps working when the host refuses to
publish.
"""

from pathlib import Path
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")


@pytest.mark.parametrize(
    "scenario",
    [
        "subscribes",
        "no_portal_no_keepalive",
        "first_keepalive_full",
        "portal_from_any_topic",
        "interval",
        "silent_link_asks_again",
        "refused",
        "refused_keeps_values",
        "republish_drops_gone_value",
        "republish_keeps_resent_value",
        "idle_poll_emits_nothing",
    ],
)
def test_victron_mqtt_keepalive(scenario):
    result = subprocess.run(
        [str(LUA), "drivers/tests/lua_harness/test_victron_mqtt_keepalive.lua", scenario],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
