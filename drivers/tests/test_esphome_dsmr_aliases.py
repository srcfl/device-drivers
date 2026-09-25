"""Exercise ESPHome DSMR aliases against the canonical public driver."""

from pathlib import Path
import re
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[2]


def test_esphome_dsmr_source_has_ftw_read_only_contract():
    source = (ROOT / "drivers/lua/esphome_dsmr.lua").read_text(encoding="utf-8")
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


@pytest.mark.parametrize("scenario", ["name-derived", "delivered-returned"])
def test_esphome_dsmr_aliases(scenario):
    result = subprocess.run(
        [
            str(ROOT / "lua55"),
            "drivers/tests/lua_harness/test_esphome_dsmr_aliases.lua",
            scenario,
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
