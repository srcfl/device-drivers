"""Test that emitted fields match the host-api.md DER type specifications.

Each DER type has a defined set of valid field names. Drivers must only
emit fields that are recognized by the runtime. This prevents silent data
loss from typos in field names.

Field definitions from spec/host-api.md:
  Meter:       w, hz, l1_w..l3_w, l1_v..l3_v, l1_a..l3_a, import_wh, export_wh
  PV:          w, rated_w, hv_lv, mppt1_v, mppt1_a, mppt2_v, mppt2_a, temp_c,
               lifetime_wh, lower_limit_w, upper_limit_w
  Battery:     w, v, a, soc, temp_c, charge_wh, discharge_wh,
               upper_limit_w, lower_limit_w
  V2X Charger: w, a, v, hz, l1_a..l3_a, l1_v..l3_v, l1_w..l3_w,
               dc_w, dc_a, dc_v, vehicle_soc_fract,
               ev_max_energy_req_wh, ev_min_energy_req_wh,
               session_charge_wh, session_discharge_wh,
               total_charge_wh, total_discharge_wh,
               capacity_wh, rated_power_w
"""

import re
import pytest
from conftest import (
    read_driver,
    get_driver_names,
    strip_lua_comments,
    extract_emit_calls,
)

DRIVERS = get_driver_names()

# Valid field names per DER type (lowercase).
# From spec/host-api.md plus additional fields used by existing drivers.
# Fields marked "ext" are used by drivers but not yet in the formal spec.
VALID_FIELDS = {
    "meter": {
        "w", "hz",
        "l1_w", "l2_w", "l3_w",
        "l1_v", "l2_v", "l3_v",
        "l1_a", "l2_a", "l3_a",
        "import_wh", "export_wh",
        # Legacy naming used by core drivers (Ferroamp, P1, Ambibox)
        "total_import_wh", "total_export_wh",
    },
    "pv": {
        "w", "rated_w", "hv_lv",
        "mppt1_v", "mppt1_a",
        "mppt2_v", "mppt2_a",
        "temp_c", "lifetime_wh",
        "lower_limit_w", "upper_limit_w",
    },
    "battery": {
        "w", "v", "a", "soc",
        "temp_c", "charge_wh", "discharge_wh",
        "upper_limit_w", "lower_limit_w",
        # Ferroamp, Ambibox nominal SoC
        "soc_nom_fract",
    },
    "v2x_charger": {
        "w", "a", "v", "hz",
        "l1_a", "l2_a", "l3_a",
        "l1_v", "l2_v", "l3_v",
        "l1_w", "l2_w", "l3_w",
        "dc_w", "dc_a", "dc_v",
        "vehicle_soc_fract",
        "ev_max_energy_req_wh", "ev_min_energy_req_wh",
        "session_charge_wh", "session_discharge_wh",
        "total_charge_wh", "total_discharge_wh",
        "capacity_wh", "rated_power_w",
        # Extended V2X fields used by existing EV charger drivers
        "session_wh",  # Simplified session energy (many charger drivers)
        "state",  # Charger state (idle/connected/charging/error)
        "max_a",  # Maximum current limit
        # Ambibox-specific fields
        "charge_power_min_w", "charge_power_max_w",
        "discharge_power_min_w", "discharge_power_max_w",
        "plug_connected",
    },
}


def _extract_inline_emit_fields(code, der_type):
    """Extract field names from inline host.emit("type", { ... }) calls.

    Returns a list of field names found in the table literal, or None if
    the emit uses a variable reference instead of an inline table.
    """
    clean = strip_lua_comments(code)

    # Match host.emit("der_type", { ... }) with inline table
    pattern = re.compile(
        rf'host\.emit\s*\(\s*"{re.escape(der_type)}"\s*,\s*\{{([^}}]*)\}}',
        re.DOTALL,
    )

    all_fields = []
    for match in pattern.finditer(clean):
        table_body = match.group(1)
        # Extract field = value assignments
        field_pattern = re.compile(r'(\w+)\s*=')
        fields = [m.group(1) for m in field_pattern.finditer(table_body)]
        all_fields.extend(fields)

    return all_fields if all_fields else None


def _extract_variable_emit_fields(code, der_type):
    """Extract field names from variable-based host.emit("type", var) calls.

    Looks for var.field = value patterns preceding the emit call.
    """
    clean = strip_lua_comments(code)

    # Match host.emit("der_type", variable_name)
    pattern = re.compile(
        rf'host\.emit\s*\(\s*"{re.escape(der_type)}"\s*,\s*(\w+)\s*\)',
    )

    all_fields = []
    for match in pattern.finditer(clean):
        var_name = match.group(1)
        # Find var_name.field = assignments
        assign_pattern = re.compile(
            rf'\b{re.escape(var_name)}\.(\w+)\s*='
        )
        for assign_match in assign_pattern.finditer(clean):
            field = assign_match.group(1)
            if field not in all_fields:
                all_fields.append(field)

        # Also check for inline table construction: local var = { field = ... }
        table_pattern = re.compile(
            rf'local\s+{re.escape(var_name)}\s*=\s*\{{([^}}]*)\}}',
            re.DOTALL,
        )
        for table_match in table_pattern.finditer(clean):
            table_body = table_match.group(1)
            field_pat = re.compile(r'(\w+)\s*=')
            for fm in field_pat.finditer(table_body):
                field = fm.group(1)
                if field not in all_fields:
                    all_fields.append(field)

    return all_fields if all_fields else None


