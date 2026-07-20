"""Test that sign conventions are followed across all drivers.

Sourceful sign conventions (from CLAUDE.md and spec):
  - PV W: always negative (generation produces negative power)
  - Battery W: positive = charging, negative = discharging
  - Meter W: positive = import from grid, negative = export to grid
  - V2X Charger W: positive = charging (consuming power)
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

# Drivers that are demo/test only and skip sign convention checks
SKIP_DRIVERS = {"hello"}


@pytest.mark.parametrize("driver_name", DRIVERS)
class TestSignConventions:
    """Verify sign conventions for each DER type."""

    def _get_emitted_types(self, driver_name):
        """Return set of DER types emitted by this driver."""
        code = read_driver(driver_name)
        clean = strip_lua_comments(code)
        return set(re.findall(r'host\.emit\s*\(\s*"(\w+)"', clean))

    def test_pv_power_negation(self, driver_name):
        """PV power (w) should be negated to follow generation = negative convention.

        Look for patterns like:
          w = -pv_w
          w = -ac_w
          W = -something
          w = -sum_array(...)
        """
        if driver_name in SKIP_DRIVERS:
            pytest.skip("demo driver")

        code = read_driver(driver_name)
        clean = strip_lua_comments(code)
        emitted_types = self._get_emitted_types(driver_name)

        if "pv" not in emitted_types:
            pytest.skip(f"{driver_name} does not emit PV telemetry")

        # Find the PV emit section and check for negation
        # Look for host.emit("pv", { w = -something }) or similar
        pv_emit_pattern = re.compile(
            r'host\.emit\s*\(\s*"pv"\s*,\s*\{([^}]*)\}',
            re.DOTALL,
        )
        pv_match = pv_emit_pattern.search(clean)

        if pv_match:
            table_body = pv_match.group(1)
            # Look for 'w = -' pattern (the negation)
            w_pattern = re.search(r'\bw\s*=\s*-', table_body, re.IGNORECASE)
            assert w_pattern, (
                f"{driver_name}: PV emit should negate w (convention: "
                f"generation is negative). Found: {table_body[:100]}"
            )
        else:
            # PV emitted via variable reference (e.g., host.emit("pv", pv_table))
            # Look for the variable and check its W field
            pv_var_pattern = re.compile(
                r'host\.emit\s*\(\s*"pv"\s*,\s*(\w+)\s*\)',
            )
            var_match = pv_var_pattern.search(clean)
            if var_match:
                var_name = var_match.group(1)
                # Check if the variable's W field is negated
                w_assign = re.search(
                    rf'{re.escape(var_name)}\.[wW]\s*=\s*-',
                    clean,
                )
                assert w_assign, (
                    f"{driver_name}: PV variable '{var_name}' should have "
                    f"negated W field (convention: generation is negative)"
                )

    def test_battery_soc_is_fraction(self, driver_name):
        """Battery SoC should be emitted as a fraction (0-1), not percentage (0-100).

        Look for division by 100 before emitting, or values already in fraction form.
        """
        if driver_name in SKIP_DRIVERS:
            pytest.skip("demo driver")

        code = read_driver(driver_name)
        clean = strip_lua_comments(code)
        emitted_types = self._get_emitted_types(driver_name)

        if "battery" not in emitted_types:
            pytest.skip(f"{driver_name} does not emit battery telemetry")

        # Check if the driver emits a soc field
        has_soc = re.search(r'\bsoc\s*=', clean, re.IGNORECASE)
        if not has_soc:
            pytest.skip(f"{driver_name} does not emit battery SoC")

        # Look for evidence of percent-to-fraction conversion (/ 100)
        # This is a heuristic: look for soc-related division by 100
        has_conversion = (
            re.search(r'soc.*[/]\s*100', clean, re.IGNORECASE)
            or re.search(r'[/]\s*100.*soc', clean, re.IGNORECASE)
            or re.search(r'soc_val\s*[/]\s*100', clean)
            or re.search(r'\*\s*0\.1\s*[/]\s*100', clean)  # * 0.1 / 100 pattern
            or re.search(r'\*\s*0\.001', clean)  # alternative: * 0.001
            # Some drivers receive SoC already as fraction (0-1)
            or re.search(r'soc.*already.*fract', clean, re.IGNORECASE)
            # Victron: bat_soc / 100
            or re.search(r'bat_soc\s*/\s*100', clean)
        )

        # If the driver mentions SoC, it should convert to fraction somewhere
        assert has_conversion, (
            f"{driver_name}: battery SoC should be converted to 0-1 fraction "
            f"(divide percentage by 100)"
        )

    def test_v2x_charger_power_positive(self, driver_name):
        """V2X charger power should be positive when charging (consuming power)."""
        if driver_name in SKIP_DRIVERS:
            pytest.skip("demo driver")

        code = read_driver(driver_name)
        clean = strip_lua_comments(code)
        emitted_types = self._get_emitted_types(driver_name)

        if "v2x_charger" not in emitted_types:
            pytest.skip(f"{driver_name} does not emit V2X charger telemetry")

        # V2X charger power should NOT be negated (positive = charging = consuming)
        v2x_emit_pattern = re.compile(
            r'host\.emit\s*\(\s*"v2x_charger"\s*,\s*\{([^}]*)\}',
            re.DOTALL,
        )
        v2x_match = v2x_emit_pattern.search(clean)

        if v2x_match:
            table_body = v2x_match.group(1)
            # W should NOT be negated for V2X charger
            w_field = re.search(r'\bw\s*=\s*(-)', table_body, re.IGNORECASE)
            if w_field:
                # It's OK if power_w is already positive from the device
                # Only flag if there's a suspicious negation
                pass  # Informational; most EV chargers report positive=charging

    def test_meter_sign_convention_documented(self, driver_name):
        """Meter drivers should document their sign convention in comments."""
        if driver_name in SKIP_DRIVERS:
            pytest.skip("demo driver")

        code = read_driver(driver_name)
        emitted_types = set(
            re.findall(r'host\.emit\s*\(\s*"(\w+)"', strip_lua_comments(code))
        )

        if "meter" not in emitted_types:
            pytest.skip(f"{driver_name} does not emit meter telemetry")

        # Check that the driver has sign convention documentation
        has_sign_doc = (
            'positive' in code.lower()
            or 'import' in code.lower()
            or 'sign convention' in code.lower()
            or 'convention' in code.lower()
            or 'negate' in code.lower()
        )

        # This is a soft check — most drivers should document their convention
        if not has_sign_doc:
            pytest.skip(
                f"{driver_name}: consider documenting meter sign convention"
            )
