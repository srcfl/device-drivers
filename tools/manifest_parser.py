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
