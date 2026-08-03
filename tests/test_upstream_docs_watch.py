"""The watcher must notice a changed document, and pester a maintainer once.

check_upstream_docs.py holds the folding of fresh fetches into a committed
baseline: a first sighting is a baseline (not news), a moved hash is one alert,
and a link that stays down is one alert on the run it crosses the failure
threshold — never every run after. These tests pin that behaviour without a
network, which is where the once-only guarantee actually lives.
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from check_upstream_docs import (  # noqa: E402
    compute_updates,
    load_state,
    write_state,
)

KEY = "nibe_local::https://x/a.pdf"
META = {
    "driver": "nibe_local",
    "url": "https://x/a.pdf",
    "title": "NIBE changelog",
    "kind": "changelog",
    "url_stability": "stable",
}
CURRENT = {KEY: META}
SHA_A = "a" * 64
SHA_B = "b" * 64


def ok(sha: str) -> dict:
    return {KEY: {"ok": True, "sha256": sha, "content_length": 100}}


def fail(error: str = "boom") -> dict:
    return {KEY: {"ok": False, "error": error}}


# ---- Baseline / change --------------------------------------------------


def test_first_sighting_records_baseline_without_alert():
    docs, alerts = compute_updates({}, CURRENT, ok(SHA_A), "t0")
    assert alerts == []
    entry = docs[KEY]
    assert entry["sha256"] == SHA_A
    assert entry["first_seen"] == "t0" and entry["last_changed"] == "t0"
    assert entry["consecutive_failures"] == 0
    assert entry["url_stability"] == "stable"


def test_unchanged_document_raises_no_alert_and_keeps_timestamps():
    base, _ = compute_updates({}, CURRENT, ok(SHA_A), "t0")
    docs, alerts = compute_updates(base, CURRENT, ok(SHA_A), "t1")
    assert alerts == []
    assert docs[KEY]["first_seen"] == "t0"
    assert docs[KEY]["last_changed"] == "t0"  # unchanged, so not bumped to t1


def test_changed_document_alerts_exactly_once():
    base, _ = compute_updates({}, CURRENT, ok(SHA_A), "t0")

    docs, alerts = compute_updates(base, CURRENT, ok(SHA_B), "t1")
    assert len(alerts) == 1
    alert = alerts[0]
    assert alert["type"] == "changed"
    assert alert["old_sha"] == SHA_A and alert["new_sha"] == SHA_B
    assert docs[KEY]["last_changed"] == "t1"
    assert docs[KEY]["first_seen"] == "t0"

    # Re-running against the now-updated baseline must not re-alert.
    _, alerts_again = compute_updates(docs, CURRENT, ok(SHA_B), "t2")
    assert alerts_again == []


def test_document_dropped_from_manifests_is_pruned():
    base, _ = compute_updates({}, CURRENT, ok(SHA_A), "t0")
    docs, alerts = compute_updates(base, {}, {}, "t1")
    assert docs == {} and alerts == []


# ---- Broken link: once ---------------------------------------------------


def test_broken_link_alerts_once_on_crossing_the_threshold():
    state, _ = compute_updates({}, CURRENT, ok(SHA_A), "t0")
    alert_runs = []
    for run in range(1, 6):
        state, alerts = compute_updates(
            state, CURRENT, fail(), f"t{run}", failure_threshold=3
        )
        if alerts:
            alert_runs.append((run, alerts[0]["type"]))

    assert alert_runs == [(3, "unreachable")]  # exactly one, on the 3rd failure
    assert state[KEY]["consecutive_failures"] == 5
    assert state[KEY]["sha256"] == SHA_A  # last good hash is retained


def test_recovery_resets_the_failure_count():
    state, _ = compute_updates({}, CURRENT, ok(SHA_A), "t0")
    state, _ = compute_updates(state, CURRENT, fail(), "t1", failure_threshold=3)
    state, alerts = compute_updates(state, CURRENT, ok(SHA_A), "t2")
    assert alerts == []
    assert state[KEY]["consecutive_failures"] == 0
    assert state[KEY]["last_error"] is None


# ---- Issue rendering ----------------------------------------------------


def test_changed_alert_title_and_body_carry_the_hashes():
    base, _ = compute_updates({}, CURRENT, ok(SHA_A), "t0")
    _, alerts = compute_updates(base, CURRENT, ok(SHA_B), "t1")
    alert = alerts[0]
    assert alert["issue_title"] == "[upstream-doc] nibe_local: NIBE changelog changed (bbbbbbbb)"
    assert SHA_A in alert["issue_body"] and SHA_B in alert["issue_body"]
    assert alert["label"] == "upstream-doc-changed"


def test_unreachable_alert_weighs_the_stability():
    state, _ = compute_updates({}, CURRENT, ok(SHA_A), "t0")
    for run in range(1, 4):
        state, alerts = compute_updates(state, CURRENT, fail(), f"t{run}", failure_threshold=3)
    body = alerts[0]["issue_body"]
    assert "URL stability:** stable" in body
    assert alerts[0]["issue_title"] == "[upstream-doc] nibe_local: NIBE changelog unreachable"
    assert alerts[0]["label"] == "upstream-doc-unreachable"


# ---- State file ---------------------------------------------------------


def test_state_file_round_trips(tmp_path):
    docs, _ = compute_updates({}, CURRENT, ok(SHA_A), "t0")
    path = tmp_path / "upstream-docs-state.json"
    write_state(path, docs)
    assert load_state(path) == docs
    assert load_state(tmp_path / "missing.json") == {}


# The runner diffs the baseline it rewrites against the committed one and
# proposes the difference. Written in the platform's line ending, a baseline
# authored on Windows is 31 changed lines to Linux on a week when no watched
# document moved -- a pull request that says nothing. Both halves are pinned:
# what the tool writes, and what is committed.


def test_state_file_is_written_with_lf_on_every_platform(tmp_path):
    docs, _ = compute_updates({}, CURRENT, ok(SHA_A), "t0")
    path = tmp_path / "upstream-docs-state.json"
    write_state(path, docs)
    assert b"\r" not in path.read_bytes()


def test_committed_baseline_is_lf():
    assert b"\r" not in (ROOT / "upstream-docs-state.json").read_bytes()
