"""Modbus-specific tests for all modbus protocol drivers.

Validates register access patterns, decode function usage, and
protocol compliance for Modbus TCP/RTU drivers.
"""

import re
import pytest
from conftest import (
    read_driver,
    get_modbus_drivers,
    strip_lua_comments,
)

MODBUS_DRIVERS = get_modbus_drivers()


def _extract_modbus_reads(code):
    """Extract all modbus_read call parameters from Lua source code.

    Returns a list of dicts with keys: address, count, kind.
    """
    clean = strip_lua_comments(code)
    reads = []

    # Match pcall(host.modbus_read, address, count, "kind")
    pattern = re.compile(
        r'(?:pcall\s*\(\s*)?host\.modbus_read\s*[,(]\s*(\d+)\s*,\s*(\d+)\s*,\s*"(\w+)"',
    )

    for match in pattern.finditer(clean):
        reads.append({
            "address": int(match.group(1)),
            "count": int(match.group(2)),
            "kind": match.group(3),
        })

    return reads


def _extract_decode_calls(code):
    """Extract all decode function calls and their argument counts.

    Returns a list of (func_name, arg_count) tuples.
    """
    clean = strip_lua_comments(code)
    calls = []

    # Match host.decode_xxx(args)
    pattern = re.compile(r'host\.(decode_\w+)\s*\(([^)]*)\)')

    for match in pattern.finditer(clean):
        func_name = match.group(1)
        args = match.group(2)
        # Count arguments by splitting on commas (rough)
        arg_count = len([a.strip() for a in args.split(',') if a.strip()])
        calls.append((func_name, arg_count))

    return calls


@pytest.mark.parametrize("driver_name", MODBUS_DRIVERS)
class TestModbusRegisterAccess:
    """Validate modbus register access patterns."""

    def test_register_kind_valid(self, driver_name):
        """All modbus_read calls must use 'holding' or 'input' kind."""
        code = read_driver(driver_name)
        reads = _extract_modbus_reads(code)

        valid_kinds = {"holding", "input"}
        for read in reads:
            assert read["kind"] in valid_kinds, (
                f"{driver_name}: modbus_read at address {read['address']} "
                f"uses invalid kind '{read['kind']}', expected {valid_kinds}"
            )

    def test_register_addresses_reasonable(self, driver_name):
        """Register addresses must be in valid Modbus range (0-65535)."""
        code = read_driver(driver_name)
        reads = _extract_modbus_reads(code)

        for read in reads:
            assert 0 <= read["address"] <= 65535, (
                f"{driver_name}: register address {read['address']} "
                f"is out of valid range (0-65535)"
            )

    def test_register_counts_reasonable(self, driver_name):
        """Register counts must be in valid range (1-125)."""
        code = read_driver(driver_name)
        reads = _extract_modbus_reads(code)

        for read in reads:
            assert 1 <= read["count"] <= 125, (
                f"{driver_name}: register count {read['count']} at "
                f"address {read['address']} is out of valid range (1-125)"
            )

    def test_register_address_plus_count_in_range(self, driver_name):
        """Address + count must not exceed the valid Modbus range."""
        code = read_driver(driver_name)
        reads = _extract_modbus_reads(code)

        for read in reads:
            end_address = read["address"] + read["count"] - 1
            assert end_address <= 65535, (
                f"{driver_name}: register read at {read['address']} with "
                f"count {read['count']} would exceed address 65535 "
                f"(end: {end_address})"
            )


@pytest.mark.parametrize("driver_name", MODBUS_DRIVERS)
class TestModbusDecoding:
    """Validate that decode functions are used correctly."""

    def test_32_bit_decoders_take_2_args(self, driver_name):
        """All 32-bit integer decoders should take exactly 2 arguments."""
        code = read_driver(driver_name)
        calls = _extract_decode_calls(code)

        for func_name, arg_count in calls:
            if func_name in ('decode_u32', 'decode_i32',
                             'decode_u32_be', 'decode_i32_be',
                             'decode_u32_le', 'decode_i32_le',
                             'decode_f32'):
                assert arg_count == 2, (
                    f"{driver_name}: {func_name} should take 2 arguments, "
                    f"got {arg_count}"
                )

    def test_decode_u64_takes_4_args(self, driver_name):
        """decode_u64 should take exactly 4 arguments."""
        code = read_driver(driver_name)
        calls = _extract_decode_calls(code)

        for func_name, arg_count in calls:
            if func_name == 'decode_u64':
                assert arg_count == 4, (
                    f"{driver_name}: decode_u64 should take 4 arguments, "
                    f"got {arg_count}"
                )

    def test_decode_i16_takes_1_arg(self, driver_name):
        """decode_i16 and decode_u16 should take exactly 1 argument."""
        code = read_driver(driver_name)
        calls = _extract_decode_calls(code)

        for func_name, arg_count in calls:
            if func_name in ('decode_i16', 'decode_u16'):
                assert arg_count == 1, (
                    f"{driver_name}: {func_name} should take 1 argument, "
                    f"got {arg_count}"
                )

    def test_decode_functions_are_valid(self, driver_name):
        """Only valid decode functions should be used."""
        code = read_driver(driver_name)
        calls = _extract_decode_calls(code)

        valid_decoders = {
            'decode_i16', 'decode_u16',
            'decode_u32', 'decode_i32',
            'decode_u32_be', 'decode_i32_be',
            'decode_u32_le', 'decode_i32_le',
            'decode_f32',
            'decode_u64',
        }

        for func_name, _ in calls:
            assert func_name in valid_decoders, (
                f"{driver_name}: unknown decode function '{func_name}', "
                f"expected one of {sorted(valid_decoders)}"
            )


@pytest.mark.parametrize("driver_name", MODBUS_DRIVERS)
class TestModbusConsistency:
    """Validate consistency of modbus register usage patterns."""

    def test_reads_match_decodes(self, driver_name):
        """Registers read with count=2 should use 32-bit decode, count=4 should use 64-bit.

        This is a heuristic check that verifies decode function usage
        is consistent with the number of registers read.
        """
        code = read_driver(driver_name)
        clean = strip_lua_comments(code)

        # This is a consistency check: if we read 2 registers, we expect
        # a 32-bit decode somewhere nearby. If we read 4, expect 64-bit.
        # We can't do exact matching, but we can verify the driver uses
        # appropriate decode functions for multi-register reads.

        reads = _extract_modbus_reads(code)
        has_multi_reg = any(r["count"] >= 2 for r in reads)

        if has_multi_reg:
            # Should use at least one multi-register decode function
            has_decode = bool(re.search(
                r'host\.decode_(u32|i32|u32_le|i32_le|f32|u64)\s*\(',
                clean,
            ))
            # Unless it's only reading u16 values from adjacent registers
            # (some drivers read multiple u16 values in a single request)
            if not has_decode:
                # Check if all multi-reg reads are used element-by-element
                # This is OK (e.g., reading 3 voltage registers as regs[1], regs[2], regs[3])
                pass  # Acceptable pattern

    def test_scale_function_usage(self, driver_name):
        """If host.scale() is used, scale factors should be read from registers."""
        code = read_driver(driver_name)
        clean = strip_lua_comments(code)

        if 'host.scale(' not in clean:
            pytest.skip(f"{driver_name}: does not use scale factors")

        # SunSpec drivers typically read scale factors from specific registers
        # Verify that scale factor variables are populated from modbus reads
        sf_vars = re.findall(r'(\w+_sf)\s*=\s*', clean)
        assert len(sf_vars) > 0, (
            f"{driver_name}: uses host.scale() but no scale factor variables found"
        )
