"""Pin the GoodWe field candidate to the FTW read-only package contract."""

import json
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from driver_package import validate_document  # noqa: E402


def test_goodwe_package_is_ftw_only_and_read_only():
    package = json.loads(
        (ROOT / "packages/v1/goodwe/package-source.json").read_text(encoding="utf-8")
    )
    validate_document(package)

    assert package["version"] == "1.0.2"
    assert package["permissions"] == ["modbus.read"]
    assert package["read_only"] is True
    assert package["commands"] == []
    assert package["capabilities"]["control"] == []
    assert [item["target"] for item in package["compatibility"]] == ["ftw-core"]
    assert package["compatibility"][0]["control_enabled"] is False
    assert package["compatibility"][0]["host"]["min_version"] == "1.10.0-beta.1"


def test_goodwe_source_has_no_write_or_profile_guess_path():
    source = (ROOT / "drivers/lua/goodwe.lua").read_text(encoding="utf-8")
    assert "host.modbus_write" not in source
    assert 'config.profile or "community-v1"' in source
    assert 'profile ~= "community-v1"' in source
    assert 'profile ~= "gw8kn-et-hk3000"' in source
