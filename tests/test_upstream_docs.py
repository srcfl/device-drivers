"""upstream_docs: the vendor documents a driver is watched against.

A driver decodes a device by following the vendor's own register map or
changelog. When that document moves upstream, the driver can fall behind
without anything noticing. `upstream_docs` records those documents at a
semi-persistent URL so a watcher can poll them and flag the driver for review.

These tests hold the field to its contract and check that the two NIBE drivers
actually declare the changelog they were built against.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from manifest_parser import parse_tested_devices, parse_upstream_docs  # noqa: E402
from validate_manifest import validate_manifest  # noqa: E402

MANIFEST_DIR = ROOT / "manifests"
NIBE_CHANGELOG = "https://www.nibe.eu/webdav/files/myuplink_changelog/nibe-n.pdf"
NIBE_IDS = ["nibe_local", "myuplink"]


# ---- Parser -------------------------------------------------------------


def test_absent_block_parses_as_empty():
    assert parse_upstream_docs("name: x\nversion: 1.0.0\n") == []


def test_empty_inline_list_parses_as_empty():
    assert parse_upstream_docs("upstream_docs: []\nmin_host_version: 2.0.0\n") == []


def test_block_parses_url_title_kind():
    text = (
        "tested_devices:\n"
        '  - manufacturer: "NIBE"\n'
        '    model_family: "S"\n'
        "upstream_docs:\n"
        '  - url: "https://example.com/a.pdf"\n'
        '    title: "A"\n'
        "    kind: changelog\n"
        '  - url: "https://example.com/b.pdf"\n'
        "    kind: register_map\n"
        'min_host_version: "2.0.0"\n'
    )
    assert parse_upstream_docs(text) == [
        {"url": "https://example.com/a.pdf", "title": "A", "kind": "changelog"},
        {"url": "https://example.com/b.pdf", "kind": "register_map"},
    ]


def test_block_does_not_bleed_into_tested_devices():
    """The two adjacent blocks must not consume each other's lines."""
    text = (
        "tested_devices:\n"
        '  - manufacturer: "NIBE"\n'
        '    model_family: "S"\n'
        "upstream_docs:\n"
        '  - url: "https://example.com/a.pdf"\n'
        '    title: "A"\n'
        'min_host_version: "2.0.0"\n'
    )
    assert parse_tested_devices(text) == [{"manufacturer": "NIBE", "model_family": "S"}]
    assert parse_upstream_docs(text) == [
        {"url": "https://example.com/a.pdf", "title": "A"}
    ]


# ---- Validation ---------------------------------------------------------


def _errors_for(tmp_path: Path, upstream_block: str) -> list[str]:
    body = (
        'name: "nibe_local"\n'
        'version: "1.0.0"\n'
        "tier: community\n"
        "protocol: http\n"
        "ders: [meter]\n"
        "size_bytes: 1\n"
        f"{upstream_block}"
    )
    path = tmp_path / "nibe_local.yaml"
    path.write_text(body, encoding="utf-8")
    return validate_manifest(path, tmp_path / "nonexistent")


def test_url_is_required(tmp_path):
    errors = _errors_for(tmp_path, 'upstream_docs:\n  - title: "no url"\n')
    assert any("upstream_docs[0]: missing required field 'url'" in e for e in errors)


def test_non_http_url_is_rejected(tmp_path):
    errors = _errors_for(tmp_path, 'upstream_docs:\n  - url: "ftp://example.com/a.pdf"\n')
    assert any("upstream_docs[0]: url must be an http(s) URL" in e for e in errors)


def test_unknown_kind_is_rejected(tmp_path):
    errors = _errors_for(
        tmp_path, 'upstream_docs:\n  - url: "https://x/a.pdf"\n    kind: bogus\n'
    )
    assert any("upstream_docs[0]: kind 'bogus' is not valid" in e for e in errors)


def test_unknown_field_is_rejected(tmp_path):
    errors = _errors_for(
        tmp_path, 'upstream_docs:\n  - url: "https://x/a.pdf"\n    foo: bar\n'
    )
    assert any("upstream_docs[0]: unknown field 'foo'" in e for e in errors)


def test_wellformed_entry_raises_no_upstream_error(tmp_path):
    errors = _errors_for(
        tmp_path,
        'upstream_docs:\n  - url: "https://x/a.pdf"\n    title: "A"\n    kind: changelog\n',
    )
    assert not [e for e in errors if e.startswith("upstream_docs")]


# ---- The shipped manifests ---------------------------------------------


@pytest.mark.parametrize("driver_id", NIBE_IDS)
def test_nibe_drivers_watch_the_changelog(driver_id):
    text = (MANIFEST_DIR / f"{driver_id}.yaml").read_text(encoding="utf-8")
    docs = parse_upstream_docs(text)
    assert docs, f"{driver_id} declares no upstream_docs"
    assert NIBE_CHANGELOG in [d.get("url") for d in docs]
    assert all(d.get("kind") == "changelog" for d in docs)


def test_every_declared_upstream_doc_is_wellformed():
    for path in sorted(MANIFEST_DIR.glob("*.yaml")):
        for i, doc in enumerate(parse_upstream_docs(path.read_text(encoding="utf-8"))):
            url = doc.get("url", "")
            assert url.startswith(("http://", "https://")), f"{path.name}[{i}]: bad url"
            assert set(doc) <= {"url", "title", "kind"}, f"{path.name}[{i}]: unknown field"
