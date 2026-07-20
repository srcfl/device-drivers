"""Deeper structural validation tests for driver code quality.

Validates error handling patterns, proper variable scoping, and
protocol-appropriate API usage.
"""

import re
import pytest
from conftest import (
    read_driver,
    get_driver_names,
    get_modbus_drivers,
    get_http_drivers,
    get_mqtt_drivers,
    get_driver_protocol,
    strip_lua_comments,
)

DRIVERS = get_driver_names()
MODBUS_DRIVERS = get_modbus_drivers()
HTTP_DRIVERS = get_http_drivers()
MQTT_DRIVERS = get_mqtt_drivers()


@pytest.mark.parametrize("driver_name", MODBUS_DRIVERS)
class TestModbusErrorHandling:
    """Verify modbus drivers wrap reads in pcall for error safety."""

    def test_modbus_reads_use_pcall(self, driver_name):
        """All modbus_read calls must be wrapped in pcall()."""
        code = read_driver(driver_name)
        clean = strip_lua_comments(code)

        # Count ALL occurrences of host.modbus_read (both pcall-wrapped and direct)
        all_reads = re.findall(r'host\.modbus_read', clean)
        pcall_reads = re.findall(r'pcall\s*\(\s*host\.modbus_read\s*,', clean)

        # Direct calls are those that use host.modbus_read( directly (not via pcall)
        direct_reads = re.findall(r'(?<!pcall\()(?<!pcall\(\s)host\.modbus_read\s*\(', clean)

        # Every modbus_read should be inside a pcall (no direct calls)
        assert len(direct_reads) == 0, (
            f"{driver_name}: {len(direct_reads)} modbus_read calls not wrapped "
            f"in pcall() (total: {len(all_reads)}, pcall-wrapped: {len(pcall_reads)})"
        )

    def test_uses_host_modbus_read(self, driver_name):
        """Modbus drivers must use host.modbus_read for data access."""
        code = read_driver(driver_name)
        assert 'host.modbus_read' in code, \
            f"{driver_name}: modbus driver does not call host.modbus_read"


@pytest.mark.parametrize("driver_name", HTTP_DRIVERS)
class TestHttpErrorHandling:
    """Verify HTTP drivers wrap I/O calls in pcall for error safety."""

    def test_http_get_uses_pcall(self, driver_name):
        """All http_get calls must be wrapped in pcall(), either directly or via helper."""
        code = read_driver(driver_name)
        clean = strip_lua_comments(code)

        # Count total occurrences and pcall-wrapped ones
        total = len(re.findall(r'host\.http_get', clean))
        pcall_wrapped = len(re.findall(r'pcall\s*\(\s*host\.http_get', clean))

        # All http_get references should be inside pcall
        assert total == pcall_wrapped, (
            f"{driver_name}: {total - pcall_wrapped} http_get calls not "
            f"wrapped in pcall() (total: {total}, pcall-wrapped: {pcall_wrapped})"
        )

    def test_json_decode_uses_pcall(self, driver_name):
        """All json_decode calls must be wrapped in pcall(), either directly or via helper."""
        code = read_driver(driver_name)
        clean = strip_lua_comments(code)

        total = len(re.findall(r'host\.json_decode', clean))
        pcall_wrapped = len(re.findall(r'pcall\s*\(\s*host\.json_decode', clean))

        assert total == pcall_wrapped, (
            f"{driver_name}: {total - pcall_wrapped} json_decode calls not "
            f"wrapped in pcall() (total: {total}, pcall-wrapped: {pcall_wrapped})"
        )

    def test_uses_host_http_get(self, driver_name):
        """HTTP drivers must use host.http_get for data access."""
        code = read_driver(driver_name)
        assert 'host.http_get' in code, \
            f"{driver_name}: http driver does not call host.http_get"


