"""The catalog page must not be able to say something the repository doesn't.

The page is the first thing most people see about these drivers, and it is the
one artefact where a stale number would be invisible: nobody diffs a rendered
page against 80 manifests. So the generator is held to the same rule as the
other generated files here — it may only restate what the repository already
says, and it must restate all of it.

The claim that matters most is hardware coverage. Five drivers say they have
run on real hardware and 28 say they have not; a page that blurred that
distinction would be worse than no page.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import generate_site  # noqa: E402
from manifest_parser import parse_yaml_simple  # noqa: E402


@pytest.fixture(scope="module")
def catalog() -> dict:
    return generate_site.build_catalog()


@pytest.fixture(scope="module")
def rendered(tmp_path_factory) -> Path:
    out = tmp_path_factory.mktemp("site")
    generate_site.write_site(out)
    return out


def manifest_ids() -> set[str]:
    return {path.stem for path in (ROOT / "manifests").glob("*.yaml")}


def test_every_manifest_reaches_the_page(catalog: dict) -> None:
    """A driver that exists but is missing from the catalog is invisible."""
    listed = {driver["id"] for driver in catalog["drivers"]}
    assert listed == manifest_ids(), (
        "the page and manifests/ disagree about which drivers exist: "
        f"{listed ^ manifest_ids()}")


def test_versions_match_the_manifests(catalog: dict) -> None:
    """The page states an installable version; it has to be the real one."""
    for driver in catalog["drivers"]:
        manifest = parse_yaml_simple(
            (ROOT / "manifests" / f"{driver['id']}.yaml").read_text(encoding="utf-8"))
        assert driver["version"] == manifest.get("version"), driver["id"]
        assert driver["tier"] == manifest.get("tier", "community"), driver["id"]
        assert driver["control"] == bool(manifest.get("control", False)), driver["id"]


def test_hardware_claims_come_only_from_the_driver_source(catalog: dict) -> None:
    """`hardware_verified` may only be true for a status the driver itself sets.

    Every other status — experimental, beta, alpha — describes a driver that has
    not been confirmed against the device, and must not be shown as if it had.
    """
    for driver in catalog["drivers"]:
        verification = driver["verification"]
        if driver["hardware_verified"]:
            assert verification is not None, driver["id"]
            assert verification["status"] in generate_site.HARDWARE_VERIFIED, driver["id"]
            assert verification["level"] == "confirmed", driver["id"]
        elif verification:
            assert verification["level"] != "confirmed", (
                f"{driver['id']} is shown as confirmed but its source says "
                f"{verification['status']}")


def test_every_verification_status_has_wording(catalog: dict) -> None:
    """An unmapped status would reach the page as a bare enum value."""
    for driver in catalog["drivers"]:
        verification = driver["verification"]
        if verification:
            assert verification["status"] in generate_site.VERIFICATION, (
                f"{driver['id']}: verification_status "
                f"{verification['status']!r} has no wording in VERIFICATION")


def test_tested_devices_survive_intact(catalog: dict) -> None:
    """The model list is the reason to visit the page; it must be complete."""
    total = sum(len(d["tested_devices"]) for d in catalog["drivers"])
    assert total >= 170, f"only {total} tested-device entries reached the page"
    for driver in catalog["drivers"]:
        for device in driver["tested_devices"]:
            assert device["manufacturer"], driver["id"]
            assert device["model_family"], driver["id"]


def test_every_driver_says_something(catalog: dict) -> None:
    """A row with no prose tells a reader nothing the id didn't already."""
    silent = [d["id"] for d in catalog["drivers"]
              if not d["description"] and not d["source_note"]]
    assert not silent, f"no description and no source note: {silent}"


def test_page_is_written_and_self_consistent(rendered: Path) -> None:
    """The embedded payload has to survive being inlined into a script tag."""
    assert (rendered / ".nojekyll").exists()
    sidecar = json.loads((rendered / "drivers.json").read_text(encoding="utf-8"))

    html = (rendered / "index.html").read_text(encoding="utf-8")
    match = re.search(r"window\.__CATALOG__ = (\{.*?\});</script>", html, re.DOTALL)
    assert match, "the page no longer embeds a catalog the browser can read"
    assert "</script>" not in match.group(1), "payload can close its own script tag"
    embedded = json.loads(match.group(1))
    assert embedded == sidecar, "the page and drivers.json disagree"


def test_page_lists_every_driver_without_javascript(rendered: Path) -> None:
    """Search engines and reader modes never run the filter."""
    html = (rendered / "index.html").read_text(encoding="utf-8")
    noscript = html[html.index("<noscript>"):html.index("</noscript>")]
    for driver_id in sorted(manifest_ids()):
        assert driver_id in noscript, f"{driver_id} is missing from the noscript list"
