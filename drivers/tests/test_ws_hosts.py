"""A driver that opens a WebSocket lists every host it dials in ws_hosts.

Core grants a driver's WebSocket only from DRIVER.ws_hosts, for a config that
already grants HTTP, or from a capabilities.websocket entry in the config
(srcfl/ftw#1822). A box set up from the UI writes no such entry. A driver that
dials a host its ws_hosts leaves out gets "ws: capability not granted" and
never reads: tibber 1.1.2 did exactly that.
"""
import re
import sys
from pathlib import Path

import pytest
from conftest import get_driver_names, read_driver, strip_lua_comments

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
from ftw_repository import (  # noqa: E402
    _lua_named_table_body,
    _lua_top_level_string_list,
)

WS_DIAL = re.compile(r"host\.ws_open\b")
WS_URL_HOST = re.compile(r"""["']wss?://([A-Za-z0-9.-]+)""")
# Core reads the DRIVER block of a bundled file with this pattern
# (go/internal/drivers/catalog.go, pickList).
CORE_PICK_LIST = re.compile(r"^\s*ws_hosts\s*=\s*\{([^}]*)\}", re.MULTILINE)


def _streaming_drivers():
    return [
        name for name in get_driver_names()
        if WS_DIAL.search(strip_lua_comments(read_driver(name)))
    ]


STREAMING_DRIVERS = _streaming_drivers()


def test_finds_the_known_streaming_drivers():
    # If the search above stops finding them, the test below checks nothing.
    assert {"easee_cloud", "tibber"} <= set(STREAMING_DRIVERS)


@pytest.mark.parametrize("driver_name", STREAMING_DRIVERS)
def test_ws_hosts_cover_every_dialled_host(driver_name):
    code = read_driver(driver_name)
    dialled = sorted(set(WS_URL_HOST.findall(strip_lua_comments(code))))
    assert dialled, f"{driver_name}: opens a WebSocket but names no wss:// host"

    body = _lua_named_table_body(code, "DRIVER")
    assert body, f"{driver_name}: no DRIVER table"

    # What the signed channel writes into the header Core reads.
    declared = _lua_top_level_string_list(body, "ws_hosts")
    missing = [h for h in dialled if h not in declared]
    assert not missing, (
        f"{driver_name}: dials {missing} but DRIVER.ws_hosts lists {declared}; "
        "Core will refuse the WebSocket for a config set up from the UI"
    )

    # What Core reads from the bundled copy.
    match = CORE_PICK_LIST.search(body)
    assert match, f"{driver_name}: Core cannot read ws_hosts from the DRIVER table"
    core_hosts = re.findall(r'"([^"]+)"', match.group(1))
    assert set(dialled) <= set(core_hosts), (
        f"{driver_name}: Core reads ws_hosts as {core_hosts}, dialled {dialled}"
    )
