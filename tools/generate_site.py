#!/usr/bin/env python3
"""Generate the public driver catalog site from the repository's own data.

Everything on the page is derived here, never typed by hand: the manifests are
the source for versions, tiers, protocols and tested devices; the Lua sources
supply the driver's own description, homepage and field-verification record;
support-status.json supplies per-target state and driver-history.json supplies
the published version history.

Nothing is written back into the repository. The site is a rendering of the
repository at one commit, built in CI and deployed to GitHub Pages, so a page
that disagrees with `main` cannot exist.

Usage:
    uv run python tools/generate_site.py --output site
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from manifest_parser import parse_tested_devices, parse_yaml_simple

ROOT = Path(__file__).resolve().parents[1]
REPO_URL = "https://github.com/srcfl/device-drivers"

# What a DER label means to somebody who has not read the contracts. The page
# is the first thing a new reader sees, so it spells the vocabulary out.
DER_LABELS = {
    "battery": "Battery",
    "ev": "EV charger",
    "heatpump": "Heat pump",
    "meter": "Meter",
    "pv": "Solar PV",
    "v2x_charger": "V2X charger",
    "vehicle": "Vehicle",
}
PROTOCOL_LABELS = {
    "modbus": "Modbus",
    "mqtt": "MQTT",
    "http": "HTTP",
    "serial": "Serial",
    "": "Unspecified",
}
TIER_LABELS = {
    "core": "Core",
    "community": "Community",
    "oem": "OEM",
}
# A driver's own verification_status is the only hardware claim on the page, so
# it is never flattened into a single "verified" mark. Most drivers are ported
# from a reference implementation and say so; the page has to say so too.
VERIFICATION = {
    "production": ("Running in production", "confirmed"),
    "tested": ("Verified on hardware", "confirmed"),
    "beta": ("Partly verified", "partial"),
    "alpha": ("Early verification", "partial"),
    "experimental": ("Not verified on hardware", "unverified"),
}
HARDWARE_VERIFIED = {"production", "tested"}
MAX_SOURCE_NOTE_LINES = 12


def git_output(*args: str) -> str:
    """Read a value from git, returning "" when git cannot answer."""
    try:
        result = subprocess.run(
            ["git", *args], cwd=ROOT, capture_output=True, text=True, check=True)
    except (OSError, subprocess.CalledProcessError):
        return ""
    return result.stdout.strip()


def lua_string(body: str, key: str) -> str:
    """Read a `key = "value"` field out of a Lua table body."""
    match = re.search(
        rf'^\s*{key}\s*=\s*"((?:[^"\\]|\\.)*)"', body, re.MULTILINE)
    if not match:
        return ""
    return match.group(1).replace('\\"', '"').replace("\\\\", "\\")


def lua_string_list(body: str, key: str) -> list[str]:
    """Read a `key = { "a", "b" }` field out of a Lua table body."""
    match = re.search(rf'^\s*{key}\s*=\s*\{{(.*?)\}}', body, re.MULTILINE | re.DOTALL)
    if not match:
        return []
    return re.findall(r'"((?:[^"\\]|\\.)*)"', match.group(1))


def header_comment(text: str) -> list[str]:
    """Return the leading `--` comment block, dashes removed, indent kept."""
    lines: list[str] = []
    for raw in text.splitlines():
        match = re.match(r"^\s*--(.*)$", raw.rstrip())
        if match:
            body = match.group(1)
            lines.append(body[1:] if body.startswith(" ") else body)
            continue
        if not raw.strip():
            if lines:
                break
            continue
        break
    while lines and not lines[-1].strip():
        lines.pop()
    return lines


def clean_headline(line: str, driver_id: str) -> str:
    """Turn a header comment's first line into a title.

    The comments were written for someone reading the file, so they carry a
    filename, a trailing "Driver" and sometimes a "(community, untested)" aside
    that the tier and verification fields already state properly.
    """
    line = re.sub(rf"^{re.escape(driver_id)}\.lua\s*[–—:-]*\s*", "",
                  line.strip(), flags=re.IGNORECASE)
    line = re.sub(r"\s*\((?:community|untested|experimental|beta|alpha)[^)]*\)\s*$",
                  "", line, flags=re.IGNORECASE)
    line = re.sub(r"\s+(?:Lua\s+)?Driver$", "", line, flags=re.IGNORECASE)
    return line.strip()


def read_driver_source(path: Path) -> dict:
    """Pull the driver's self-description out of its Lua source.

    38 of the drivers carry a `DRIVER = { ... }` table with a description,
    homepage and verification record. The other 42 describe themselves in the
    header comment only, so that comment supplies the title and, quoted
    verbatim, the summary. Both are the driver's own words; neither is restated
    in a second place that could drift from the code.
    """
    if not path.exists():
        return {}
    text = path.read_text(encoding="utf-8")
    info: dict = {}

    table = re.search(r'^DRIVER\s*=\s*\{(.*?)^\}', text, re.MULTILINE | re.DOTALL)
    if table:
        body = table.group(1)
        for key in ("name", "manufacturer", "description", "homepage"):
            value = lua_string(body, key)
            if value:
                info[key] = value
        status = lua_string(body, "verification_status")
        if status:
            info["verification"] = {
                "status": status,
                "at": lua_string(body, "verified_at"),
                "notes": lua_string(body, "verification_notes"),
            }

    comment = header_comment(text)
    if "name" not in info:
        for index, line in enumerate(comment):
            headline = clean_headline(line, path.stem)
            if headline:
                info["name"] = headline
                comment = comment[index + 1:]
                break
    if "description" not in info and comment:
        note = comment[:MAX_SOURCE_NOTE_LINES]
        while note and not note[0].strip():
            note.pop(0)
        while note and not note[-1].strip():
            note.pop()
        if note:
            info["source_note"] = "\n".join(note)
    return info


def collect_drivers() -> list[dict]:
    """Build one record per driver from the manifest, the source and the status."""
    support = json.loads(
        (ROOT / "support-status.json").read_text(encoding="utf-8"))
    status_by_driver = {
        entry["driver_id"]: entry for entry in support.get("drivers", [])
    }
    history = json.loads(
        (ROOT / "driver-history.json").read_text(encoding="utf-8"))
    history_by_driver = history.get("drivers", {})

    drivers = []
    for manifest_path in sorted((ROOT / "manifests").glob("*.yaml")):
        text = manifest_path.read_text(encoding="utf-8")
        data = parse_yaml_simple(text)
        driver_id = data.get("name", manifest_path.stem)
        source = read_driver_source(ROOT / "drivers" / "lua" / f"{driver_id}.lua")

        tested = []
        for device in parse_tested_devices(text):
            tested.append({
                "manufacturer": device.get("manufacturer", "Unknown"),
                "model_family": device.get(
                    "model_family", device.get("model", "Unknown")),
                "variants": device.get("variants", []) or [],
                "regions": device.get("regions", []) or [],
                "firmware_versions": device.get("firmware_versions", ""),
                "notes": device.get("notes", ""),
                "min_driver_version": device.get("min_driver_version", ""),
            })

        manufacturers = []
        for name in [source.get("manufacturer", "")] + [d["manufacturer"] for d in tested]:
            if name and name not in manufacturers:
                manufacturers.append(name)

        targets = status_by_driver.get(driver_id, {}).get("targets", {})
        releases = history_by_driver.get(driver_id, [])

        verification = source.get("verification")
        if verification:
            label, level = VERIFICATION.get(
                verification["status"], (verification["status"], "partial"))
            verification["label"] = label
            verification["level"] = level

        drivers.append({
            "id": driver_id,
            "title": source.get("name", "") or driver_id,
            "description": source.get("description", ""),
            "source_note": source.get("source_note", ""),
            "homepage": source.get("homepage", ""),
            "manufacturers": manufacturers,
            "version": data.get("version", ""),
            "tier": data.get("tier", "community"),
            "protocol": data.get("protocol", ""),
            "ders": data.get("ders", []) or [],
            "control": bool(data.get("control", False)),
            "author": data.get("author", ""),
            "min_host_version": data.get("min_host_version", ""),
            "size_bytes": data.get("size_bytes", 0),
            "sha256": data.get("sha256", ""),
            "tested_devices": tested,
            "verification": verification,
            "hardware_verified": bool(
                verification and verification["status"] in HARDWARE_VERIFIED),
            "targets": {
                name: {
                    "conformance": target.get("target_conformance", "not_assessed"),
                    "hil": target.get("hil", "not_recorded"),
                    "control_enabled": bool(target.get("control_enabled", False)),
                    "stable": target.get("stable_package_version"),
                    "beta": target.get("historical_signed_beta_version"),
                    "note": target.get("note", ""),
                }
                for name, target in sorted(targets.items())
            },
            "releases": [
                {"version": r.get("version", ""), "date": (r.get("date", "") or "")[:10]}
                for r in releases
            ],
            "source_url": f"{REPO_URL}/blob/main/drivers/lua/{driver_id}.lua",
            "manifest_url": f"{REPO_URL}/blob/main/manifests/{driver_id}.yaml",
        })
    return drivers


def build_catalog() -> dict:
    """Assemble the whole payload the page renders, plus its provenance."""
    drivers = collect_drivers()

    families: set[tuple[str, str]] = set()
    manufacturers: set[str] = set()
    variants = 0
    for driver in drivers:
        manufacturers.update(driver["manufacturers"])
        for device in driver["tested_devices"]:
            families.add((device["manufacturer"], device["model_family"]))
            variants += len(device["variants"])

    commit = git_output("rev-parse", "HEAD")
    return {
        "drivers": drivers,
        "labels": {
            "ders": DER_LABELS,
            "protocols": PROTOCOL_LABELS,
            "tiers": TIER_LABELS,
        },
        "totals": {
            "drivers": len(drivers),
            "manufacturers": len(manufacturers),
            "model_families": len(families),
            "variants": variants,
            "control": sum(1 for d in drivers if d["control"]),
            "hardware_verified": sum(1 for d in drivers if d["hardware_verified"]),
        },
        "source": {
            "repository": REPO_URL,
            "commit": commit,
            "commit_short": commit[:7],
            "commit_date": git_output("log", "-1", "--format=%cs"),
        },
    }


def embed_json(payload: dict) -> str:
    """Serialise for a <script> block without letting a string close the tag."""
    return (json.dumps(payload, indent=1, sort_keys=True)
            .replace("<", "\\u003c").replace(">", "\\u003e")
            .replace("&", "\\u0026"))


STYLE = """
:root {
  --paper: #fafaf7;
  --cream: #f5f2e1;
  --ink: #0a0a0a;
  --body: #171717;
  --muted: #676762;
  --line: #d9d8d1;
  --line-dark: rgba(245, 242, 225, 0.18);
  --signal: #e85d1f;
  --signal-light: #fff0e8;
  --surface: #ffffff;
  --confirmed: #53c878;
  --max: 1320px;
  --mono: "JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, monospace;
}
* { box-sizing: border-box; }
/* .table-head sets display:grid, which outranks the user-agent rule for
   [hidden]. Without this the column header survives into the device view. */
