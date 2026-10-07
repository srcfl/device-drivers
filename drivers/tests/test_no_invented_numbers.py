"""A device that stops answering gets nil from its driver, never a number.

`local w = 0` before a read, or `decode(...) or 0` after one, turns a failed
read into a measurement: 0 W, 0 A, 0 % SoC, 50 Hz. Nothing downstream can tell
it from a real reading. A meter at 0 W looks like a site in balance; a battery
at 0 % looks empty and ready to charge. A missing value has to stay missing, so
the host sends null.

`lua_harness/no_invented_numbers.lua` measures it. It runs a driver twice, with
different register values, numeric config and clock, then makes every read
fail, then makes every Modbus reply short. A number the driver still emits
that is equal in both runs, and was not read, came from none of its inputs: it
was invented. The data model's default SoC window (0.05 / 1.0) is the one
constant allowed. Sourceful's driver registry runs the same file on every
publish and refuses a driver that fails it.

## Why a baseline

When the probe was first run here, 44 of 91 drivers invented at least one
number. As in `test_absent_register_settles.py`, the counts sit in
`invented-number-baseline.json` and this test ratchets:

* a driver whose count goes **up** fails;
* a driver **absent from the baseline** must be clean, so new drivers get the
  rule in full;
* a driver whose count goes **down** also fails, asking for the baseline to be
  updated, so the debt cannot be re-borrowed.

Shrink the baseline. Never grow it.
"""

import json
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"
HARNESS = ROOT / "drivers" / "tests" / "lua_harness"
PROBE = HARNESS / "no_invented_numbers.lua"
DRIVERS = ROOT / "drivers" / "lua"
BASELINE = Path(__file__).parent / "invented-number-baseline.json"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")


def load_baseline() -> dict:
    return json.loads(BASELINE.read_text())["drivers"]


def probe(driver: str) -> tuple[list[str], str | None]:
    """Return the fields this driver invents a number for, or why it was not measured."""
    result = subprocess.run(
        [str(LUA), str(PROBE), str(HARNESS), str(DRIVERS / f"{driver}.lua")],
        capture_output=True, text=True, cwd=ROOT)
    assert result.returncode == 0, result.stdout + result.stderr
    report = json.loads(result.stdout)
    if not report["measured"]:
        return [], report["reason"]
    return sorted({f"{row['der']}.{row['field']}" for row in report["invented"]}), None


def driver_names() -> list[str]:
    return sorted(p.stem for p in DRIVERS.glob("*.lua"))


@pytest.mark.parametrize("driver", driver_names())
def test_invented_number_debt_does_not_grow(driver: str) -> None:
    baseline = load_baseline()
    invented, not_measured = probe(driver)
    if not_measured is not None:
        # driver_init failed with probe config, so a host would not poll it either.
        assert driver not in baseline, (
            f"{driver} is in the baseline but can no longer be measured "
            f"({not_measured}). Remove it from {BASELINE.name}.")
        return

    expected = baseline.get(driver, 0)
    found = len(invented)

    if driver not in baseline:
        assert found == 0, (
            f"{driver} emits numbers it never read once the device stops "
            f"answering: {invented}. Leave a value nil when its read failed "
            f"or came back short, so the host sends null instead of a fake 0.")
        return

    assert found <= expected, (
        f"{driver} went from {expected} to {found} fields it invents a "
        f"number for: {invented}.")

    assert found == expected, (
        f"{driver} is down to {found} from {expected}. Set it to {found} in "
        f"{BASELINE.name} so the debt cannot be re-borrowed."
        if found else
        f"{driver} is clean now. Remove it from {BASELINE.name} so it is held "
        f"to the rule in full.")
