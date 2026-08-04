#!/usr/bin/env python3
"""Watch the upstream_docs a driver was built against and flag changes.

A manifest may list the vendor documents a driver decodes a device by — a
register map, a parameter changelog PDF (see spec/manifest-v2.md, `upstream_docs`).
Those documents change without telling us. This tool fetches each one, hashes it,
compares it against a committed baseline in `upstream-docs-state.json`, and
reports which drivers now sit on a changed source so a maintainer can review the
registers.

It is the automation half of the field: the manifest records WHAT to watch, this
records WHAT IT WAS and notices when that moves.

    python tools/check_upstream_docs.py                     # fetch, update baseline, report
    python tools/check_upstream_docs.py --dry-run           # fetch + report, write nothing
    python tools/check_upstream_docs.py --check             # validate baseline only, no network
    python tools/check_upstream_docs.py --changes-out P.json  # write alerts for the workflow

Change detection is a raw-byte SHA-256. A PDF's bytes can churn without its
content changing (rebuild timestamps in the file metadata), so a flagged change
is a prompt to look, not proof the registers moved — the tracking issue says so.
The tool only detects and records; the workflow opens the tracking issue.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from manifest_parser import parse_upstream_docs, parse_yaml_simple

ROOT = Path(__file__).resolve().parents[1]
MANIFEST_DIR = ROOT / "manifests"
STATE_PATH = ROOT / "upstream-docs-state.json"

SCHEMA_VERSION = "sourceful.upstream-docs-state/v1"
# Vendor URLs rot and rate-limit; a single failed fetch is noise, not a story.
# Surface a document as unreachable only after it has failed this many runs.
FAILURE_ALERT_THRESHOLD = 3
CHANGED_LABEL = "upstream-doc-changed"
UNREACHABLE_LABEL = "upstream-doc-unreachable"
USER_AGENT = ("srcfl-device-drivers upstream-docs watcher "
              "(+https://github.com/srcfl/device-drivers)")
FETCH_TIMEOUT_S = 30


# ---- Manifest collection ------------------------------------------------


def doc_key(driver: str, url: str) -> str:
    """Stable identity for one watched document."""
    return f"{driver}::{url}"


def collect_docs(manifests_dir: Path) -> dict[str, dict]:
    """Every upstream_docs entry across all manifests, keyed by doc_key."""
    docs: dict[str, dict] = {}
    for path in sorted(manifests_dir.glob("*.yaml")):
        text = path.read_text(encoding="utf-8")
        driver = parse_yaml_simple(text).get("name", path.stem)
        for entry in parse_upstream_docs(text):
            url = entry.get("url", "")
            if not url:
                continue
            docs[doc_key(driver, url)] = {
                "driver": driver,
                "url": url,
                "title": entry.get("title", ""),
                "kind": entry.get("kind", ""),
                "url_stability": entry.get("url_stability", ""),
            }
    return docs


# ---- Fetching (the only network in this file) ---------------------------


def fetch_doc(url: str, timeout: int = FETCH_TIMEOUT_S) -> dict:
    """Fetch a document. Returns an observation dict.

    {"ok": True, "sha256": ..., "content_length": ...} on success,
    {"ok": False, "error": "..."} on any failure. Never raises.
    """
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read()
    except (urllib.error.URLError, TimeoutError, ValueError, OSError) as exc:
        return {"ok": False, "error": f"{type(exc).__name__}: {exc}"}
    return {
        "ok": True,
        "sha256": hashlib.sha256(body).hexdigest(),
        "content_length": len(body),
    }


# ---- Diff (pure — this is what the tests pin) ---------------------------


def compute_updates(
    prev_docs: dict[str, dict],
    current: dict[str, dict],
    observations: dict[str, dict],
    now: str,
    failure_threshold: int = FAILURE_ALERT_THRESHOLD,
) -> tuple[dict[str, dict], list[dict]]:
    """Fold fresh observations into the baseline. Pure; no I/O.

    Returns (new baseline docs, alerts). An alert is raised when a document's
    bytes change, or when it has been unreachable for `failure_threshold` runs
    in a row (once, on crossing the threshold). A document seen for the first
    time only records a baseline — a new watch is not a change. Documents no
    longer named by any manifest are dropped from the baseline.
    """
    new_docs: dict[str, dict] = {}
    alerts: list[dict] = []

    for key, meta in current.items():
        prev = prev_docs.get(key)
        obs = observations.get(key, {"ok": False, "error": "not fetched"})
        entry = {
            "driver": meta["driver"],
            "url": meta["url"],
            "title": meta.get("title", ""),
            "kind": meta.get("kind", ""),
            "url_stability": meta.get("url_stability", ""),
        }

        if obs.get("ok"):
            if prev is None:
                entry.update(
                    sha256=obs["sha256"],
                    content_length=obs["content_length"],
                    first_seen=now,
                    last_changed=now,
                    consecutive_failures=0,
                    last_error=None,
                )
            elif prev.get("sha256") != obs["sha256"]:
                entry.update(
                    sha256=obs["sha256"],
                    content_length=obs["content_length"],
                    first_seen=prev.get("first_seen", now),
                    last_changed=now,
                    consecutive_failures=0,
                    last_error=None,
                )
                alerts.append(_changed_alert(entry, prev.get("sha256"), now))
            else:
                entry.update(
                    sha256=obs["sha256"],
                    content_length=obs["content_length"],
                    first_seen=prev.get("first_seen", now),
                    last_changed=prev.get("last_changed", now),
                    consecutive_failures=0,
                    last_error=None,
                )
        else:  # fetch failed
            failures = (prev.get("consecutive_failures", 0) if prev else 0) + 1
            entry.update(
                sha256=prev.get("sha256") if prev else None,
                content_length=prev.get("content_length") if prev else None,
                first_seen=prev.get("first_seen", now) if prev else now,
                last_changed=prev.get("last_changed") if prev else None,
                consecutive_failures=failures,
                last_error=obs.get("error", "unknown error"),
            )
            if failures == failure_threshold:
                alerts.append(_unreachable_alert(entry, failures))

        new_docs[key] = entry

    return new_docs, alerts


# ---- Alert / issue rendering (pure) -------------------------------------


def _doc_label(entry: dict) -> str:
    return entry.get("title") or entry["url"].rsplit("/", 1)[-1] or entry["url"]


def _changed_alert(entry: dict, old_sha: str | None, now: str) -> dict:
    driver = entry["driver"]
    label = _doc_label(entry)
    # The short hash in the title makes each distinct change its own thread and
    # lets the workflow skip a re-run of the SAME change: notify exactly once.
    title = f"[upstream-doc] {driver}: {label} changed ({entry['sha256'][:8]})"
    body = "\n".join([
        f"The upstream document **{driver}** is watched against has changed.",
        "",
        f"- **Driver:** `{driver}` — `drivers/lua/{driver}.lua`, `manifests/{driver}.yaml`",
        f"- **Document:** {label}",
        f"- **URL:** {entry['url']}",
        f"- **Kind:** {entry.get('kind') or 'unspecified'}",
        f"- **URL stability:** {entry.get('url_stability') or 'unknown'}",
        f"- **Previous SHA-256:** `{old_sha or 'none'}`",
        f"- **New SHA-256:** `{entry['sha256']}`",
        f"- **Detected:** {now}",
        "",
        "### Review",
        "",
        "- [ ] Read the new document and note what changed (registers renumbered,",
        "      parameters added, scaling corrected).",
        f"- [ ] Cross-check against the registers/parameters `{driver}` reads.",
        "- [ ] If the driver is affected, open a fix and bump its version;",
        "      otherwise close this issue.",
        "",
        "> Detection is a raw-byte hash: the file's bytes moved. That can be a",
        "> genuine content change or just rebuild churn in the PDF metadata —",
        "> this issue is a prompt to look, not proof the registers changed.",
        "",
        f"<!-- upstream-doc-watch:{doc_key(driver, entry['url'])} -->",
    ])
    return {
        "type": "changed",
        "key": doc_key(driver, entry["url"]),
        "driver": driver,
        "url": entry["url"],
        "old_sha": old_sha,
        "new_sha": entry["sha256"],
        "label": CHANGED_LABEL,
        "issue_title": title,
        "issue_body": body,
    }


def _unreachable_alert(entry: dict, failures: int) -> dict:
    driver = entry["driver"]
    label = _doc_label(entry)
    stability = entry.get("url_stability") or "unknown"
    # How much a broken link should worry a maintainer depends on whether the
    # manufacturer promised the URL would stay put (the url_stability field).
    weight = {
        "committed": "The manufacturer commits to this URL, so a break is "
                     "unexpected — the document has very likely moved.",
        "stable": "This URL was recorded as stable, so a break most likely "
                  "means the document moved.",
        "volatile": "This URL was flagged as volatile, so an occasional break "
                    "may be routine — confirm before acting.",
    }.get(stability, "This URL's stability was not assessed.")
    # No short hash here: while the link stays down there is one outage to tell
    # the maintainers about, and the workflow skips it if that issue is open.
    title = f"[upstream-doc] {driver}: {label} unreachable"
    body = "\n".join([
        f"The upstream document **{driver}** is watched against could not be",
        f"fetched for {failures} runs in a row. It may have moved or been removed —",
        "which is itself worth checking, since the driver would then be following",
        "a source that no longer exists.",
        "",
        f"- **Driver:** `{driver}`",
        f"- **Document:** {label}",
        f"- **URL:** {entry['url']}",
        f"- **URL stability:** {stability} — {weight}",
        f"- **Last error:** `{entry.get('last_error')}`",
        "",
        "- [ ] Confirm whether the document moved to a new URL and update",
        f"      `manifests/{driver}.yaml`, or remove the entry if it is gone.",
        "",
        f"<!-- upstream-doc-watch:{doc_key(driver, entry['url'])} -->",
    ])
    return {
        "type": "unreachable",
        "key": doc_key(driver, entry["url"]),
        "driver": driver,
        "url": entry["url"],
        "failures": failures,
        "label": UNREACHABLE_LABEL,
        "issue_title": title,
        "issue_body": body,
    }


# ---- State file ---------------------------------------------------------


def load_state(path: Path) -> dict[str, dict]:
    if not path.exists():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    return data.get("docs", {})


def write_state(path: Path, docs: dict[str, dict]) -> None:
    payload = {
        "schema_version": SCHEMA_VERSION,
        "docs": {key: docs[key] for key in sorted(docs)},
    }
    # Without newline="\n", text mode writes the platform's line ending. A
    # baseline written on Windows then reads as a whole-file change to the
    # Linux runner that rewrites it, and the watcher proposes 31 changed lines
    # on a week when no watched document moved.
    path.write_text(json.dumps(payload, indent=2) + "\n",
                    encoding="utf-8", newline="\n")


# ---- CLI ----------------------------------------------------------------


def _now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def _validate_state(state_path: Path, manifests_dir: Path) -> int:
    """No-network sanity check: baseline parses and names only real docs."""
    docs = load_state(state_path)
    current = collect_docs(manifests_dir)
    errors = []
    for key, entry in docs.items():
        if key not in current:
            errors.append(f"{key}: baseline names a doc no manifest declares")
        for field in ("driver", "url"):
            if not entry.get(field):
                errors.append(f"{key}: missing '{field}'")
    for message in errors:
        print(message)
    print(f"{len(docs)} watched docs, {len(errors)} problems.")
    return 1 if errors else 0


def _summarize(alerts: list[dict], docs: dict, checked: int, failed: int) -> str:
    lines = [
        "## upstream-docs watch",
        "",
        f"- Watched documents: **{len(docs)}**",
        f"- Fetched this run: **{checked}** ({failed} failed)",
        f"- Alerts: **{len(alerts)}**",
    ]
    for alert in alerts:
        lines.append(f"  - `{alert['type']}` — {alert['driver']}: {alert['url']}")
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true",
                        help="fetch and report, but do not write the baseline")
    parser.add_argument("--check", action="store_true",
                        help="validate the baseline file only; no network")
    parser.add_argument("--changes-out", type=Path,
                        help="write the alert list as JSON to this path")
    parser.add_argument("--state", type=Path, default=STATE_PATH)
    parser.add_argument("--manifests", type=Path, default=MANIFEST_DIR)
    args = parser.parse_args()

    if args.check:
        return _validate_state(args.state, args.manifests)

    current = collect_docs(args.manifests)
    # Several drivers can watch the same document (nibe_local and myuplink share
    # one PDF); fetch each distinct URL once, not once per driver.
    fetched = {url: fetch_doc(url)
               for url in sorted({meta["url"] for meta in current.values()})}
    observations = {key: fetched[meta["url"]] for key, meta in current.items()}
    failed = sum(1 for obs in fetched.values() if not obs.get("ok"))

    prev_docs = load_state(args.state)
    new_docs, alerts = compute_updates(prev_docs, current, observations, _now_iso())

    if args.changes_out:
        args.changes_out.write_text(json.dumps(alerts, indent=2) + "\n", encoding="utf-8")

    summary = _summarize(alerts, new_docs, len(fetched), failed)
    print(summary)
    _append_step_summary(summary)

    if not args.dry_run:
        write_state(args.state, new_docs)

    return 0


def _append_step_summary(summary: str) -> None:
    import os
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(summary)


if __name__ == "__main__":
    raise SystemExit(main())
