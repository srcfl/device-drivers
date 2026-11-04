"""Exercise zap.lua's meter reading against the v1 and v2 Zap local API schemas."""

from pathlib import Path
import re
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[2]


def test_zap_source_has_ftw_read_only_contract():
    source = (ROOT / "drivers/lua/zap.lua").read_text(encoding="utf-8")
    for entrypoint in ("driver_init", "driver_poll", "driver_command",
                       "driver_default_mode"):
        assert re.search(rf"\bfunction\s+{entrypoint}\s*\(", source), entrypoint
    assert re.search(r"\bhost_api_min\s*=", source)
    assert re.search(r"\bhost_api_max\s*=", source)
    assert re.search(r"\bread_only\s*=\s*true\b", source)
    assert not re.search(
        r"\bhost\.(?:http_post|modbus_write(?:_multi)?|mqtt_publish|serial_write)\s*\(",
        source,
    ), "a read-only driver calls a write-capable host function"


@pytest.mark.parametrize("scenario", ["v1", "v2"])
def test_zap_meter_schema(scenario):
    result = subprocess.run(
        [
            str(ROOT / "lua55"),
            "drivers/tests/lua_harness/test_zap_meter_schema.lua",
            scenario,
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
