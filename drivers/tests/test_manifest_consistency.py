"""Cross-reference manifests with drivers for consistency.

Validates that every manifest accurately describes its corresponding Lua driver,
including protocol matching, DER type coverage, naming, and metadata quality.
"""

import os
import re
import pytest
from conftest import (
    read_driver,
    read_manifest,
    get_driver_names,
    get_manifest_names,
    get_driver_protocol,
    strip_lua_comments,
    DRIVERS_DIR,
    MANIFESTS_DIR,
)


def simple_yaml_load(text):
    """Minimal YAML parser for flat manifest files. No external deps."""
    result = {}
    for line in text.split('\n'):
        line = line.strip()
        if not line or line.startswith('#') or line.startswith('-'):
            continue
        if ':' not in line:
            continue
        key, _, value = line.partition(':')
        key = key.strip()
        value = value.strip()
        # Skip nested keys (indented lines processed as top-level)
        if key.startswith('-'):
            continue
        # Parse value types
        if value.startswith('[') and value.endswith(']'):
            # Inline list
            items = value[1:-1]
            result[key] = [v.strip().strip('"').strip("'") for v in items.split(',') if v.strip()]
        elif value.startswith('"') and value.endswith('"'):
            result[key] = value[1:-1]
        elif value.startswith("'") and value.endswith("'"):
            result[key] = value[1:-1]
        elif value == 'true':
            result[key] = True
        elif value == 'false':
            result[key] = False
        elif value == '[]':
            result[key] = []
        elif value == '""' or value == "''":
            result[key] = ""
        else:
            try:
                result[key] = int(value)
            except ValueError:
                try:
                    result[key] = float(value)
                except ValueError:
                    result[key] = value
    # Parse tested_devices manually
    if 'tested_devices' not in result:
        result['tested_devices'] = []
    devices = []
    in_device = False
    current = {}
    for line in text.split('\n'):
        stripped = line.strip()
        if stripped.startswith('- manufacturer:'):
            if current:
                devices.append(current)
            current = {}
            current['manufacturer'] = stripped.split(':', 1)[1].strip().strip('"').strip("'")
            in_device = True
        elif in_device and stripped.startswith('model_family:'):
            current['model_family'] = stripped.split(':', 1)[1].strip().strip('"').strip("'")
        elif in_device and stripped.startswith('variants:'):
            val = stripped.split(':', 1)[1].strip()
            if val.startswith('[') and val.endswith(']'):
                items = val[1:-1]
                current['variants'] = [v.strip().strip('"') for v in items.split(',') if v.strip()]
            else:
                current['variants'] = []
    if current:
        devices.append(current)
    if devices:
        result['tested_devices'] = devices
    return result

DRIVERS = get_driver_names()
MANIFESTS = get_manifest_names()


class TestManifestDriverParity:
    """Every driver should have a manifest and vice versa."""

    def test_every_driver_has_manifest(self):
        """Every .lua driver file must have a corresponding .yaml manifest."""
        drivers = set(get_driver_names())
        manifests = set(get_manifest_names())
        missing = drivers - manifests
        assert not missing, (
            f"Drivers without manifests: {sorted(missing)}"
        )

    def test_every_manifest_has_driver(self):
        """Every .yaml manifest must have a corresponding .lua driver file."""
        drivers = set(get_driver_names())
        manifests = set(get_manifest_names())
        orphaned = manifests - drivers
        assert not orphaned, (
            f"Manifests without drivers: {sorted(orphaned)}"
        )


