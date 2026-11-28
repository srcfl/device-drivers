#!/usr/bin/env python3
"""Shared YAML manifest parser for lua-drivers tools.

Provides a minimal YAML parser for our manifest format, including
support for nested tested_devices blocks with model hierarchy fields.

Used by: validate_manifest.py, generate_index.py, generate_devices.py
"""

import re


def parse_yaml_simple(text: str) -> dict:
    """Minimal YAML parser for our flat manifest format.

    Handles top-level key: value pairs and inline lists.
    For nested tested_devices blocks, use parse_tested_devices().
    """
    data = {}
    for line in text.strip().splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        # Skip nested lines (indented list items)
        if line.startswith(" ") or line.startswith("\t"):
            continue
        if stripped.startswith("-"):
            continue
        # Handle inline lists: key: [a, b, c]
        m = re.match(r'^(\w+):\s*\[([^\]]*)\]$', stripped)
        if m:
            key = m.group(1)
            items = [i.strip().strip('"').strip("'") for i in m.group(2).split(",") if i.strip()]
            data[key] = items
            continue
        # Handle simple key: value
        m = re.match(r'^(\w+):\s*(.+)$', stripped)
        if m:
            key = m.group(1)
            val = m.group(2).strip().strip('"').strip("'")
            if val == "true":
                data[key] = True
            elif val == "false":
                data[key] = False
            elif val.isdigit():
                data[key] = int(val)
            else:
                data[key] = val
            continue
    return data


def parse_tested_devices(text: str) -> list[dict]:
    """Parse the tested_devices block from manifest text.

    Supports both old format (model/manufacturer) and new format
    (manufacturer/model_family/variants/regions/firmware_versions/notes).

    Returns a list of device dicts.
    """
    devices = []
    current = None
    in_tested = False

    for line in text.splitlines():
        stripped = line.strip()

        # Detect start of tested_devices block
        if stripped.startswith("tested_devices:"):
            in_tested = True
            # Handle empty list: tested_devices: []
            if stripped == "tested_devices: []":
                return []
            continue

        # Detect end of tested_devices block (next top-level key)
        if in_tested and stripped and not line.startswith(" ") and not line.startswith("\t"):
            break

        if not in_tested:
            continue

        # Skip empty lines and comments
        if not stripped or stripped.startswith("#"):
            continue

        # New device entry: "- key: value" or just "-"
        if stripped.startswith("- "):
            if current is not None:
                devices.append(current)
            current = {}
            rest = stripped[2:].strip()
            if rest:
                _parse_device_field(current, rest)
            continue

        # Continuation field within current device
        if current is not None and ":" in stripped:
            _parse_device_field(current, stripped)

    if current is not None:
        devices.append(current)

    return devices


def parse_upstream_docs(text: str) -> list[dict]:
    """Parse the optional upstream_docs block from manifest text.

    upstream_docs lists the vendor reference documents a driver was built
    against — register maps, parameter changelogs, protocol manuals — at a
    semi-persistent URL. A change to one of these is the upstream signal that
    a driver's register decoding may need review. Each entry carries a `url`
    and optional `title`/`kind`.

    Mirrors parse_tested_devices(): a top-level block of "- " list items.
    Returns a list of doc dicts (empty when the block is absent or `[]`).
    """
    docs = []
    current = None
    in_block = False

    for line in text.splitlines():
        stripped = line.strip()

        # Detect start of upstream_docs block
        if stripped.startswith("upstream_docs:"):
            in_block = True
            # Handle empty list: upstream_docs: []
            if stripped == "upstream_docs: []":
                return []
            continue

        # Detect end of block (next top-level key)
        if in_block and stripped and not line.startswith(" ") and not line.startswith("\t"):
            break

        if not in_block:
            continue

        # Skip empty lines and comments
        if not stripped or stripped.startswith("#"):
            continue

        # New doc entry: "- key: value" or just "-"
        if stripped.startswith("- "):
            if current is not None:
                docs.append(current)
            current = {}
            rest = stripped[2:].strip()
            if rest:
                _parse_device_field(current, rest)
            continue

        # Continuation field within current doc
        if current is not None and ":" in stripped:
            _parse_device_field(current, stripped)

    if current is not None:
        docs.append(current)

    return docs


def _parse_device_field(device: dict, field_str: str) -> None:
    """Parse a single key: value field into a device dict."""
    # Handle inline lists: key: [a, b, c]
    m = re.match(r'^(\w+):\s*\[([^\]]*)\]$', field_str)
    if m:
        key = m.group(1)
        items = [i.strip().strip('"').strip("'") for i in m.group(2).split(",") if i.strip()]
        device[key] = items
        return

    # Handle key: value
    m = re.match(r'^(\w+):\s*(.*)$', field_str)
    if m:
        key = m.group(1)
        val = m.group(2).strip().strip('"').strip("'")
        device[key] = val


