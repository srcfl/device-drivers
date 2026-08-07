"""`connectivity` has to be checkable, or it is just a word in a file.

A driver that reaches a vendor service has to name that service somewhere in
its source: it builds a URL from a hostname it hardcodes, because there is
nowhere else for a cloud endpoint to come from. A driver that only talks to
the LAN takes its address from config. That asymmetry is what these tests read,
so a manifest cannot claim `local` while the Lua calls an API on the internet.

`setup` cannot be derived the same way -- nothing in the source proves a
manufacturer has to unlock an interface first -- so it is checked for shape
and for the one rule that carries meaning: absent is not `none`.
"""

import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
MANIFESTS = sorted((ROOT / "manifests").glob("*.yaml"))

# A URL literal in code, not in a comment and not the DRIVER table's homepage.
URL_RE = re.compile(r"""https?://([A-Za-z][A-Za-z0-9.-]*\.[A-Za-z]{2,})""")
COMMENT_RE = re.compile(r"^\s*--")
HOMEPAGE_RE = re.compile(r"^\s*homepage\s*=")


def manifest_field(text: str, field: str) -> str:
    match = re.search(rf"^{field}:\s*(.+)$", text, re.MULTILINE)
    return match.group(1).strip().strip('"') if match else ""


def manifest_list(text: str, field: str) -> list[str] | None:
    match = re.search(rf"^{field}:\s*\[(.*)\]$", text, re.MULTILINE)
    if not match:
        return None
    return [item.strip() for item in match.group(1).split(",") if item.strip()]


def called_hosts(driver_id: str) -> set[str]:
    """Hostnames the driver hardcodes into a request, ignoring documentation."""
    source = ROOT / "drivers" / "lua" / f"{driver_id}.lua"
    if not source.is_file():
        return set()
    hosts: set[str] = set()
    for line in source.read_text(encoding="utf-8").splitlines():
        if COMMENT_RE.match(line) or HOMEPAGE_RE.match(line):
            continue
        for host in URL_RE.findall(line):
            # A link to a project page is provenance, not an endpoint.
            if host.endswith("github.com") or host.startswith("developer."):
                continue
            hosts.add(host)
    return hosts


IDS = [path.stem for path in MANIFESTS]


@pytest.mark.parametrize("driver_id", IDS)
def test_every_driver_states_where_it_talks(driver_id: str) -> None:
    text = (ROOT / "manifests" / f"{driver_id}.yaml").read_text(encoding="utf-8")
    assert manifest_field(text, "connectivity") in {"local", "cloud"}, (
        f"{driver_id}: connectivity must be local or cloud")


@pytest.mark.parametrize("driver_id", IDS)
def test_a_local_driver_does_not_call_the_internet(driver_id: str) -> None:
    text = (ROOT / "manifests" / f"{driver_id}.yaml").read_text(encoding="utf-8")
    if manifest_field(text, "connectivity") != "local":
        return
    hosts = called_hosts(driver_id)
    assert not hosts, (
        f"{driver_id} claims connectivity: local but its source builds requests "
        f"against {sorted(hosts)}")


@pytest.mark.parametrize("driver_id", IDS)
def test_a_cloud_driver_names_the_service_it_needs(driver_id: str) -> None:
    text = (ROOT / "manifests" / f"{driver_id}.yaml").read_text(encoding="utf-8")
    if manifest_field(text, "connectivity") != "cloud":
        return
    assert called_hosts(driver_id), (
        f"{driver_id} claims connectivity: cloud but hardcodes no vendor host; "
        "if it reads a device on the LAN it is local")


@pytest.mark.parametrize("driver_id", IDS)
def test_setup_is_absent_or_meaningful(driver_id: str) -> None:
    text = (ROOT / "manifests" / f"{driver_id}.yaml").read_text(encoding="utf-8")
    setup = manifest_list(text, "setup")
    if setup is None:
        assert not re.search(r"^setup:", text, re.MULTILINE), (
            f"{driver_id}: setup must be an inline list, e.g. setup: [device_ui]")
        return
    assert setup, f"{driver_id}: omit setup rather than stating an empty list"
    assert "none" not in setup or len(setup) == 1, (
        f"{driver_id}: setup 'none' cannot be combined with another requirement")


def test_a_cloud_driver_needs_something_from_its_vendor() -> None:
    """Reaching a vendor service means holding a credential for it.

    Not a style rule: a cloud driver whose setup is unrecorded is the case
    where an owner discovers only after installing that they need an account.
    """
    for path in MANIFESTS:
        text = path.read_text(encoding="utf-8")
        if manifest_field(text, "connectivity") != "cloud":
            continue
        setup = manifest_list(text, "setup") or []
        assert setup and setup != ["none"], (
            f"{path.stem}: a cloud driver must record what its vendor requires")
