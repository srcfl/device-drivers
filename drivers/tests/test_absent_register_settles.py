"""A driver that keeps reporting must not keep failing reads.

The host counts every failed `host.modbus_read` against the poll whether or
not Lua caught it with pcall — `driver_poll: %d of %d modbus reads failed` in
FTW's `go/internal/drivers/lua.go`. So a driver that decides it can live
without a register, and then goes on reading it every five seconds anyway,
gets marked offline by the stale-telemetry watchdog. The site reports nothing
instead of one field less.

Emitting nothing while failing is not a violation. A device that cannot answer
its identity block or its main data block really is unreadable, and failing
the poll is the honest outcome. The violation is doing both.

`tests/test_blueprint.py` already holds the blueprint to this property. This
holds the drivers that ship to it.

## Why a baseline rather than a plain assertion

When this check was first run, 49 of 50 Modbus drivers violated the rule on
at least one register — 497 of 543 probed addresses. That is the real state
of the catalog, not a bug in the check: Pixii and SolarEdge legacy were not
unlucky, they were the two that met firmware omitting a register they read.

Failing all 49 would gate every unrelated change until the whole fleet is
fixed. So the counts are recorded in `absent-register-baseline.json` and this
test ratchets:

* a driver whose count goes **up** fails — new debt is blocked at the door;
* a driver **absent from the baseline** must be clean — new drivers get the
  rule in full;
* a driver whose count goes **down** also fails, asking for the baseline to be
  updated, so the debt cannot quietly be re-borrowed later.

Shrink the baseline. Never grow it.
"""

import json
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"
PROBE = ROOT / "drivers" / "tests" / "lua_harness" / "absent_register_probe.lua"
DRIVERS = ROOT / "drivers" / "lua"
BASELINE = Path(__file__).parent / "absent-register-baseline.json"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")


def load_baseline() -> dict:
    return json.loads(BASELINE.read_text())["drivers"]


def probe(driver: str) -> tuple[list[int], str | None]:
    """Return the addresses this driver violates the rule on, or a skip reason."""
    result = subprocess.run(
        [str(LUA), str(PROBE), str(ROOT), str(DRIVERS / f"{driver}.lua")],
        capture_output=True, text=True, cwd=ROOT)
    assert result.returncode == 0, result.stdout + result.stderr

    violations = []
    for line in result.stdout.splitlines():
        if line.startswith("SKIP "):
            return [], line[5:].strip()
        if not line.startswith("ADDR "):
            continue
        parts = line.split()
        addr, settled, emitted = int(parts[1]), int(parts[3]), int(parts[5])
        # Settled means the driver stopped asking. Emitting nothing means it
        # stopped claiming the device is readable. Either one is fine.
        if not settled and emitted > 0:
            violations.append(addr)
    return violations, None


def driver_names() -> list[str]:
    return sorted(p.stem for p in DRIVERS.glob("*.lua"))


@pytest.mark.holds_for_ftw_drivers
@pytest.mark.parametrize("driver", driver_names())
def test_absent_register_debt_does_not_grow(driver: str) -> None:
    baseline = load_baseline()
    violations, skip = probe(driver)
    if skip is not None:
        # Not a Modbus driver, or reads no registers. Nothing to measure.
        assert driver not in baseline, (
            f"{driver} is in the baseline but can no longer be measured "
            f"({skip}). Remove it from {BASELINE.name}.")
        return

    expected = baseline.get(driver, 0)
    found = len(violations)

    if driver not in baseline:
        assert found == 0, (
            f"{driver} keeps reporting telemetry while permanently failing "
            f"reads of {violations}. Probe each register once, remember an "
            f"absent one and stop asking — or stop emitting. The host counts "
            f"every failed read against the poll and takes the driver offline."
        )
        return

    assert found <= expected, (
        f"{driver} went from {expected} to {found} registers it fails forever "
        f"while still reporting: {violations}. This is the failure that took "
        f"Pixii and SolarEdge legacy offline on customer hardware.")

    assert found == expected, (
        f"{driver} is down to {found} from {expected} — good. Set it to "
        f"{found} in {BASELINE.name} so the debt cannot be re-borrowed."
        if found else
        f"{driver} is clean now — good. Remove it from {BASELINE.name} so it "
        f"is held to the rule in full.")
