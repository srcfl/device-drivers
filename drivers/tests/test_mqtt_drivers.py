"""MQTT-specific tests for all MQTT protocol drivers.

Validates MQTT driver patterns including topic subscription,
message processing, and proper lifecycle management.
"""

import re
import pytest
from conftest import (
    read_driver,
    get_mqtt_drivers,
    strip_lua_comments,
)

MQTT_DRIVERS = get_mqtt_drivers()


@pytest.mark.parametrize("driver_name", MQTT_DRIVERS)
class TestMqttSubscription:
    """Validate MQTT subscription patterns."""

    def test_subscribes_in_driver_init(self, driver_name):
        """MQTT subscriptions should happen in driver_init, not driver_poll."""
        code = read_driver(driver_name)

        # Extract driver_init body
        init_match = re.search(
            r'function\s+driver_init\s*\([^)]*\)(.*?)(?=\nfunction\s|\Z)',
            code,
            re.DOTALL,
        )
        assert init_match, f"{driver_name}: cannot find driver_init body"

        init_body = init_match.group(1)
        assert 'host.mqtt_subscribe(' in init_body, (
            f"{driver_name}: mqtt_subscribe should be called in driver_init, "
            f"not elsewhere"
        )

    def test_subscription_topics_are_strings(self, driver_name):
        """All mqtt_subscribe calls should use string literal topics."""
        code = read_driver(driver_name)
        clean = strip_lua_comments(code)

        # Find all subscribe calls and verify they use string literals
        sub_calls = re.findall(
            r'host\.mqtt_subscribe\s*\(\s*(.+?)\s*\)',
            clean,
        )

        for call_arg in sub_calls:
            # Should be a string literal (starts with ")
            assert call_arg.strip().startswith('"'), (
                f"{driver_name}: mqtt_subscribe should use string literal "
                f"topic, found: {call_arg}"
            )


@pytest.mark.parametrize("driver_name", MQTT_DRIVERS)
class TestMqttMessageProcessing:
    """Validate MQTT message processing patterns."""

    def test_processes_messages_in_poll(self, driver_name):
        """driver_poll should call mqtt_messages() and iterate over results."""
        code = read_driver(driver_name)
        clean = strip_lua_comments(code)

        # Should call mqtt_messages()
        assert 'host.mqtt_messages()' in clean, (
            f"{driver_name}: driver_poll should call host.mqtt_messages()"
        )

        # Should iterate over messages (for _, msg in ipairs(messages))
        has_iteration = (
            re.search(r'for\s+\w+,\s*\w+\s+in\s+ipairs\s*\(\s*messages\s*\)', clean)
            or re.search(r'for\s+\w+,\s*\w+\s+in\s+ipairs\s*\(\s*msgs\s*\)', clean)
        )

        assert has_iteration, (
            f"{driver_name}: driver_poll should iterate over mqtt messages"
        )

    def test_handles_empty_message_list(self, driver_name):
        """Driver should handle nil/empty message list gracefully."""
        code = read_driver(driver_name)
        clean = strip_lua_comments(code)

        # Should check for nil messages before processing
        has_nil_check = (
            re.search(r'if\s+not\s+messages\b', clean)
            or re.search(r'if\s+messages\s*==\s*nil', clean)
            or re.search(r'if\s+not\s+msgs\b', clean)
        )

        assert has_nil_check, (
            f"{driver_name}: should handle nil/empty message list from "
            f"mqtt_messages()"
        )

    def test_accesses_topic_and_payload(self, driver_name):
        """Message processing should access msg.topic and msg.payload."""
        code = read_driver(driver_name)
        clean = strip_lua_comments(code)

        # Should access topic field
        has_topic = (
            re.search(r'\w+\.topic\b', clean)
            or re.search(r'\["topic"\]', clean)
        )
        assert has_topic, (
            f"{driver_name}: should access msg.topic for routing messages"
        )

        # Should access payload field
        has_payload = (
            re.search(r'\w+\.payload\b', clean)
            or re.search(r'\["payload"\]', clean)
        )
        assert has_payload, (
            f"{driver_name}: should access msg.payload for extracting values"
        )


@pytest.mark.parametrize("driver_name", MQTT_DRIVERS)
class TestMqttJsonHandling:
    """Validate JSON parsing in MQTT drivers."""

    def test_json_decode_uses_pcall(self, driver_name):
        """JSON decoding of MQTT payloads should use pcall for error safety."""
        code = read_driver(driver_name)
        clean = strip_lua_comments(code)

        # If the driver uses json_decode, it should be wrapped in pcall
        if 'host.json_decode' not in clean:
            pytest.skip(f"{driver_name}: does not use json_decode (may use raw payloads)")

        # Count all references to host.json_decode (regardless of how called)
        total = len(re.findall(r'host\.json_decode', clean))
        pcall_wrapped = len(re.findall(r'pcall\s*\(\s*host\.json_decode', clean))

        # All json_decode uses should be via pcall
        assert total == pcall_wrapped, (
            f"{driver_name}: {total - pcall_wrapped} json_decode calls not "
            f"wrapped in pcall() (total: {total}, pcall-wrapped: {pcall_wrapped})"
        )


@pytest.mark.parametrize("driver_name", MQTT_DRIVERS)
class TestMqttStateManagement:
    """Validate MQTT driver state management."""

    def test_cleanup_resets_state(self, driver_name):
        """driver_cleanup should reset cached state."""
        code = read_driver(driver_name)

        # Extract driver_cleanup body
        cleanup_match = re.search(
            r'function\s+driver_cleanup\s*\([^)]*\)(.*?)(?=\nfunction\s|\Z)',
            code,
            re.DOTALL,
        )
        assert cleanup_match, f"{driver_name}: cannot find driver_cleanup body"

        cleanup_body = cleanup_match.group(1).strip()

        # Cleanup should do something (not be empty)
        # Strip comments and whitespace
        clean_body = strip_lua_comments(cleanup_body).strip()
        # Remove 'end' at the end
        clean_body = re.sub(r'\bend\s*$', '', clean_body).strip()

        assert len(clean_body) > 0, (
            f"{driver_name}: driver_cleanup is empty but MQTT driver likely "
            f"has cached state to clean up"
        )
