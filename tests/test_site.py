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
from ftw_repository import _load_channel  # noqa: E402
from manifest_parser import parse_upstream_docs, parse_yaml_simple  # noqa: E402


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


def test_upstream_docs_reach_the_page(catalog: dict) -> None:
    """A recorded source document is only useful if a reader can open it.

    The manifest field exists so the register map a driver follows can be
    found again. Collecting it and not rendering it would leave the page
    exactly as silent about provenance as it was before the field existed.
    """
    for driver in catalog["drivers"]:
        declared = parse_upstream_docs(
            (ROOT / "manifests" / f"{driver['id']}.yaml").read_text(encoding="utf-8"))
        assert [doc["url"] for doc in driver["upstream_docs"]] == \
            [doc["url"] for doc in declared], driver["id"]

    total = sum(len(d["upstream_docs"]) for d in catalog["drivers"])
    assert total, "no manifest's upstream_docs reached the page"


def test_every_document_label_has_wording(catalog: dict) -> None:
    """An unmapped kind or stability would reach the page as a bare enum."""
    for driver in catalog["drivers"]:
        for doc in driver["upstream_docs"]:
            assert doc["kind"] in generate_site.DOC_KIND_LABELS, (
                f"{driver['id']}: doc kind {doc['kind']!r} has no wording")
            assert doc["url_stability"] in generate_site.URL_STABILITY_LABELS, (
                f"{driver['id']}: url_stability {doc['url_stability']!r} "
                "has no wording")


def test_the_card_renders_the_documents_it_collects() -> None:
    """Guard the rendering, not just the data behind it.

    `test_upstream_docs_reach_the_page` passes just as well when the payload
    carries the documents and the card silently drops them — which is the
    state this test was written to end.
    """
    script = generate_site.SCRIPT
    card = script[script.index("function driverCard"):
                  script.index("function manufacturerView")]
    assert "upstreamDocs(d)" in card, "the driver card no longer renders the documents"
    assert "doc.url" in script and "doc.title" in script


def test_a_document_url_must_be_http() -> None:
    """The page turns this value into an href a reader clicks.

    `validate_manifest.py` holds the same line, but it is a different tool run
    at a different time, and a javascript: URL reaching the rendered card
    would be this generator's bug to have prevented.
    """
    manifest = (
        'upstream_docs:\n'
        '  - url: "javascript:alert(1)"\n'
        '    title: "not a document"\n'
        '  - url: "https://example.invalid/registers.pdf"\n'
        '    title: "a real one"\n'
        'min_host_version: "2.0.0"\n'
    )
    kept = generate_site.upstream_documents(manifest)
    assert [doc["url"] for doc in kept] == ["https://example.invalid/registers.pdf"]


def test_a_document_without_a_title_still_reads_as_a_link(catalog: dict) -> None:
    """`title` is optional in the manifest; an empty link label is not."""
    kept = generate_site.upstream_documents(
        'upstream_docs:\n  - url: "https://example.invalid/map.pdf"\n')
    assert kept[0]["title"] == "https://example.invalid/map.pdf"
    for driver in catalog["drivers"]:
        for doc in driver["upstream_docs"]:
            assert doc["title"].strip(), driver["id"]


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


def test_control_is_what_the_signed_channel_publishes(catalog: dict) -> None:
    """The page says a driver controls only when the channel ships it so.

    A Zaptec Go owner read nothing that said FTW would only watch the charger.
    The manifest's control field had drifted from the code before, so the page
    takes the answer from the same rule the channel build uses.
    """
    published = {
        entry["id"]: entry["controls"]
        for entry in _load_channel(ROOT / "ftw-channel.json", ROOT)
    }
    for driver in catalog["drivers"]:
        assert driver["control"] is published[driver["id"]], driver["id"]
        assert (driver["control_state"] == "controls") is driver["control"], driver["id"]


def test_every_driver_says_what_ftw_can_do(catalog: dict) -> None:
    """One of three answers, each in words, for every driver."""
    for driver in catalog["drivers"]:
        state = driver["control_state"]
        assert state in generate_site.CONTROL_STATES, driver["id"]
        assert driver["control_label"] == generate_site.CONTROL_STATES[state]
        assert driver["control_note"].strip(), driver["id"]
        if state == "telemetry":
            # Only a meter or PV driver may be quietly read-only.
            assert driver["ders"], driver["id"]
            assert set(driver["ders"]) <= generate_site.TELEMETRY_DERS, driver["id"]
        if state == "reads_only":
            assert "cannot control" in driver["control_note"], driver["id"]
        if state == "controls" and not driver["hardware_verified"]:
            assert "Experimental" in driver["control_note"], driver["id"]
        if state != "reads_only":
            assert not driver["control_reason"], driver["id"]


def test_a_read_only_charger_says_why(catalog: dict) -> None:
    """A charger FTW cannot steer says so, with the driver's own reason.

    zaptec_cloud started this: it read the charger and never said why it did
    not control. It controls now, as an experiment until a field report, and
    tesla_wall_connector is the charger that cannot, because Tesla offers no
    way to set its current.
    """
    by_id = {d["id"]: d for d in catalog["drivers"]}
    zaptec = by_id["zaptec_cloud"]
    assert zaptec["control_state"] == "controls"
    assert "Experimental" in zaptec["control_note"]
    wall = by_id["tesla_wall_connector"]
    assert wall["control_state"] == "reads_only"
    assert "turns its control off" in wall["control_note"]
    assert "Tesla offers no way" in wall["control_reason"]
    assert len(wall["control_reason"]) <= generate_site.MAX_REASON_CHARS + 1


def test_a_product_description_is_not_a_reason() -> None:
    """Text that never mentions reading or control is left out."""
    assert generate_site.read_only_reason(
        "Zaptec Go / Go 2 / Pro via Zaptec Cloud.", ["Community driver, untested"],
        ["Wallbox Commander 2 EV Charger Driver", "Emits: V2X Charger (READ-ONLY)"]) == ""
    assert generate_site.read_only_reason(
        "Huawei SUN2000 via Modbus TCP. Read-only until a held-zero command is verified.",
        [], []) == "Read-only until a held-zero command is verified."


def test_the_card_and_device_view_render_the_control_state() -> None:
    """Guard the rendering, as for the documents."""
    script = generate_site.SCRIPT
    card = script[script.index("function driverCard"):
                  script.index("function manufacturerView")]
    assert "d.control_label" in card and "d.control_note" in card
    assert "d.control_reason" in card and "controlNote +" in card
    devices = script[script.index("function manufacturerView"):
                     script.index("function render()")]
    assert "row.driver.control_label" in devices


def test_page_says_what_ftw_can_do_without_javascript(rendered: Path, catalog: dict) -> None:
    html = (rendered / "index.html").read_text(encoding="utf-8")
    noscript = html[html.index("<noscript>"):html.index("</noscript>")]
    for driver in catalog["drivers"]:
        row = re.search(rf"<li><b>{re.escape(driver['id'])}</b>[^<]*</li>", noscript)
        assert row, driver["id"]
        assert driver["control_label"].lower() in row.group(0), driver["id"]
