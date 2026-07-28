"""Shared fixtures and utilities for driver test suite."""

import os
import glob
import hashlib
import pytest

DRIVERS_DIR = os.path.join(os.path.dirname(__file__), "..", "lua")
MANIFESTS_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "manifests")
BASELINE_DIR = os.path.join(os.path.dirname(__file__), "..", "..",
                            "baselines", "ftw", "drivers")


def _digest(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def ftw_sourced_drivers():
    """Drivers that are byte-identical to FTW's field-proven version.

    These have run on customer sites for months and FTW tests them in Go, so
    this suite's conventions -- which were written for the catalog and describe
    a dialect FTW never spoke -- do not apply to them.

    Identity is by content, not by a list. Edit a promoted driver here and it
    stops matching, and every check in this suite starts applying to it again.
    """
    if not os.path.isdir(BASELINE_DIR):
        return frozenset()
    sourced = set()
    for baseline in glob.glob(os.path.join(BASELINE_DIR, "*.lua")):
        name = os.path.splitext(os.path.basename(baseline))[0]
        promoted = os.path.join(DRIVERS_DIR, f"{name}.lua")
        if os.path.exists(promoted) and _digest(promoted) == _digest(baseline):
            sourced.add(name)
    return frozenset(sourced)


FTW_SOURCED = ftw_sourced_drivers()


def valid_ders():
    """The DER vocabulary, read from the tool that enforces it.

    Two tests used to hand-maintain their own copy of this set, and both were
    left behind when `ev`, `heatpump` and `vehicle` were added for the drivers
    promoted from FTW. Nothing noticed, because every driver emitting one of
    those was byte-identical to its baseline and therefore exempt. Editing one
    for any reason made two unrelated tests fail on a rule that had already
    been changed to allow it.
    """
    import re
    path = os.path.join(os.path.dirname(__file__), "..", "..",
                        "tools", "validate_manifest.py")
    with open(path) as handle:
        match = re.search(r"^VALID_DERS\s*=\s*\{([^}]*)\}", handle.read(), re.M)
    assert match, "VALID_DERS not found in tools/validate_manifest.py"
    return {name.strip().strip('"\'') for name in match.group(1).split(",")
            if name.strip()}


def skip_if_ftw_sourced(name):
    """Skip a catalog-convention check for a driver FTW owns and tests."""
    if name in FTW_SOURCED:
        pytest.skip(f"{name} is FTW's driver verbatim; FTW tests it in Go")


def pytest_configure(config):
    config.addinivalue_line(
        "markers",
        "holds_for_ftw_drivers: this check describes runtime behaviour rather "
        "than a catalog convention, so a driver promoted from FTW is not "
        "exempt from it")


def pytest_collection_modifyitems(items):
    """Skip catalog-convention checks for the drivers FTW owns.

    Applied here rather than in each test so that a driver promoted from FTW
    is exempt everywhere at once, and stops being exempt the moment someone
    edits it and it no longer matches the baseline.

    The exemption covers conventions this repository grew and FTW never spoke:
    spelling, key names, structure. It must not cover a rule about what the
    driver does on hardware. A check marked `holds_for_ftw_drivers` applies to
    every driver, promoted or not — the flap that took Pixii and SolarEdge
    legacy offline lived in promoted drivers, and a blanket exemption is what
    kept anyone from seeing it.
    """
    if not FTW_SOURCED:
        return
    reason = pytest.mark.skip(
        reason="FTW's driver verbatim; FTW tests it in Go")
    for item in items:
        if item.get_closest_marker("holds_for_ftw_drivers"):
            continue
        params = getattr(getattr(item, "callspec", None), "params", {})
        for value in params.values():
            name = getattr(value, "stem", None) or (
                value if isinstance(value, str) else None)
            if name in FTW_SOURCED:
                item.add_marker(reason)
                break


@pytest.fixture
def all_driver_files():
    """Return list of all .lua driver file paths."""
    return sorted(glob.glob(os.path.join(DRIVERS_DIR, "*.lua")))


@pytest.fixture
def all_manifest_files():
    """Return list of all .yaml manifest file paths."""
    return sorted(glob.glob(os.path.join(MANIFESTS_DIR, "*.yaml")))


@pytest.fixture
def driver_names():
    """Return sorted list of driver names (without extension)."""
    files = glob.glob(os.path.join(DRIVERS_DIR, "*.lua"))
    return sorted(os.path.splitext(os.path.basename(f))[0] for f in files)


def read_driver(name):
    """Read a driver's Lua source code."""
    path = os.path.join(DRIVERS_DIR, f"{name}.lua")
    with open(path) as f:
        return f.read()


def read_manifest(name):
    """Read and parse a manifest's YAML content."""
    path = os.path.join(MANIFESTS_DIR, f"{name}.yaml")
    with open(path) as f:
        return f.read()


def get_driver_names():
    """Get all driver names for parametrization."""
    files = glob.glob(os.path.join(DRIVERS_DIR, "*.lua"))
    return sorted(os.path.splitext(os.path.basename(f))[0] for f in files)


def get_manifest_names():
    """Get all manifest names for parametrization."""
    files = glob.glob(os.path.join(MANIFESTS_DIR, "*.yaml"))
    return sorted(os.path.splitext(os.path.basename(f))[0] for f in files)


def get_driver_protocol(name):
    """Extract the PROTOCOL value from a driver's source code."""
    import re
    code = read_driver(name)
    match = re.search(r'^PROTOCOL\s*=\s*"([^"]*)"', code, re.MULTILINE)
    return match.group(1) if match else None


def get_modbus_drivers():
    """Get names of all modbus-protocol drivers."""
    return [n for n in get_driver_names() if get_driver_protocol(n) == "modbus"]


def get_http_drivers():
    """Get names of all http-protocol drivers."""
    return [n for n in get_driver_names() if get_driver_protocol(n) == "http"]


def get_mqtt_drivers():
    """Get names of all mqtt-protocol drivers."""
    return [n for n in get_driver_names() if get_driver_protocol(n) == "mqtt"]


def strip_lua_comments(code):
    """Remove Lua single-line comments from code.

    Handles both -- single-line and --[[ block ]] comments.
    Preserves string contents.
    """
    import re
    # Remove block comments first
    code = re.sub(r'--\[\[.*?\]\]', '', code, flags=re.DOTALL)
    # Remove single-line comments (but not inside strings)
    lines = code.split('\n')
    cleaned = []
    for line in lines:
        # Simple approach: remove -- comments that aren't inside strings
        # Find -- that is not inside a quoted string
        result = []
        in_string = False
        string_char = None
        i = 0
        while i < len(line):
            c = line[i]
            if in_string:
                result.append(c)
                if c == string_char:
                    in_string = False
                elif c == '\\':
                    # Skip escaped character
                    i += 1
                    if i < len(line):
                        result.append(line[i])
            elif c == '"' or c == "'":
                in_string = True
                string_char = c
                result.append(c)
            elif c == '-' and i + 1 < len(line) and line[i + 1] == '-':
                # Comment starts here, skip rest of line
                break
            else:
                result.append(c)
            i += 1
        cleaned.append(''.join(result))
    return '\n'.join(cleaned)


def extract_emit_calls(code):
    """Extract all host.emit() calls from Lua source code.

    Returns a list of (der_type, [field_names]) tuples.
    Uses regex to parse the Lua table literals inside emit calls.
    """
    import re

    clean = strip_lua_comments(code)
    results = []

    # Find all host.emit("type", { ... }) patterns
    # Match host.emit("type", table_var) or host.emit("type", { ... })
    emit_pattern = re.compile(
        r'host\.emit\s*\(\s*"(\w+)"\s*,\s*(\{[^}]*\}|\w+)\s*\)',
        re.DOTALL,
    )
    for match in emit_pattern.finditer(clean):
        der_type = match.group(1)
        table_content = match.group(2)

        fields = []
        if table_content.startswith('{'):
            # Parse field names from table literal
            field_pattern = re.compile(r'(\w+)\s*=')
            for field_match in field_pattern.finditer(table_content):
                fields.append(field_match.group(1))
        else:
            # Variable reference - we can't easily extract fields
            # Try to find the table construction for this variable
            var_name = table_content.strip()
            # Look for var_name.field = or var_name["field"] = patterns
            assign_pattern = re.compile(
                rf'{re.escape(var_name)}\.(\w+)\s*='
            )
            for assign_match in assign_pattern.finditer(clean):
                field = assign_match.group(1)
                if field not in fields:
                    fields.append(field)

        results.append((der_type, fields))

    return results