[hidden] { display: none !important; }
body {
  margin: 0;
  background: var(--paper);
  color: var(--body);
  font-family: "Satoshi", ui-sans-serif, system-ui, -apple-system, sans-serif;
  font-size: 16px;
  line-height: 1.55;
  -webkit-font-smoothing: antialiased;
}
a { color: inherit; }
h1, h2, h3, p { margin-top: 0; }
.wrap { width: min(var(--max), calc(100% - 48px)); margin-inline: auto; }
.mono, .kicker, .chip, .badge, code, .stat dt, .nav-links, .brand-name {
  font-family: var(--mono);
}
.skip-link { position: fixed; left: 16px; top: -100px; z-index: 100; padding: 12px 16px; background: var(--signal); color: var(--ink); }
.skip-link:focus { top: 16px; }

.site-header { position: sticky; top: 0; z-index: 30; background: var(--ink); color: var(--cream); border-bottom: 1px solid var(--line-dark); }
.nav { min-height: 64px; display: flex; align-items: center; justify-content: space-between; gap: 24px; flex-wrap: wrap; }
.brand { display: flex; align-items: baseline; gap: 10px; text-decoration: none; }
.brand-name { color: var(--signal); font-size: 19px; font-weight: 700; letter-spacing: -0.02em; }
.brand small { color: var(--cream); opacity: 0.6; font-size: 11px; letter-spacing: 0.12em; text-transform: uppercase; }
.nav-links { display: flex; align-items: center; gap: 14px 22px; flex-wrap: wrap; padding: 8px 0; font-size: 10px; font-weight: 500; letter-spacing: 0.12em; text-transform: uppercase; }
.nav-links a { color: var(--cream); text-decoration: none; opacity: 0.68; }
.nav-links a:hover, .nav-links a:focus-visible { opacity: 1; }
.nav-links .nav-cta { display: inline-flex; align-items: center; gap: 8px; min-height: 34px; padding: 0 13px; background: var(--signal); color: var(--ink); opacity: 1; font-weight: 700; }
a:focus-visible, button:focus-visible, input:focus-visible { outline: 2px solid var(--signal); outline-offset: 3px; }