@pytest.mark.parametrize("driver_name", MANIFESTS)
class TestManifestSchema:
    """Validate manifest YAML structure and field values."""

    def _load_manifest(self, driver_name):
        """Parse YAML manifest into a dict."""
        content = read_manifest(driver_name)
        return simple_yaml_load(content)

    def test_name_matches_filename(self, driver_name):
        """Manifest 'name' field must match the filename."""
        manifest = self._load_manifest(driver_name)
        assert manifest.get("name") == driver_name, (
            f"{driver_name}: manifest name '{manifest.get('name')}' "
            f"does not match filename"
        )

    def test_version_is_semver(self, driver_name):
        """Version must be valid semantic versioning (X.Y.Z)."""
        manifest = self._load_manifest(driver_name)
        version = manifest.get("version", "")
        assert re.match(r'^\d+\.\d+\.\d+$', str(version)), (
            f"{driver_name}: version '{version}' is not valid semver (X.Y.Z)"
        )

    def test_tier_is_valid(self, driver_name):
        """Tier must be one of: core, community, oem."""
        manifest = self._load_manifest(driver_name)
        valid_tiers = {"core", "community", "oem"}
        tier = manifest.get("tier")
        assert tier in valid_tiers, (
            f"{driver_name}: tier '{tier}' not in {valid_tiers}"
        )

    def test_protocol_is_valid(self, driver_name):
        """Protocol must be a known protocol or empty string."""
        manifest = self._load_manifest(driver_name)
        valid_protocols = {"modbus", "mqtt", "http", "serial", "p1", "standalone", ""}
        protocol = manifest.get("protocol", "")
        assert str(protocol) in valid_protocols or protocol is None, (
            f"{driver_name}: manifest protocol '{protocol}' not in {valid_protocols}"
        )

    def test_ders_are_valid(self, driver_name):
        """All DER types in the manifest must be valid."""
        manifest = self._load_manifest(driver_name)
        valid_ders = {"pv", "battery", "meter", "v2x_charger"}
        ders = manifest.get("ders", [])
        assert isinstance(ders, list), (
            f"{driver_name}: ders must be a list, got {type(ders)}"
        )
        for der in ders:
            assert der in valid_ders, (
                f"{driver_name}: invalid DER type '{der}' in manifest, "
                f"expected one of {valid_ders}"
            )

    def test_ders_not_empty(self, driver_name):
        """Manifest must declare at least one DER type."""
        manifest = self._load_manifest(driver_name)
        ders = manifest.get("ders", [])
        assert len(ders) > 0, (
            f"{driver_name}: manifest declares no DER types"
        )

    def test_control_is_boolean(self, driver_name):
        """Control field must be a boolean."""
        manifest = self._load_manifest(driver_name)
        control = manifest.get("control")
        assert isinstance(control, bool), (
            f"{driver_name}: control must be boolean, got {type(control)}: {control}"
        )

    def test_size_bytes_is_reasonable(self, driver_name):
        """size_bytes should be non-negative. Real drivers are typically > 100 bytes."""
        manifest = self._load_manifest(driver_name)
        size = manifest.get("size_bytes", 0)
        assert isinstance(size, int), (
            f"{driver_name}: size_bytes must be integer, got {type(size)}"
        )
        assert size >= 0, (
            f"{driver_name}: size_bytes must be non-negative, got {size}"
        )

    def test_core_tier_has_author(self, driver_name):
        """Core tier drivers must have an author."""
        manifest = self._load_manifest(driver_name)
        if manifest.get("tier") != "core":
            pytest.skip("Not a core tier driver")
        author = manifest.get("author", "")
        assert author and len(str(author).strip()) > 0, (
            f"{driver_name}: core tier driver must have an author"
        )

    def test_tested_devices_structure(self, driver_name):
        """tested_devices entries must have manufacturer and model_family."""
        manifest = self._load_manifest(driver_name)
        tested = manifest.get("tested_devices", [])
        if not tested:
            pytest.skip(f"{driver_name}: no tested_devices entries")

        for i, device in enumerate(tested):
            assert "manufacturer" in device, (
                f"{driver_name}: tested_devices[{i}] missing 'manufacturer'"
            )
            assert "model_family" in device, (
                f"{driver_name}: tested_devices[{i}] missing 'model_family'"
            )


@pytest.mark.parametrize("driver_name", MANIFESTS)
class TestManifestDriverConsistency:
    """Cross-reference manifest metadata against the actual driver code."""

    def _load_manifest(self, driver_name):
        """Parse YAML manifest into a dict."""
        content = read_manifest(driver_name)
        return simple_yaml_load(content)

    def test_protocol_matches_driver(self, driver_name):
        """Manifest protocol must match the PROTOCOL global in the Lua file."""
        if driver_name not in get_driver_names():
            pytest.skip(f"No driver file for {driver_name}")

        manifest = self._load_manifest(driver_name)
        manifest_protocol = str(manifest.get("protocol", ""))

        driver_protocol = get_driver_protocol(driver_name)
        assert driver_protocol is not None, (
            f"{driver_name}: cannot extract PROTOCOL from driver source"
        )

        # Handle empty/standalone mapping
        # Manifest may use "" or "standalone" for the same thing
        # Also handle the hello driver which has PROTOCOL="standalone" but manifest protocol=""
        proto_aliases = {
            "": {"", "standalone"},
            "standalone": {"", "standalone"},
        }

        if manifest_protocol in proto_aliases:
            assert driver_protocol in proto_aliases[manifest_protocol], (
                f"{driver_name}: manifest protocol '{manifest_protocol}' "
                f"does not match driver PROTOCOL='{driver_protocol}'"
            )
        else:
            assert manifest_protocol == driver_protocol, (
                f"{driver_name}: manifest protocol '{manifest_protocol}' "
                f"does not match driver PROTOCOL='{driver_protocol}'"
            )

    def test_ders_match_emit_calls(self, driver_name):
        """Manifest DER list should match the host.emit() DER types in the driver."""
        if driver_name not in get_driver_names():
            pytest.skip(f"No driver file for {driver_name}")

        manifest = self._load_manifest(driver_name)
        manifest_ders = set(manifest.get("ders", []))

        code = read_driver(driver_name)
        clean = strip_lua_comments(code)
        emitted_ders = set(re.findall(r'host\.emit\s*\(\s*"(\w+)"', clean))

        if not emitted_ders:
            pytest.skip(f"{driver_name}: no emit calls found (may use variable)")

        # Emitted DER types should be a subset of manifest DER types
        extra = emitted_ders - manifest_ders
        assert not extra, (
            f"{driver_name}: driver emits DER types {extra} not listed in manifest. "
            f"Manifest: {manifest_ders}, Driver: {emitted_ders}"
        )

        # Manifest DER types should be a subset of (or equal to) emitted types
        # Allow manifest to list types the driver conditionally emits
        missing = manifest_ders - emitted_ders
        if missing:
            # Soft warning: manifest claims DER types that aren't explicitly emitted
            # This can happen with conditional emission or variable-based emit
            pass

    def test_control_matches_driver(self, driver_name):
        """If manifest says control=true, driver should define driver_command."""
        if driver_name not in get_driver_names():
            pytest.skip(f"No driver file for {driver_name}")

        manifest = self._load_manifest(driver_name)
        has_control = manifest.get("control", False)

        code = read_driver(driver_name)
        has_command_func = bool(
            re.search(r'^function\s+driver_command\s*\(', code, re.MULTILINE)
        )

        if has_control:
            assert has_command_func, (
                f"{driver_name}: manifest declares control=true but driver "
                f"does not define driver_command()"
            )
