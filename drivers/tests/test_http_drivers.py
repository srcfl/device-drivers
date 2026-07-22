"""HTTP-specific tests for all HTTP protocol drivers.

Validates HTTP driver patterns including URL construction,
JSON response handling, and error checking.
"""

import re
import pytest
from conftest import (
    read_driver,
    get_http_drivers,
    strip_lua_comments,
)

HTTP_DRIVERS = get_http_drivers()


@pytest.mark.parametrize("driver_name", HTTP_DRIVERS)
class TestHttpPatterns:
    """Validate HTTP driver API usage patterns."""

    def test_constructs_base_url(self, driver_name):
        """HTTP drivers should construct a base URL from config.host."""
        code = read_driver(driver_name)
        clean = strip_lua_comments(code)

        # Look for URL construction pattern:
        # base_url = "http://" .. config.host .. ":" .. port
        # or similar patterns
        has_url_construction = (
            re.search(r'"http://".*config\.host', clean)
            or re.search(r'config\.host.*"http://"', clean)
            or re.search(r'base_url\s*=\s*"http://"', clean)
        )

        assert has_url_construction, (
            f"{driver_name}: HTTP driver should construct URL from config.host"
        )

    def test_uses_json_decode(self, driver_name):
        """HTTP drivers should parse JSON responses with host.json_decode."""
        code = read_driver(driver_name)
        assert 'host.json_decode' in code, (
            f"{driver_name}: HTTP driver should use host.json_decode "
            f"for JSON response parsing"
        )

    def test_handles_nil_response(self, driver_name):
        """HTTP drivers should handle nil/error responses from http_get."""
        code = read_driver(driver_name)
        clean = strip_lua_comments(code)

        # Look for nil-checking patterns after http_get:
        # "if not ok" or "if not body" or "if not data"
        has_nil_check = (
            re.search(r'if\s+not\s+ok', clean)
            or re.search(r'if\s+not\s+body', clean)
            or re.search(r'if\s+not\s+data', clean)
            or re.search(r'return\s+nil', clean)  # helper returns nil on error
        )

        assert has_nil_check, (
            f"{driver_name}: HTTP driver should handle nil/error responses"
        )

    def test_has_http_get_json_helper_or_inline(self, driver_name):
        """HTTP drivers should use a helper function or inline pcall pattern."""
        code = read_driver(driver_name)
        clean = strip_lua_comments(code)

        # Most HTTP drivers define a http_get_json helper or use pcall inline
        has_helper = bool(re.search(r'function\s+http_get_json\s*\(', clean))
        has_inline_pcall = bool(
            re.search(r'pcall\s*\(\s*host\.http_get', clean)
        )

        assert has_helper or has_inline_pcall, (
            f"{driver_name}: HTTP driver should use pcall pattern for http_get "
            f"(either via helper function or inline)"
        )


@pytest.mark.parametrize("driver_name", HTTP_DRIVERS)
class TestHttpUrlSafety:
    """Validate URL construction safety."""

    def test_uses_http_scheme(self, driver_name):
        """HTTP drivers should use http:// scheme (not https on constrained devices)."""
        code = read_driver(driver_name)
        clean = strip_lua_comments(code)

        # Remove comments for checking
        # Should have http:// somewhere in URL construction
        assert '"http://"' in clean, (
            f"{driver_name}: HTTP driver should use 'http://' scheme"
        )

    def test_uses_config_port(self, driver_name):
        """HTTP drivers should use config.port for the connection port."""
        code = read_driver(driver_name)
        clean = strip_lua_comments(code)

        # Most drivers use config.port or a default port
        has_port = (
            'config.port' in clean
            or 'config["port"]' in clean
        )

        assert has_port, (
            f"{driver_name}: HTTP driver should reference config.port "
            f"for connection port"
        )

    def test_poll_returns_on_nil_data(self, driver_name):
        """driver_poll should return early if HTTP request fails."""
        code = read_driver(driver_name)
        clean = strip_lua_comments(code)
        poll_match = re.search(
            r'function\s+driver_poll\s*\([^)]*\)(.*?)(?=\nfunction\s|\Z)',
            clean,
            re.DOTALL,
        )
        poll_body = poll_match.group(1) if poll_match else ""

        # Accept fixed intervals and stateful backoff helpers. HTTP drivers
        # may expose the request error as a separate return value.
        has_early_return = bool(re.search(
            r'if\s+(?:not\s+)?\w+[^\n]*then.*?return\s+'
            r'(?:\d+|[a-z_]\w*(?:\([^)]*\))?)',
            poll_body,
            re.DOTALL,
        ))

        assert has_early_return, (
            f"{driver_name}: driver_poll should return early (with interval) "
            f"when HTTP request fails"
        )
