"""Read-only EV and vehicle drivers say plainly why FTW cannot control them.

People read the catalog and expect a listed device to be controllable. A
driver that can command its device ships with control on; one that cannot
says so in its DRIVER description and in its manifest notes, in words a
novice understands, and says where control goes instead.

`vag_vehicle` belongs here too. Its wording waits for the open PR on that
driver (#213), which has right of way.
"""
import re

import pytest

from conftest import read_driver, read_manifest

# Driver id -> why FTW cannot control the device through it.
READ_ONLY_REASONS = {
    "tesla_wall_connector": "Tesla offers no way for another system to set its current",
    "teslamate_vehicle": "TeslaMate only logs",
    "home_assistant_vehicle": "only listens",
    "tesla_cloud": "this driver cannot sign",
}


def driver_field(source, field):
    match = re.search(rf'^\s*{field}\s*=\s*(.+?),?\s*$', source, re.M)
    assert match, f"DRIVER has no {field}"
    return match.group(1)


@pytest.mark.parametrize("driver_id", sorted(READ_ONLY_REASONS))
def test_read_only_driver_says_why(driver_id):
    source = read_driver(driver_id)
    assert driver_field(source, "read_only") == "true"
    description = driver_field(source, "description").strip('"')
    reason = READ_ONLY_REASONS[driver_id]
    assert reason in description, description
    assert re.search(r"\b(cannot|not control)\b", description), description
    # Where control goes instead.
    assert re.search(r"charger (FTW|it) can control", description), description

    manifest = read_manifest(driver_id)
    assert re.search(r"^control:\s*false\s*$", manifest, re.M)
    notes = re.search(r'^\s*notes:\s*"(.*)"\s*$', manifest, re.M).group(1)
    assert notes.startswith("Read-only."), notes
    assert "FTW cannot control" in notes, notes
