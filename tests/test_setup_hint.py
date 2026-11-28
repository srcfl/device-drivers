"""setup_hint: what a new owner switches on in the device before FTW can reach it.

A novice adds an inverter, FTW cannot read it, and nothing says that Modbus TCP
is off in the inverter (FTW onboarding review, 27 November 2026). A driver may
now say so in its DRIVER table, in one plain sentence of the device's own menu
words. FTW shows it on the device card and when a connection test fails.

Core reads the hint from two places: the DRIVER table of a bundled copy, and
the generated header of a signed copy. It reads both with one pattern
(go/internal/drivers/catalog.go, driverBlockRe and pickString) that stops at
the first double quote. These tests hold the hint to what that pattern can
read, and check that the signed header carries it.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from ftw_repository import _load_channel  # noqa: E402
from manifest_parser import SETUP_HINT_MAX_CHARS, setup_hint  # noqa: E402
from validate_manifest import validate_manifest  # noqa: E402

LUA_DIR = ROOT / "drivers" / "lua"
DRIVERS = sorted(p.stem for p in (ROOT / "manifests").glob("*.yaml"))

# Core's own patterns, copied from go/internal/drivers/catalog.go.
CORE_BLOCK = re.compile(r"^[ \t]*DRIVER\s*=\s*\{(.*?)\n\}", re.M | re.S)
CORE_ALIAS = re.compile(r"^\s*DRIVER\s*=\s*([A-Za-z_][A-Za-z0-9_]*)\s*$", re.M)
CORE_PICK = re.compile(r'^\s*setup_hint\s*=\s*"([^"]*)"', re.M)

# The drivers this change gave a hint, each from the vendor's document or the
# driver's own notes (see the pull request). Losing one is a regression.
HINTED = {
    "abb_terra", "alfen", "ctek", "ctek_hybrid", "ctek_v2", "esphome_dsmr",
    "etrel", "fronius", "goe", "goe_http", "goodwe", "huawei", "keba",
    "kostal", "mennekes", "nibe_local", "remne_p1ib", "sma", "sma_pv",
    "solis", "sungrow", "victron", "zap",
}


def core_reads(text: str) -> str:
    """The setup_hint Core reads from a file, the way extractDriverBlock does:
    the last DRIVER assignment wins, and an alias names a local table."""
    inline = list(CORE_BLOCK.finditer(text))
    alias = list(CORE_ALIAS.finditer(text))
    block = inline[-1].group(1) if inline else ""
    if alias and (not inline or alias[-1].start() > inline[-1].start()):
        name = re.escape(alias[-1].group(1))
        match = re.search(rf"local\s+{name}\s*=\s*\{{(.*?)\n\}}", text, re.S)
        block = match.group(1) if match else ""
    found = CORE_PICK.search(block)
    return found.group(1) if found else ""


def driver(body: str) -> str:
    return f'DRIVER = {{\n  id = "x",\n{body}\n}}\n\nPROTOCOL = "modbus"\n'


@pytest.mark.parametrize("driver_id", DRIVERS)
def test_every_declared_hint_is_one_core_can_read(driver_id: str) -> None:
    source = (LUA_DIR / f"{driver_id}.lua").read_text(encoding="utf-8")
    hint, problem = setup_hint(source)
    assert not problem, f"{driver_id}: {problem}"
    assert core_reads(source) == hint


def test_the_hinted_drivers_keep_their_hint() -> None:
    have = {d for d in DRIVERS
            if setup_hint((LUA_DIR / f"{d}.lua").read_text(encoding="utf-8"))[0]}
    assert HINTED <= have, f"lost a setup_hint: {sorted(HINTED - have)}"


@pytest.mark.parametrize(
    ("body", "hint"),
    [
        ("", ""),
        ('  setup_hint = "Turn on Modbus TCP.",', "Turn on Modbus TCP."),
        ('  setup_hint   = "Open the meter\'s port.", -- grid company',
         "Open the meter's port."),
        ('  -- setup_hint = "Old words.",', ""),
    ],
)
def test_a_valid_hint_or_none(body: str, hint: str) -> None:
    assert setup_hint(driver(body)) == (hint, "")


@pytest.mark.parametrize(
    ("body", "problem"),
    [
        ('  setup_hint = "' + "a" * SETUP_HINT_MAX_CHARS + '.",', "characters"),
        ("  setup_hint = 'Turn on Modbus TCP.',", "double-quoted"),
        ('  setup_hint = "Set \\"Modbus\\" on.",', "double-quoted"),
        ('  setup_hint = "Turn on " .. "Modbus TCP.",', "double-quoted"),
        ("  setup_hint = [[Turn on Modbus TCP.]],", "double-quoted"),
        ("  setup_hint = true,", "double-quoted"),
        ('  setup_hint = "Turn on Modbus TCP",', "full stop"),
        ('  setup_hint = "",', "empty"),
        ('  setup_hint = " Turn on Modbus TCP.",', "stray spaces"),
        ('  setup_hint = "Turn on.",\n  setup_hint = "Turn off.",', "more than once"),
    ],
)
def test_a_hint_core_would_misread_is_refused(body: str, problem: str) -> None:
    hint, reason = setup_hint(driver(body))
    assert hint == ""
    assert problem in reason


def test_a_hint_outside_the_driver_table_is_refused() -> None:
    _, reason = setup_hint('setup_hint = "Turn on Modbus TCP."\nPROTOCOL = "modbus"\n')
    assert "DRIVER table" in reason


def test_the_validator_reports_a_bad_hint(tmp_path: Path) -> None:
    drivers = tmp_path / "lua"
    drivers.mkdir()
    (drivers / "huawei.lua").write_text(
        driver('  setup_hint = "' + "a" * 150 + '.",'), encoding="utf-8")
    errors = validate_manifest(ROOT / "manifests" / "huawei.yaml", drivers)
    assert any("setup_hint is 151 characters" in e for e in errors), errors


def one_driver_channel(tmp_path: Path, driver_id: str) -> dict:
    repo = tmp_path / "repo"
    (repo / "drivers" / "lua").mkdir(parents=True)
    (repo / "manifests").mkdir()
    for sub, suffix in (("drivers/lua", ".lua"), ("manifests", ".yaml")):
        (repo / sub / f"{driver_id}{suffix}").write_bytes(
            (ROOT / sub / f"{driver_id}{suffix}").read_bytes())
    config = repo / "ftw-channel.json"
    config.write_text(json.dumps(
        {"schema_version": 1, "include_all": True, "release_mode": "per_driver"}))
    return _load_channel(config, repo)[0]


@pytest.mark.parametrize("driver_id", ["huawei", "keba", "zap"])
def test_the_signed_header_carries_the_hint(tmp_path: Path, driver_id: str) -> None:
    # Core reads only this header from a signed copy, never the source's
    # own DRIVER table further down.
    source = (LUA_DIR / f"{driver_id}.lua").read_text(encoding="utf-8")
    hint, _ = setup_hint(source)
    assert hint

    entry = one_driver_channel(tmp_path, driver_id)
    artifact = entry["raw"].decode("utf-8")
    header = artifact.split("DRIVER = __sourceful_ftw_metadata", 1)[0]

    assert entry["metadata"]["setup_hint"] == hint
    assert f"    setup_hint = {json.dumps(hint, ensure_ascii=False)}," in header
    assert core_reads(artifact) == hint


def test_a_driver_without_a_hint_keeps_its_header(tmp_path: Path) -> None:
    # Published versions must not change bytes, so a driver that declares no
    # hint gets no new field.
    entry = one_driver_channel(tmp_path, "myuplink")
    assert "setup_hint" not in entry["metadata"]
    assert "setup_hint" not in entry["raw"].decode("utf-8")