# A read request asks a device to report and changes nothing on it. Victron's
# Venus OS publishes its MQTT values only while a client sends one to
# R/<portal ID>/keepalive. A read-only MQTT driver may declare such topics in
# `mqtt_read_request_topics`, and FTW Core then lets it publish to them and to
# nothing else. Core applies this same rule (go/internal/drivers/
# mqtt_read_request.go in srcfl/ftw); change the two together.
MQTT_READ_REQUEST_NAMESPACE = "R"
MQTT_READ_REQUEST_TOPIC_MAX_BYTES = 256
MQTT_READ_REQUEST_PAYLOAD_MAX_BYTES = 1024
_MQTT_TOPIC_LEVEL_RE = re.compile(r"[!-~]+")


def mqtt_read_request_topic_error(topic: object) -> str:
    """Why `topic` cannot be a declared read request, or "" when it can.

    The first level must be exactly "R", Venus's read-request namespace. A
    literal first level alone is not enough: W/+/settings/... is a valid
    pattern and a Venus write. "+" stands for one whole level and "#" is
    refused. A level is printable ASCII without spaces.
    """
    if not isinstance(topic, str) or not topic:
        return f"MQTT read-request topic {topic!r} must be a non-empty string"
    if len(topic.encode("utf-8")) > MQTT_READ_REQUEST_TOPIC_MAX_BYTES:
        return (f"MQTT read-request topic {topic!r} is longer than "
                f"{MQTT_READ_REQUEST_TOPIC_MAX_BYTES} bytes")
    levels = topic.split("/")
    if levels[0] != MQTT_READ_REQUEST_NAMESPACE or len(levels) < 2:
        return (f"MQTT read-request topic {topic!r} must start with "
                f"{MQTT_READ_REQUEST_NAMESPACE}/, Venus's read-request namespace")
    for level in levels[1:]:
        if level == "+":
            continue
        if not _MQTT_TOPIC_LEVEL_RE.fullmatch(level) or "+" in level or "#" in level:
            return (f"MQTT read-request topic {topic!r} has level {level!r}; a level is "
                    "printable ASCII without spaces, and a wildcard is a whole '+' level")
    return ""


# A driver may tell a new owner what to switch on in the device before FTW can
# reach it: `setup_hint` in its DRIVER table, one plain sentence in the
# device's own menu words. FTW shows it on the device card and when a
# connection test fails. The signed channel copies it into the header Core
# reads; Core reads a bundled copy's DRIVER table with the pattern below
# (go/internal/drivers/catalog.go, driverBlockRe and pickString), which stops
# at the first double quote. So the hint is one double-quoted string with no
# double quote or backslash inside, and this check reads it the way Core does.
SETUP_HINT_MAX_CHARS = 140
_DRIVER_BLOCK_RE = re.compile(r"^[ \t]*DRIVER\s*=\s*\{(.*?)\n\}", re.M | re.S)
_SETUP_HINT_LINE_RE = re.compile(r"^[ \t]*setup_hint\s*=(.*)$", re.M)
_SETUP_HINT_VALUE_RE = re.compile(r'\s*"([^"\\\n]*)"\s*,?\s*(?:--.*)?')


def setup_hint(source: str) -> tuple[str, str]:
    """The DRIVER table's setup_hint and why it is invalid.

    Returns ("", "") when the driver declares none, (hint, "") when it
    declares a valid one, and ("", reason) when the declaration is wrong.
    """
    blocks = _DRIVER_BLOCK_RE.findall(source)
    if not blocks:
        if re.search(r"^[ \t]*setup_hint\s*=", source, re.M):
            return "", "setup_hint must sit in a DRIVER table"
        return "", ""
    lines = _SETUP_HINT_LINE_RE.findall(blocks[-1])
    if not lines:
        return "", ""
    if len(lines) > 1:
        return "", "DRIVER declares setup_hint more than once"
    match = _SETUP_HINT_VALUE_RE.fullmatch(lines[0])
    if not match:
        return "", ("setup_hint must be one double-quoted string on one line, "
                    "with no double quote or backslash inside")
    hint = match.group(1)
    if not hint.strip():
        return "", "setup_hint is empty: omit it, or say what to switch on"
    if hint != hint.strip() or "  " in hint:
        return "", "setup_hint has stray spaces"
    if any(ord(char) < 32 or ord(char) == 127 for char in hint):
        return "", "setup_hint holds a control character"
    if len(hint) > SETUP_HINT_MAX_CHARS:
        return "", (f"setup_hint is {len(hint)} characters; "
                    f"keep it to {SETUP_HINT_MAX_CHARS}")
    if not hint.endswith("."):
        return "", "setup_hint is one sentence and ends with a full stop"
    return hint, ""