@pytest.mark.parametrize("driver_name", DRIVERS)
class TestEmitFields:
    """Validate that emitted fields are recognized for each DER type."""

    def _get_fields_for_der(self, driver_name, der_type):
        """Get the list of field names emitted for a given DER type."""
        code = read_driver(driver_name)
        fields = _extract_inline_emit_fields(code, der_type)
        if fields is None:
            fields = _extract_variable_emit_fields(code, der_type)
        return fields

    def test_meter_fields_valid(self, driver_name):
        """All meter emit fields must be in the valid field set."""
        fields = self._get_fields_for_der(driver_name, "meter")
        if fields is None:
            pytest.skip(f"{driver_name}: no meter emit found or uses dynamic fields")

        # Normalize to lowercase for comparison
        fields_lower = [f.lower() for f in fields]
        valid = VALID_FIELDS["meter"]

        invalid = [f for f in fields_lower if f not in valid]
        if invalid:
            # Check if they might be valid with different casing
            # Some drivers use mixed case like W, Hz, L1_W etc.
            still_invalid = [f for f in invalid if f.lower() not in valid]
            assert not still_invalid, (
                f"{driver_name}: meter emits unknown fields: {still_invalid}. "
                f"Valid fields: {sorted(valid)}"
            )

    def test_pv_fields_valid(self, driver_name):
        """All PV emit fields must be in the valid field set."""
        fields = self._get_fields_for_der(driver_name, "pv")
        if fields is None:
            pytest.skip(f"{driver_name}: no PV emit found or uses dynamic fields")

        fields_lower = [f.lower() for f in fields]
        valid = VALID_FIELDS["pv"]

        invalid = [f for f in fields_lower if f not in valid]
        if invalid:
            still_invalid = [f for f in invalid if f.lower() not in valid]
            assert not still_invalid, (
                f"{driver_name}: PV emits unknown fields: {still_invalid}. "
                f"Valid fields: {sorted(valid)}"
            )

    def test_battery_fields_valid(self, driver_name):
        """All battery emit fields must be in the valid field set."""
        fields = self._get_fields_for_der(driver_name, "battery")
        if fields is None:
            pytest.skip(f"{driver_name}: no battery emit found or uses dynamic fields")

        fields_lower = [f.lower() for f in fields]
        valid = VALID_FIELDS["battery"]

        invalid = [f for f in fields_lower if f not in valid]
        if invalid:
            still_invalid = [f for f in invalid if f.lower() not in valid]
            assert not still_invalid, (
                f"{driver_name}: battery emits unknown fields: {still_invalid}. "
                f"Valid fields: {sorted(valid)}"
            )

    def test_v2x_charger_fields_valid(self, driver_name):
        """All V2X charger emit fields must be in the valid field set."""
        fields = self._get_fields_for_der(driver_name, "v2x_charger")
        if fields is None:
            pytest.skip(
                f"{driver_name}: no V2X charger emit found or uses dynamic fields"
            )

        fields_lower = [f.lower() for f in fields]
        valid = VALID_FIELDS["v2x_charger"]

        invalid = [f for f in fields_lower if f not in valid]
        if invalid:
            still_invalid = [f for f in invalid if f.lower() not in valid]
            assert not still_invalid, (
                f"{driver_name}: V2X charger emits unknown fields: "
                f"{still_invalid}. Valid fields: {sorted(valid)}"
            )

    def test_meter_has_required_w(self, driver_name):
        """Meter emit must include at least the 'w' field."""
        fields = self._get_fields_for_der(driver_name, "meter")
        if fields is None:
            pytest.skip(f"{driver_name}: no meter emit found")

        fields_lower = [f.lower() for f in fields]
        assert "w" in fields_lower, (
            f"{driver_name}: meter emit missing required 'w' field. "
            f"Found: {fields}"
        )

    def test_pv_has_required_w(self, driver_name):
        """PV emit must include at least the 'w' field."""
        fields = self._get_fields_for_der(driver_name, "pv")
        if fields is None:
            pytest.skip(f"{driver_name}: no PV emit found")

        fields_lower = [f.lower() for f in fields]
        assert "w" in fields_lower, (
            f"{driver_name}: PV emit missing required 'w' field. "
            f"Found: {fields}"
        )

    def test_battery_has_required_w(self, driver_name):
        """Battery emit must include at least the 'w' field."""
        fields = self._get_fields_for_der(driver_name, "battery")
        if fields is None:
            pytest.skip(f"{driver_name}: no battery emit found")

        fields_lower = [f.lower() for f in fields]
        assert "w" in fields_lower, (
            f"{driver_name}: battery emit missing required 'w' field. "
            f"Found: {fields}"
        )

    def test_v2x_charger_has_required_w(self, driver_name):
        """V2X charger emit must include at least the 'w' field."""
        fields = self._get_fields_for_der(driver_name, "v2x_charger")
        if fields is None:
            pytest.skip(f"{driver_name}: no V2X charger emit found")

        fields_lower = [f.lower() for f in fields]
        assert "w" in fields_lower, (
            f"{driver_name}: V2X charger emit missing required 'w' field. "
            f"Found: {fields}"
        )