.hero { background: var(--cream); border-bottom: 1px solid var(--line); padding-block: 56px 44px; }
.kicker { display: flex; align-items: center; gap: 10px; margin: 0 0 22px; color: var(--muted); font-size: 10px; font-weight: 500; letter-spacing: 0.13em; text-transform: uppercase; }
.kicker .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--signal); }
h1 { max-width: 16ch; margin-bottom: 22px; color: var(--ink); font-size: clamp(2.9rem, 6vw, 5.2rem); font-weight: 900; line-height: 0.94; letter-spacing: -0.05em; text-wrap: balance; }
h1 em { color: var(--signal); font-style: normal; }
.lede { max-width: 68ch; margin-bottom: 0; color: var(--muted); font-size: clamp(17px, 1.4vw, 20px); line-height: 1.45; text-wrap: pretty; }
.stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); max-width: 980px; margin: 40px 0 0; padding-top: 20px; border-top: 1px solid var(--line); }
.stats div { display: flex; flex-direction: column; padding-right: 14px; border-right: 1px solid var(--line); }
.stats dd { margin-top: auto; }
.stats div + div { padding-left: 18px; }
.stats div:last-child { border-right: 0; }
.stats dt { margin-bottom: 4px; color: var(--muted); font-size: 9px; letter-spacing: 0.13em; text-transform: uppercase; }
.stats dd { color: var(--ink); font-size: 26px; font-weight: 700; letter-spacing: -0.03em; }