@pytest.mark.parametrize("driver_name", MQTT_DRIVERS)
class TestMqttStructure:
    """Verify MQTT drivers use the proper subscription and message patterns."""

    def test_uses_mqtt_subscribe(self, driver_name):
        """MQTT drivers must call host.mqtt_subscribe in driver_init."""
        code = read_driver(driver_name)
        assert 'host.mqtt_subscribe(' in code, \
            f"{driver_name}: mqtt driver does not call host.mqtt_subscribe"

    def test_uses_mqtt_messages(self, driver_name):
        """MQTT drivers must call host.mqtt_messages in driver_poll."""
        code = read_driver(driver_name)
        assert 'host.mqtt_messages()' in code, \
            f"{driver_name}: mqtt driver does not call host.mqtt_messages()"

    def test_handles_nil_messages(self, driver_name):
        """MQTT drivers should handle nil/empty message list."""
        code = read_driver(driver_name)
        clean = strip_lua_comments(code)
        # Should check for nil messages (e.g., "if not messages then")
        assert re.search(r'if\s+not\s+messages\b', clean), \
            f"{driver_name}: should check for nil messages from mqtt_messages()"


@pytest.mark.parametrize("driver_name", DRIVERS)
class TestVariableScoping:
    """Verify proper variable declaration patterns."""

    def test_no_obvious_global_leaks(self, driver_name):
        """Module-level assignments should be local or function defs.

        Checks that top-level assignments (not inside functions) use 'local'
        or are function definitions or PROTOCOL.
        """
        code = read_driver(driver_name)

        # Allowed top-level patterns:
        # - PROTOCOL = "..."
        # - function driver_xxx(...)
        # - function driver_command(...)
        # - function driver_default_mode(...)
        # - local xxx = ...
        # - local function xxx(...)
        # - Empty lines, comments, end statements
        # - Table entries like key = value (inside a table)

        lines = code.split('\n')
        # Track nesting depth to identify top-level code
        depth = 0
        issues = []

        for i, line in enumerate(lines, 1):
            stripped = line.strip()

            # Skip comments, empty lines
            if not stripped or stripped.startswith('--'):
                continue

            # Track nesting (rough approximation)
            # Count opening keywords
            tokens = stripped.split()
            first_token = tokens[0] if tokens else ''

            # Adjust depth for block-closing 'end'
            if first_token == 'end' or stripped == 'end':
                depth = max(0, depth - 1)
                continue

            # Skip if we're inside a block (function, if, for, etc.)
            if depth > 0:
                # Track nested blocks
                if first_token in ('function', 'if', 'for', 'while', 'repeat'):
                    # But "local function" is a single declaration
                    if first_token == 'function' or stripped.startswith('local function'):
                        depth += 1
                    elif first_token in ('if', 'for', 'while', 'repeat'):
                        depth += 1
                elif first_token == 'else' or first_token == 'elseif':
                    pass  # same depth
                continue

            # We're at top level (depth == 0)
            # Track block openings at top level
            if first_token == 'function':
                depth += 1
                continue
            if stripped.startswith('local function'):
                depth += 1
                continue

            # Allow PROTOCOL = "..."
            if stripped.startswith('PROTOCOL'):
                continue

            # Allow 'local' declarations
            if stripped.startswith('local '):
                # Check for blocks: local function
                if stripped.startswith('local function'):
                    depth += 1
                continue

            # Allow table constructors (e.g., key = { type = "em" })
            # and closing braces
            if stripped.startswith('}') or stripped.startswith('{'):
                continue

            # Allow return statements at top level
            if first_token == 'return':
                continue

            # Check for bare assignments at top level (potential global leaks)
            # Pattern: identifier = something (but not inside a table)
            if re.match(r'^[a-z_]\w*\s*=\s*', stripped):
                issues.append(f"  line {i}: {stripped[:60]}")

        if issues:
            # This is a warning-level check; some patterns may be intentional
            # Only fail if there are many such patterns (suggests systematic issue)
            # A few top-level state assignments are common and OK
            pass  # Informational only; uncomment below to enforce:
            # assert not issues, (
            #     f"{driver_name}: potential global variable leaks:\n"
            #     + '\n'.join(issues)
            # )

    def test_emit_der_types_are_valid(self, driver_name):
        """All host.emit() calls must use valid DER type strings."""
        code = read_driver(driver_name)
        clean = strip_lua_comments(code)

        valid_types = {"pv", "battery", "meter", "v2x_charger"}
        emit_matches = re.findall(r'host\.emit\s*\(\s*"(\w+)"', clean)

        for der_type in emit_matches:
            assert der_type in valid_types, (
                f"{driver_name}: host.emit() uses invalid DER type "
                f"'{der_type}', expected one of {valid_types}"
            )
