"""A driver whose device refuses a write must stop making it unprompted.

`driver_default_mode` is the one control path that runs on a timer. FTW reaches
it through `Registry.SendDefault` on lease expiry, the telemetry watchdog, the
stale-site-meter standdown and shutdown — never from a command, and never with
anything able to say no to it. A driver that writes there whatever the device
answers goes on writing for the life of the session.

A customer's Sungrow SG12RT is the worked example. Its EMS registers are not
implemented on that model, so every write came back `modbus exception
function=0x06`, and the driver reissued three of them on every watchdog tick
and logged a warn line each time — drowning the log an operator was reading to
find why the site was offline, which it was for an unrelated reason. Fixed in
sungrow 1.5.7 by counting refusals: three prove the block is absent, and the
unprompted paths stop.

This is the write-side twin of `test_absent_register_settles.py`, which holds
the same property for reads. The two failures are not equally severe — a failed
read fails the whole poll and takes the site offline, while a failed write
costs bus traffic and a log line — which is why this one measures the flap
rather than treating every occurrence as an outage.

## What is not a violation

* A driver that never writes in `driver_default_mode`.
* A driver that stops after a bounded number of attempts.
* Returning `false` while it is still attempting. That is honest, and it is
  what a caller needs to know. What must not last forever is the writing.

## Why a baseline rather than a plain assertion

11 of the 12 Modbus drivers with a writing `driver_default_mode` violated the
rule when this was first measured; sungrow was the only one that settled, and
only because a field report forced it. Failing all 11 would gate every
unrelated change until the fleet is fixed, so the counts live in
`refused-write-baseline.json` and this test ratchets, the way #36 did for
reads:

* a driver whose count goes **up** fails — new debt is blocked at the door;
* a driver **absent from the baseline** must be clean — new drivers get the
  rule in full;
* a driver whose count goes **down** also fails, asking for the baseline to be
  updated, so the debt cannot quietly be re-borrowed.

Shrink the baseline. Never grow it.
"""

import json
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"
PROBE = ROOT / "drivers" / "tests" / "lua_harness" / "refused_write_probe.lua"
DRIVERS = ROOT / "drivers" / "lua"
BASELINE = Path(__file__).parent / "refused-write-baseline.json"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")


def load_baseline() -> dict:
    return json.loads(BASELINE.read_text())["drivers"]


def probe(driver: str) -> tuple[list[int], str | None]:
    """Return the per-call write counts if the driver never settles.

    An empty list means it settled, or never wrote. A skip reason means this
    driver cannot be measured at all.
    """
    result = subprocess.run(
        [str(LUA), str(PROBE), str(ROOT), str(DRIVERS / f"{driver}.lua")],
        capture_output=True, text=True, cwd=ROOT)
    assert result.returncode == 0, result.stdout + result.stderr

    for line in result.stdout.splitlines():
        if line.startswith("SKIP "):
            return [], line[5:].strip()
        if not line.startswith("DEFAULT_MODE "):
            continue
        parts = line.split()
        settled = int(parts[2])
        writes = [int(n) for n in parts[4].split(",")]
        if settled or not any(writes):
            return [], None
        return writes, None
    return [], "no probe output"


def driver_names() -> list[str]:
    return sorted(p.stem for p in DRIVERS.glob("*.lua"))


@pytest.mark.holds_for_ftw_drivers
@pytest.mark.parametrize("driver", driver_names())
def test_refused_write_debt_does_not_grow(driver: str) -> None:
    baseline = load_baseline()
    writes, skip = probe(driver)
    if skip is not None:
        # Not Modbus, or no driver_default_mode. Nothing to measure.
        assert driver not in baseline, (
            f"{driver} is in the baseline but can no longer be measured "
            f"({skip}). Remove it from {BASELINE.name}.")
        return

    found = 1 if writes else 0
    expected = baseline.get(driver, 0)

    if driver not in baseline:
        assert found == 0, (
            f"{driver} reissues a refused write on every driver_default_mode "
            f"call and never stops: {writes} writes per call. The watchdog "
            f"reaches this path on a timer, so on a model that does not "
            f"implement the register it repeats for the life of the session. "
            f"Count the refusals and stop — sungrow 1.5.7 is the pattern.")
        return

    assert found <= expected, (
        f"{driver} went from settling to not settling: {writes} writes per "
        f"call, forever.")

    assert found == expected, (
        f"{driver} settles now — good. Remove it from {BASELINE.name} so it "
        f"is held to the rule in full.")