.controls { position: sticky; top: 64px; z-index: 20; background: var(--paper); border-bottom: 1px solid var(--line); padding-block: 16px; }
.controls-row { display: flex; align-items: center; gap: 14px; flex-wrap: wrap; }
.search { flex: 1 1 280px; display: flex; align-items: center; gap: 10px; min-height: 46px; padding: 0 14px; background: var(--surface); border: 1px solid var(--line); }
.search input { flex: 1; border: 0; background: transparent; color: var(--body); font: inherit; }
.search input:focus { outline: 0; }
.search .hint { color: var(--muted); font-family: var(--mono); font-size: 11px; white-space: nowrap; }
.view-toggle { display: flex; border: 1px solid var(--ink); }
.view-toggle button { min-height: 46px; padding: 0 18px; border: 0; background: transparent; color: var(--ink); font-family: var(--mono); font-size: 11px; letter-spacing: 0.1em; text-transform: uppercase; cursor: pointer; }
.view-toggle button[aria-pressed="true"] { background: var(--ink); color: var(--cream); }
.filters { display: flex; gap: 22px; flex-wrap: wrap; margin-top: 14px; }
.filter-group { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.filter-group > span { color: var(--muted); font-family: var(--mono); font-size: 9px; letter-spacing: 0.13em; text-transform: uppercase; }
.chip { min-height: 30px; padding: 0 11px; border: 1px solid var(--line); background: var(--surface); color: var(--muted); font-size: 11px; cursor: pointer; }
.chip:hover { border-color: var(--ink); color: var(--ink); }
.chip[aria-pressed="true"] { border-color: var(--signal); background: var(--signal); color: var(--ink); font-weight: 700; }
.result-line { margin-top: 14px; color: var(--muted); font-family: var(--mono); font-size: 11px; letter-spacing: 0.06em; }
.result-line button { padding: 0; border: 0; background: 0; color: var(--signal); font: inherit; text-decoration: underline; cursor: pointer; }

main { padding-bottom: 72px; }
.catalog-body { padding-top: 30px; }
.driver { border: 1px solid var(--line); background: var(--surface); margin-bottom: -1px; }
.driver.is-open { border-color: var(--ink); position: relative; z-index: 1; }
.driver-head { width: 100%; display: grid; grid-template-columns: minmax(0, 3fr) 90px minmax(0, 1.6fr) 76px 92px 74px 22px; align-items: center; gap: 14px; padding: 15px 18px; border: 0; background: transparent; color: inherit; font: inherit; text-align: left; cursor: pointer; }
.driver-head:hover { background: var(--signal-light); }
.driver-id { display: block; color: var(--ink); font-family: var(--mono); font-size: 14px; font-weight: 700; }
.driver-title { display: block; margin-top: 2px; color: var(--muted); font-size: 13px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.cell-label { display: none; }
.badge { display: inline-block; padding: 2px 8px; border: 1px solid var(--line); font-size: 10px; letter-spacing: 0.06em; text-transform: uppercase; white-space: nowrap; }
.badge.tier-core { border-color: var(--ink); background: var(--ink); color: var(--cream); }
.badge.control-yes { border-color: var(--signal); color: var(--signal); font-weight: 700; }
.badge.control-no { color: var(--muted); opacity: 0.7; }
.ders { display: flex; gap: 5px; flex-wrap: wrap; }
.ders .badge { border-style: dashed; }
.version { color: var(--ink); font-family: var(--mono); font-size: 12px; }
.caret { color: var(--muted); font-size: 12px; transition: transform 0.15s; }
.driver.is-open .caret { transform: rotate(90deg); }

.driver-body { display: none; min-width: 0; padding: 4px 18px 24px; border-top: 1px solid var(--line); }
.driver.is-open .driver-body { display: block; }
.driver-body p.desc { max-width: 78ch; margin: 18px 0 0; color: var(--body); }
.source-note { max-width: 88ch; margin: 18px 0 0; padding: 12px 14px; border-left: 2px solid var(--line); background: var(--paper); color: var(--muted); font-family: var(--mono); font-size: 12px; line-height: 1.55; white-space: pre-wrap; overflow-x: auto; }
.source-note b { display: block; margin-bottom: 7px; color: var(--muted); font-size: 9px; font-weight: 500; letter-spacing: 0.13em; text-transform: uppercase; }
.verification { max-width: 88ch; margin: 16px 0 0; padding: 9px 13px; border-left: 2px solid var(--muted); background: rgba(103, 103, 98, 0.09); font-size: 13px; }
.verification b { margin-right: 9px; font-family: var(--mono); font-size: 11px; letter-spacing: 0.08em; text-transform: uppercase; }
.verification .when { color: var(--muted); font-family: var(--mono); font-size: 11px; white-space: nowrap; }
.verification.level-confirmed { border-left-color: var(--confirmed); background: rgba(83, 200, 120, 0.14); }
.verification.level-partial { border-left-color: var(--signal); background: var(--signal-light); }
.verification.level-unverified { border-left-color: var(--muted); }
.subhead { margin: 26px 0 10px; color: var(--muted); font-family: var(--mono); font-size: 9px; letter-spacing: 0.13em; text-transform: uppercase; }
/* A model table is wider than a phone. It scrolls inside its own box so it
   never widens the page and pushes every other element off-screen. */
.table-scroll { overflow-x: auto; }
table.models { width: 100%; min-width: 540px; border-collapse: collapse; font-size: 13px; }
table.models th { padding: 7px 10px 7px 0; border-bottom: 1px solid var(--line); color: var(--muted); font-family: var(--mono); font-size: 9px; font-weight: 500; letter-spacing: 0.1em; text-align: left; text-transform: uppercase; }
table.models td { padding: 9px 10px 9px 0; border-bottom: 1px solid var(--line); vertical-align: top; }
table.models tr:last-child td { border-bottom: 0; }
table.models .variants { color: var(--muted); font-family: var(--mono); font-size: 11.5px; }
table.models .note { color: var(--muted); font-size: 12px; }
.facts { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 14px 24px; margin-top: 8px; }
.facts div { min-width: 0; }
.facts dt { color: var(--muted); font-family: var(--mono); font-size: 9px; letter-spacing: 0.1em; text-transform: uppercase; }
.facts dd { margin: 3px 0 0; font-family: var(--mono); font-size: 12px; overflow-wrap: anywhere; }
.links { display: flex; gap: 10px; flex-wrap: wrap; margin-top: 22px; }
.links a { display: inline-flex; align-items: center; gap: 8px; min-height: 38px; padding: 0 14px; border: 1px solid var(--ink); font-size: 13px; text-decoration: none; }
.links a:hover { background: var(--ink); color: var(--cream); }

.mfr { border-top: 1px solid var(--line); padding: 26px 0; }
.mfr:first-child { border-top: 0; }
.mfr h2 { margin-bottom: 14px; font-size: 24px; font-weight: 700; letter-spacing: -0.03em; }
.family { display: grid; grid-template-columns: minmax(0, 1.1fr) minmax(0, 2.2fr) minmax(0, 0.8fr); gap: 14px; padding: 12px 0; border-top: 1px dashed var(--line); }
.family b { font-size: 14px; }
.family .variants { color: var(--muted); font-family: var(--mono); font-size: 11.5px; }
.family .regions { color: var(--muted); font-family: var(--mono); font-size: 10px; letter-spacing: 0.08em; }
.family .driver-link { font-family: var(--mono); font-size: 12px; }
.family .driver-link a { color: var(--signal); }

.empty { padding: 60px 0; color: var(--muted); text-align: center; }
noscript .empty { color: var(--body); }
.table-head { display: grid; grid-template-columns: minmax(0, 3fr) 90px minmax(0, 1.6fr) 76px 92px 74px 22px; gap: 14px; padding: 0 18px 8px; color: var(--muted); font-family: var(--mono); font-size: 9px; letter-spacing: 0.1em; text-transform: uppercase; }

footer { background: var(--ink); color: var(--cream); padding-block: 44px 26px; }
footer h2 { margin-bottom: 10px; font-size: 22px; font-weight: 700; letter-spacing: -0.03em; }
footer p { max-width: 62ch; color: rgba(245, 242, 225, 0.66); }
.footer-main { display: grid; grid-template-columns: minmax(0, 1.4fr) minmax(0, 1fr); gap: 40px; }
.footer-links { display: flex; gap: 40px; flex-wrap: wrap; }
.footer-links > div { display: flex; flex-direction: column; gap: 7px; }
.footer-links span { color: rgba(245, 242, 225, 0.45); font-family: var(--mono); font-size: 9px; letter-spacing: 0.13em; text-transform: uppercase; }
.footer-links a { color: var(--cream); font-size: 14px; text-decoration: none; opacity: 0.8; }
.footer-links a:hover { opacity: 1; text-decoration: underline; }
.footer-bottom { display: flex; justify-content: space-between; gap: 18px; flex-wrap: wrap; margin-top: 34px; padding-top: 18px; border-top: 1px solid var(--line-dark); color: rgba(245, 242, 225, 0.45); font-family: var(--mono); font-size: 11px; }
.footer-bottom a { color: rgba(245, 242, 225, 0.66); }

@media (max-width: 1080px) {
  .driver-head, .table-head { grid-template-columns: minmax(0, 2.4fr) 84px minmax(0, 1.4fr) 70px 74px 22px; }
  .driver-head .cell-host, .table-head .cell-host { display: none; }
}
@media (max-width: 780px) {
  .wrap { width: calc(100% - 32px); }
  .controls { position: static; }
  .table-head { display: none; }
  .driver-head { grid-template-columns: 1fr auto; gap: 8px 12px; }
  .driver-head > * { grid-column: 1; }
  .driver-head .caret { grid-column: 2; grid-row: 1; }
  .driver-head .cell-inline { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
  .family { grid-template-columns: 1fr; gap: 6px; }
  .footer-main { grid-template-columns: 1fr; }
}
@media (prefers-reduced-motion: reduce) { * { transition: none !important; } }
"""


SCRIPT = r"""
(function () {
  var CATALOG = window.__CATALOG__;
  var drivers = CATALOG.drivers;
  var labels = CATALOG.labels;
  var state = { view: "drivers", query: "", ders: new Set(), protocols: new Set(),
                tiers: new Set(), control: false, verified: false };

  var listEl = document.getElementById("list");
  var countEl = document.getElementById("result-count");
  var clearEl = document.getElementById("clear-filters");

  function esc(value) {
    return String(value == null ? "" : value).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }
  function derLabel(d) { return labels.ders[d] || d; }
  function protocolLabel(p) { return labels.protocols[p] || p; }
  function tierLabel(t) { return labels.tiers[t] || t; }
  function bytes(n) { return n >= 1024 ? (n / 1024).toFixed(1) + " kB" : n + " B"; }

  // One flat haystack per driver so a search matches a model number or a
  // manufacturer, not only the driver id.
  drivers.forEach(function (d) {
    var parts = [d.id, d.title, d.description, d.protocol, d.tier, d.author];
    d.ders.forEach(function (x) { parts.push(x, derLabel(x)); });
    d.manufacturers.forEach(function (m) { parts.push(m); });
    d.tested_devices.forEach(function (dev) {
      parts.push(dev.manufacturer, dev.model_family, dev.notes);
      parts.push(dev.variants.join(" "), dev.regions.join(" "));
    });
    d.haystack = parts.join(" ").toLowerCase();
  });

  function matches(d) {
    if (state.query && d.haystack.indexOf(state.query) === -1) return false;
    if (state.control && !d.control) return false;
    if (state.verified && !d.hardware_verified) return false;
    if (state.tiers.size && !state.tiers.has(d.tier)) return false;
    if (state.protocols.size && !state.protocols.has(d.protocol)) return false;
    if (state.ders.size) {
      var hit = d.ders.some(function (x) { return state.ders.has(x); });
      if (!hit) return false;
    }
    return true;
  }

  function modelsTable(d) {
    if (!d.tested_devices.length) return "";
    var rows = d.tested_devices.map(function (dev) {
      var note = dev.notes ? '<div class="note">' + esc(dev.notes) + "</div>" : "";
      var fw = dev.firmware_versions ? '<div class="note">Firmware ' + esc(dev.firmware_versions) + "</div>" : "";
      var min = dev.min_driver_version ? esc(dev.min_driver_version) : "&mdash;";
      return "<tr>" +
        "<td><b>" + esc(dev.manufacturer) + "</b><br>" + esc(dev.model_family) + "</td>" +
        '<td class="variants">' + (dev.variants.length ? esc(dev.variants.join(", ")) : "&mdash;") + "</td>" +
        "<td>" + (dev.regions.length ? esc(dev.regions.join(" ")) : "&mdash;") + "</td>" +
        '<td class="version">' + min + "</td>" +
        "<td>" + note + fw + "</td>" +
        "</tr>";
    }).join("");
    return '<p class="subhead">Models the manifest states as tested</p>' +
      '<div class="table-scroll"><table class="models"><thead><tr><th>Manufacturer / family</th><th>Variants</th>' +
      "<th>Regions</th><th>Min driver</th><th>Notes</th></tr></thead><tbody>" + rows + "</tbody></table></div>";
  }

  function targetsTable(d) {
    var names = Object.keys(d.targets);
    if (!names.length) return "";
    var rows = names.map(function (name) {
      var t = d.targets[name];
      return "<tr><td><b>" + esc(name) + "</b></td>" +
        '<td class="variants">' + esc(t.conformance) + "</td>" +
        '<td class="variants">' + esc(t.hil) + "</td>" +
        '<td class="variants">' + esc(t.stable || "—") + "</td>" +
        '<td class="note">' + esc(t.note) + "</td></tr>";
    }).join("");
    return '<p class="subhead">Per-target status</p>' +
      '<div class="table-scroll"><table class="models"><thead><tr><th>Target</th><th>Conformance</th><th>HIL</th>' +
      "<th>Stable package</th><th>Note</th></tr></thead><tbody>" + rows + "</tbody></table></div>";
  }

  function driverCard(d) {
    var ders = d.ders.map(function (x) { return '<span class="badge">' + esc(derLabel(x)) + "</span>"; }).join("");
    var control = d.control
      ? '<span class="badge control-yes">Control</span>'
      : '<span class="badge control-no">Read only</span>';
    // The driver's own verification_status, rendered as what it actually says.
    // Most drivers are ports awaiting hardware, and the page must not dress
    // that up as a test result.
    var verified = "";
    if (d.verification && d.verification.status) {
      var when = d.verification.at ? '<span class="when">as of ' + esc(d.verification.at) + "</span>" : "";
      verified = '<p class="verification level-' + esc(d.verification.level) + '">' +
        "<b>" + esc(d.verification.label) + "</b>" +
        (d.verification.notes ? esc(d.verification.notes) + " " : "") + when + "</p>";
    }
    var sourceNote = d.source_note
      ? '<div class="source-note"><b>From the driver source</b>' + esc(d.source_note) + "</div>" : "";
    var release = d.releases.length ? d.releases[d.releases.length - 1] : null;

    var facts = [
      ["Tier", esc(tierLabel(d.tier))],
      ["Protocol", esc(protocolLabel(d.protocol))],
      ["Catalog version", esc(d.version)],
      ["Min host", esc(d.min_host_version || "—")],
      ["Source size", bytes(d.size_bytes)],
      ["Maintainer", esc(d.author || "Community")],
      ["First published", release ? esc(release.date) : "—"],
      ["Source sha256", '<span title="' + esc(d.sha256) + '">' + esc(d.sha256.slice(0, 16)) + "…</span>"]
    ].map(function (f) { return "<div><dt>" + f[0] + "</dt><dd>" + f[1] + "</dd></div>"; }).join("");

    var homepage = d.homepage
      ? '<a href="' + esc(d.homepage) + '" rel="noopener">Vendor site <span aria-hidden="true">↗</span></a>' : "";

    return '<article class="driver" id="driver-' + esc(d.id) + '">' +
      '<button class="driver-head" type="button" aria-expanded="false" aria-controls="body-' + esc(d.id) + '">' +
        "<span><span class=\"driver-id\">" + esc(d.id) + '</span><span class="driver-title">' + esc(d.title) + "</span></span>" +
        '<span class="cell-inline"><span class="badge">' + esc(protocolLabel(d.protocol)) + "</span></span>" +
        '<span class="ders cell-inline">' + ders + "</span>" +
        '<span class="cell-inline">' + control + "</span>" +
        '<span class="cell-inline cell-host"><span class="badge tier-' + esc(d.tier) + '">' + esc(tierLabel(d.tier)) + "</span></span>" +
        '<span class="version">v' + esc(d.version) + "</span>" +
        '<span class="caret" aria-hidden="true">❯</span>' +
      "</button>" +
      '<div class="driver-body" id="body-' + esc(d.id) + '">' +
        (d.description ? '<p class="desc">' + esc(d.description) + "</p>" : "") +
        sourceNote +
        verified +
        modelsTable(d) +
        targetsTable(d) +
        '<p class="subhead">Facts</p><dl class="facts">' + facts + "</dl>" +
        '<div class="links">' +
          '<a href="' + esc(d.source_url) + '" rel="noopener">Read the Lua source <span aria-hidden="true">↗</span></a>' +
          '<a href="' + esc(d.manifest_url) + '" rel="noopener">Manifest <span aria-hidden="true">↗</span></a>' +
          homepage +
        "</div>" +
      "</div></article>";
  }

  function manufacturerView(list) {
    var byMfr = {};
    list.forEach(function (d) {
      d.tested_devices.forEach(function (dev) {
        var key = dev.manufacturer;
        (byMfr[key] = byMfr[key] || []).push({ dev: dev, driver: d });
      });
    });
    var names = Object.keys(byMfr).sort(function (a, b) { return a.localeCompare(b); });
    if (!names.length) return '<p class="empty">No manufacturer in the catalog matches that filter.</p>';
    return names.map(function (name) {
      var families = byMfr[name].slice().sort(function (a, b) {
        return a.dev.model_family.localeCompare(b.dev.model_family);
      }).map(function (row) {
        return '<div class="family">' +
          "<div><b>" + esc(row.dev.model_family) + "</b>" +
            (row.dev.regions.length ? '<div class="regions">' + esc(row.dev.regions.join(" ")) + "</div>" : "") +
          "</div>" +
          '<div class="variants">' + (row.dev.variants.length ? esc(row.dev.variants.join(", ")) : "&mdash;") +
            (row.dev.notes ? '<div class="note">' + esc(row.dev.notes) + "</div>" : "") + "</div>" +
          '<div class="driver-link"><a href="#driver-' + esc(row.driver.id) + '" data-jump="' + esc(row.driver.id) + '">' +
            esc(row.driver.id) + "</a> v" + esc(row.driver.version) +
            (row.driver.control ? " &middot; control" : "") + "</div>" +
        "</div>";
      }).join("");
      return '<section class="mfr"><h2>' + esc(name) + "</h2>" + families + "</section>";
    }).join("");
  }

  function render() {
    var list = drivers.filter(matches);
    var filtered = list.length !== drivers.length;
    countEl.textContent = state.view === "drivers"
      ? list.length + " of " + drivers.length + " drivers"
      : list.length + " of " + drivers.length + " drivers, grouped by manufacturer";
    clearEl.hidden = !(filtered || state.query);

    if (!list.length) {
      listEl.innerHTML = '<p class="empty">Nothing matches. Try a manufacturer, a model number or a protocol.</p>';
      document.getElementById("table-head").hidden = true;
      return;
    }
    if (state.view === "drivers") {
      document.getElementById("table-head").hidden = false;
      listEl.innerHTML = list.map(driverCard).join("");
    } else {
      document.getElementById("table-head").hidden = true;
      listEl.innerHTML = manufacturerView(list);
    }
  }

  listEl.addEventListener("click", function (event) {
    var head = event.target.closest(".driver-head");
    if (head) {
      var card = head.parentElement;
      var open = card.classList.toggle("is-open");
      head.setAttribute("aria-expanded", open ? "true" : "false");
      return;
    }
    var jump = event.target.closest("[data-jump]");
    if (jump) {
      event.preventDefault();
      state.view = "drivers";
      syncToggle();
      render();
      var card = document.getElementById("driver-" + jump.dataset.jump);
      if (card) {
        card.classList.add("is-open");
        card.querySelector(".driver-head").setAttribute("aria-expanded", "true");
        card.scrollIntoView({ block: "center" });
      }
    }
  });

  var searchEl = document.getElementById("search");
  searchEl.addEventListener("input", function () {
    state.query = searchEl.value.trim().toLowerCase();
    render();
  });

  document.querySelectorAll("[data-filter]").forEach(function (chip) {
    chip.addEventListener("click", function () {
      var kind = chip.dataset.filter;
      var value = chip.dataset.value;
      if (kind === "control" || kind === "verified") {
        state[kind] = !state[kind];
      } else {
        var set = state[kind];
        if (set.has(value)) { set.delete(value); } else { set.add(value); }
      }
      chip.setAttribute("aria-pressed", chip.getAttribute("aria-pressed") === "true" ? "false" : "true");
      render();
    });
  });

  function syncToggle() {
    document.querySelectorAll("[data-view]").forEach(function (button) {
      button.setAttribute("aria-pressed", button.dataset.view === state.view ? "true" : "false");
    });
  }
  document.querySelectorAll("[data-view]").forEach(function (button) {
    button.addEventListener("click", function () {
      state.view = button.dataset.view;
      syncToggle();
      render();
    });
  });

  clearEl.addEventListener("click", function () {
    state.query = ""; state.control = false; state.verified = false;
    state.ders.clear(); state.protocols.clear(); state.tiers.clear();
    searchEl.value = "";
    document.querySelectorAll("[data-filter]").forEach(function (chip) {
      chip.setAttribute("aria-pressed", "false");
    });
    render();
    searchEl.focus();
  });

  // Deep link: /#driver-sungrow opens that driver.
  render();
  if (location.hash.indexOf("#driver-") === 0) {
    var target = document.getElementById(location.hash.slice(1));
    if (target) {
      target.classList.add("is-open");
      target.querySelector(".driver-head").setAttribute("aria-expanded", "true");
      target.scrollIntoView({ block: "center" });
    }
  }
})();
"""


def chip(kind: str, value: str, label: str) -> str:
    return (f'<button class="chip" type="button" aria-pressed="false" '
            f'data-filter="{kind}" data-value="{value}">{label}</button>')


def render_html(catalog: dict) -> str:
    drivers = catalog["drivers"]
    totals = catalog["totals"]
    source = catalog["source"]

    ders_present = sorted({d for driver in drivers for d in driver["ders"]})
    protocols_present = sorted({driver["protocol"] for driver in drivers})
    tiers_present = sorted({driver["tier"] for driver in drivers})

    der_chips = "".join(chip("ders", d, DER_LABELS.get(d, d)) for d in ders_present)
    protocol_chips = "".join(
        chip("protocols", p, PROTOCOL_LABELS.get(p, p)) for p in protocols_present)
    tier_chips = "".join(chip("tiers", t, TIER_LABELS.get(t, t)) for t in tiers_present)

    # Without JavaScript the page still has to answer "which drivers exist?".
    noscript_rows = "".join(
        f"<li><b>{d['id']}</b> v{d['version']} &middot; "
        f"{PROTOCOL_LABELS.get(d['protocol'], d['protocol'])} &middot; "
        f"{', '.join(DER_LABELS.get(x, x) for x in d['ders']) or 'unspecified'}"
        f"{' &middot; control' if d['control'] else ''}</li>"
        for d in drivers)

    commit_line = ""
    if source["commit_short"]:
        commit_line = (
            f'<a href="{REPO_URL}/commit/{source["commit"]}">'
            f'{source["commit_short"]}</a>')
        if source["commit_date"]:
            commit_line += f' &middot; {source["commit_date"]}'

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Device driver catalog | Sourceful &amp; FTW</title>
<meta name="description" content="Every device driver Sourceful publishes for FTW and Blixt: {totals['drivers']} drivers covering {totals['manufacturers']} manufacturers and {totals['model_families']} model families, with the protocol, tested models and support evidence behind each one.">
<meta name="robots" content="index,follow">
<meta name="theme-color" content="#0a0a0a">
<link rel="canonical" href="https://srcfl.github.io/device-drivers/">
<meta property="og:title" content="Device driver catalog | Sourceful &amp; FTW">
<meta property="og:description" content="{totals['drivers']} open Lua drivers for solar, batteries, meters, heat pumps and EV charging — with the tested models and support evidence behind each one.">
<meta property="og:type" content="website">
<meta property="og:url" content="https://srcfl.github.io/device-drivers/">
<meta property="og:site_name" content="Sourceful device drivers">
<meta name="twitter:card" content="summary">
<meta name="twitter:title" content="Device driver catalog | Sourceful &amp; FTW">
<meta name="twitter:description" content="{totals['drivers']} open Lua drivers, with the tested models and support evidence behind each one.">
<link rel="icon" href="https://ftw.sourceful.energy/favicon.svg" type="image/svg+xml">
<link rel="preconnect" href="https://api.fontshare.com">
<link rel="stylesheet" href="https://api.fontshare.com/v2/css?f[]=satoshi@400,500,700,900&amp;display=swap">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;700&amp;display=swap">
<style>{STYLE}</style>
</head>
<body>
<a class="skip-link" href="#catalog">Skip to the catalog</a>

<header class="site-header">
  <div class="wrap nav">
    <a class="brand" href="#top">
      <span class="brand-name">drivers</span>
      <small>sourceful / device-drivers</small>
    </a>
    <nav class="nav-links" aria-label="Primary">
      <a href="#catalog">Catalog</a>
      <a href="{REPO_URL}/blob/main/docs/WRITING-A-DRIVER.md">Write a driver</a>
      <a href="{REPO_URL}/blob/main/SUPPORT_STATUS.md">Support status</a>
      <a href="https://ftw.sourceful.energy/">FTW</a>
      <a class="nav-cta" href="{REPO_URL}">GitHub <span aria-hidden="true">↗</span></a>
    </nav>
  </div>
</header>

<main id="content">
<section class="hero" id="top">
  <div class="wrap">
    <p class="kicker"><span class="dot" aria-hidden="true"></span>Apache-2.0 &middot; One driver per device &middot; Built from the repository</p>
    <h1>Every driver, and what <em>stands behind it.</em></h1>
    <p class="lede">These are the Lua drivers Sourceful publishes for FTW and Blixt L1 — solar inverters,
    batteries, meters, heat pumps and EV charging. Each entry is generated from the manifest and the driver
    source in <a href="{REPO_URL}">srcfl/device-drivers</a>, so what you read here is what a host installs.
    Being listed is not an install claim: the tier and the per-target status state the evidence behind a
    driver, and a channel signature proves artifact integrity, never hardware coverage.</p>
    <dl class="stats">
      <div><dt>Drivers</dt><dd>{totals['drivers']}</dd></div>
      <div><dt>Manufacturers</dt><dd>{totals['manufacturers']}</dd></div>
      <div><dt>Model families</dt><dd>{totals['model_families']}</dd></div>
      <div><dt>Listed variants</dt><dd>{totals['variants']}</dd></div>
      <div><dt>With control</dt><dd>{totals['control']}</dd></div>
      <div><dt>Verified on hardware</dt><dd>{totals['hardware_verified']}</dd></div>
    </dl>
  </div>
</section>

<section class="controls" id="catalog">
  <div class="wrap">
    <div class="controls-row">
      <label class="search">
        <span class="hint" aria-hidden="true">SEARCH</span>
        <input id="search" type="search" autocomplete="off"
               placeholder="Manufacturer, model number, driver or protocol — try SH10RT"
               aria-label="Search drivers, manufacturers and model numbers">
      </label>
      <div class="view-toggle" role="group" aria-label="View">
        <button type="button" data-view="drivers" aria-pressed="true">By driver</button>
        <button type="button" data-view="manufacturers" aria-pressed="false">By device</button>
      </div>
    </div>
    <div class="filters">
      <div class="filter-group"><span>Type</span>{der_chips}</div>
      <div class="filter-group"><span>Protocol</span>{protocol_chips}</div>
      <div class="filter-group"><span>Tier</span>{tier_chips}</div>
      <div class="filter-group"><span>Evidence</span>{chip("control", "control", "Can control")}{chip("verified", "verified", "Verified on hardware")}</div>
    </div>
    <p class="result-line"><span id="result-count">{totals['drivers']} drivers</span>
      <button id="clear-filters" type="button" hidden>Clear</button></p>
  </div>
</section>

<div class="wrap catalog-body">
  <div class="table-head" id="table-head">
    <span>Driver</span><span>Protocol</span><span>Emits</span><span>Capability</span>
    <span class="cell-host">Tier</span><span>Version</span><span></span>
  </div>
  <div id="list"></div>
  <noscript>
    <p class="empty">This page filters in the browser. Without JavaScript, here is the plain list —
      the same data lives in <a href="{REPO_URL}/blob/main/index.yaml">index.yaml</a> and
      <a href="{REPO_URL}/blob/main/devices.yaml">devices.yaml</a>.</p>
    <ul>{noscript_rows}</ul>
  </noscript>
</div>
</main>

<footer>
  <div class="wrap footer-main">
    <div>
      <h2>Your device is missing?</h2>
      <p>Start from <a href="{REPO_URL}/blob/main/blueprint/BLUEPRINT.lua">BLUEPRINT.lua</a>, a working driver
      written so every rule the repository enforces sits beside the code that follows it. New community drivers
      start with telemetry only; control needs a separate review with a safe default mode, a bounded command
      lease and supervised hardware evidence.</p>
    </div>
    <div class="footer-links">
      <div>
        <span>Repository</span>
        <a href="{REPO_URL}">Source</a>
        <a href="{REPO_URL}/blob/main/CONTRIBUTING.md">Contributing</a>
        <a href="{REPO_URL}/issues">Report a driver fault</a>
      </div>
      <div>
        <span>Contracts</span>
        <a href="{REPO_URL}/blob/main/spec/host-api.md">Host API</a>
        <a href="{REPO_URL}/blob/main/spec/tiers.md">Tiers</a>
        <a href="{REPO_URL}/blob/main/SUPPORT_STATUS.md">Support status</a>
      </div>
      <div>
        <span>Hosts</span>
        <a href="https://ftw.sourceful.energy/">FTW</a>
        <a href="https://github.com/srcfl/ftw">srcfl/ftw</a>
        <a href="https://www.sourceful.energy/">Sourceful Energy</a>
      </div>
    </div>
  </div>
  <div class="wrap footer-bottom">
    <span>&copy; Sourceful Labs AB and contributors &middot; Apache-2.0</span>
    <span>Generated from {commit_line or "the repository"} &middot;
      <a href="./drivers.json">drivers.json</a></span>
  </div>
</footer>

<script>window.__CATALOG__ = {embed_json(catalog)};</script>
<script>{SCRIPT}</script>
</body>
</html>
"""


def write_site(out: Path) -> dict:
    """Render the site into `out` and return the catalog it was built from."""
    catalog = build_catalog()
    out.mkdir(parents=True, exist_ok=True)
    (out / "index.html").write_text(render_html(catalog), encoding="utf-8")
    # The same payload as a file, for anyone who wants the catalog as data.
    (out / "drivers.json").write_text(
        json.dumps(catalog, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    # GitHub Pages must serve the files as generated, not run Jekyll over them.
    (out / ".nojekyll").write_text("", encoding="utf-8")
    return catalog


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default="site",
                        help="directory to write the site into (default: site)")
    args = parser.parse_args()

    out = Path(args.output)
    if not out.is_absolute():
        out = ROOT / out
    catalog = write_site(out)

    totals = catalog["totals"]
    print(f"Generated {out}/index.html: {totals['drivers']} drivers, "
          f"{totals['manufacturers']} manufacturers, "
          f"{totals['model_families']} model families.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
