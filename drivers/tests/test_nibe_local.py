"""NIBE local-API driver: FTW contract + the opt-in Solar PV write path.

The driver is read-only by default. Its single write path feeds the pump's
native Solar PV surplus input (srcfl/ftw#537): value clamped to the operator's
stated PV nameplate, deadband against register churn, a dead-man's switch
because the pump-side timeout for a silent feed is undocumented, an orphan
clear on startup, and default mode as the universal off-switch. All of that
is exercised in one harness script against a fake pump that answers with the
Local REST API's real shapes -- including the API's most dangerous habit,
rejecting a write inside an HTTP 200.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "lua55"

pytestmark = pytest.mark.skipif(
    not LUA.exists(), reason="run make check to build ./lua55")


def test_nibe_local_contract_and_solar_pv_write_path():
    result = subprocess.run(
        [str(LUA), "drivers/tests/lua_harness/test_nibe_local_ftw.lua"],
        capture_output=True, text=True, cwd=ROOT)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "OK" in result.stdout
