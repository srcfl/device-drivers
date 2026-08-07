"""Test that all drivers comply with the driver contract specification.

Every driver must define PROTOCOL, driver_init, driver_poll, and driver_cleanup.
See spec/driver-contract.md for the full specification.
"""

import re
import pytest
from conftest import (
    read_driver,
    read_manifest,
    get_driver_names,
    strip_lua_comments,
)

DRIVERS = get_driver_names()


@pytest.mark.parametrize("driver_name", DRIVERS)
class TestDriverContract:
    """Contract compliance tests for each driver."""

    def test_has_protocol_global(self, driver_name):
        """PROTOCOL must be defined as a global string."""
        code = read_driver(driver_name)
        assert re.search(r'^PROTOCOL\s*=\s*"', code, re.MULTILINE), \
            f"{driver_name}: missing PROTOCOL global"

    def test_protocol_value_valid(self, driver_name):
        """PROTOCOL must be one of the allowed values."""
        code = read_driver(driver_name)
        match = re.search(r'^PROTOCOL\s*=\s*"([^"]*)"', code, re.MULTILINE)
        assert match, f"{driver_name}: cannot parse PROTOCOL value"
        valid = {"modbus", "mqtt", "http", "serial", "p1", "standalone", ""}
        assert match.group(1) in valid, \
            f"{driver_name}: PROTOCOL={match.group(1)!r} not in {valid}"

    def test_has_driver_init(self, driver_name):
        """driver_init(config) must be defined."""
        code = read_driver(driver_name)
        assert re.search(r'^function\s+driver_init\s*\(', code, re.MULTILINE), \
            f"{driver_name}: missing driver_init function"

    def test_has_driver_poll(self, driver_name):
        """driver_poll() must be defined."""
        code = read_driver(driver_name)
        assert re.search(r'^function\s+driver_poll\s*\(', code, re.MULTILINE), \
            f"{driver_name}: missing driver_poll function"

    def test_has_driver_cleanup(self, driver_name):
        """driver_cleanup() must be defined."""
        code = read_driver(driver_name)
        assert re.search(r'^function\s+driver_cleanup\s*\(', code, re.MULTILINE), \
            f"{driver_name}: missing driver_cleanup function"

    def test_driver_poll_returns_interval(self, driver_name):
        """driver_poll should return a numeric interval."""
        code = read_driver(driver_name)
        # Extract the driver_poll function body — find it up to the next
        # top-level function or end of file
        poll_match = re.search(
            r'function\s+driver_poll\s*\([^)]*\)(.*?)(?=\nfunction\s|\Z)',
            code,
            re.DOTALL,
        )
        if poll_match:
            body = poll_match.group(1)
            assert re.search(r'return\s+(?:\d+|[a-z_]\w*(?:\([^)]*\))?)', body), \
                f"{driver_name}: driver_poll should return a poll interval"

    def test_calls_set_make_in_init(self, driver_name):
        """driver_init should call host.set_make()."""
        if driver_name == "hello":
            pytest.skip("hello driver is a demo-only driver")
        code = read_driver(driver_name)
        assert 'host.set_make(' in code, \
            f"{driver_name}: should call host.set_make() in driver_init"

    def test_calls_emit_in_poll(self, driver_name):
        """driver_poll should report each declared DER through host.emit.

        `host.emit` carries a DER reading and needs a DER type the host
        understands. Heat-pump and schema-less drivers have no matching
        reading type, so they may report only through `host.emit_metric`.
        Metrics remain diagnostic data for every schema-backed DER.
        """
        if driver_name == "hello":
            pytest.skip("hello driver is a demo-only driver")
        code = read_driver(driver_name)
        if 'host.emit(' in code:
            return

        manifest = read_manifest(driver_name)
        match = re.search(r"^ders:\s*\[([^]]*)\]\s*$", manifest, re.MULTILINE)
        assert match, f"{driver_name}: cannot parse manifest ders"
        ders = {
            item.strip().strip("'\"")
            for item in match.group(1).split(",")
            if item.strip()
        }
        metric_only = not ders or ders == {"heatpump"}
        assert metric_only and 'host.emit_metric(' in code, (
            f"{driver_name}: declares {sorted(ders)} and must call host.emit(); "
            f"only heat-pump or schema-less drivers may report metrics only"
        )

    def test_no_forbidden_globals(self, driver_name):
        """Driver must not use forbidden sandbox-escaping functions."""
        code = read_driver(driver_name)
        clean = strip_lua_comments(code)

        forbidden = ['require(', 'dofile(', 'loadfile(', 'loadstring(']
        for pattern in forbidden:
            assert pattern not in clean, \
                f"{driver_name}: uses forbidden function {pattern}"

    def test_no_io_os_debug(self, driver_name):
        """Driver must not access io, os, or debug modules."""
        code = read_driver(driver_name)
        clean = strip_lua_comments(code)

        # Check for io.xxx usage (word boundary to avoid false positives like 'radio.xxx')
        assert not re.search(r'\bio\.\w+', clean), \
            f"{driver_name}: uses forbidden io module"
        # Check for os.xxx usage (word boundary to avoid 'Ferroamp EnergyHub OS' etc.)
        assert not re.search(r'\bos\.\w+', clean), \
            f"{driver_name}: uses forbidden os module"
        # Check for debug.xxx usage
        assert not re.search(r'\bdebug\.\w+', clean), \
            f"{driver_name}: uses forbidden debug module"

    def test_no_raw_print(self, driver_name):
        """Driver should use host.log() instead of print()."""
        code = read_driver(driver_name)
        clean = strip_lua_comments(code)
        # Allow print inside strings, but not as a function call
        no_strings = re.sub(r'"[^"]*"', '""', clean)
        no_strings = re.sub(r"'[^']*'", "''", no_strings)
        assert not re.search(r'\bprint\s*\(', no_strings), \
            f"{driver_name}: should use host.log() instead of print()"
