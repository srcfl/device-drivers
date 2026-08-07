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

_TOPIC_PART = r'(?:(?:"(?:\\.|[^"\\])*")|(?:[A-Za-z_]\w*))'
_TOPIC_EXPRESSION = re.compile(
    rf'{_TOPIC_PART}(?:\s*\.\.\s*{_TOPIC_PART})*'
)


def _file_local_names(code):
    """Return names declared before the first function in a Lua file."""
    first_function = re.search(
        r'^\s*(?:local\s+)?function\b',
        code,
        re.MULTILINE,
    )
    preamble = code[:first_function.start()] if first_function else code
    return set(re.findall(
        r'^\s*local\s+([A-Za-z_]\w*)\s*=',
        preamble,
        re.MULTILINE,
    ))


def _is_static_topic_expression(arg, file_local_names):
    """Accept literals and concatenations of declared file-local names."""
    if not _TOPIC_EXPRESSION.fullmatch(arg):
        return False
    without_strings = re.sub(r'"(?:\\.|[^"\\])*"', '', arg)
    names = set(re.findall(r'\b[A-Za-z_]\w*\b', without_strings))
    return names <= file_local_names


@pytest.mark.parametrize(
    ("arg", "file_local_names", "expected"),
    [
        ('"fixed/#"', set(), True),
        ('BASE_TOPIC .. "/#"', {"BASE_TOPIC"}, True),
        ('topic', set(), False),
        ('BASE_TOPIC .. topic', {"BASE_TOPIC"}, False),
        ('msg.topic', set(), False),
        ('make_topic()', {"make_topic"}, False),
    ],
)
def test_static_topic_expression_requires_file_local_names(
        arg, file_local_names, expected):
    assert _is_static_topic_expression(arg, file_local_names) is expected


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

    def test_subscription_topics_are_static(self, driver_name):
        """A subscription topic must be decidable without running the driver.

        A literal is the common case. A file-local constant or configurable
        prefix is the other one. Function-local names do not qualify because
        they can come from a received message.

        What this rejects is a topic taken from runtime data: an index, a
        field or a call, which is how a driver ends up subscribing to whatever
        a message told it to.
        """
        code = read_driver(driver_name)
        clean = strip_lua_comments(code)
        file_names = _file_local_names(clean)

        sub_calls = re.findall(
            r'host\.mqtt_subscribe\s*\(\s*(.+?)\s*\)',
            clean,
        )

        for call_arg in sub_calls:
            arg = call_arg.strip()
            static = _is_static_topic_expression(arg, file_names)
            assert static, (
                f"{driver_name}: mqtt_subscribe topic must be a literal or a "
                f"concatenation of literals and declared file-local names, "
                f"found: {arg}"
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
