"""Pin the reviewed Ferroamp DC2 V2X import delta to the host field contract."""

from conftest import read_driver


def test_ferroamp_dc2_uses_host_v2x_power_limit_fields() -> None:
    code = read_driver("ferroamp_dc2_v2x")
    expected = {
        'charger.charge_power_max_W = snum("ev/limits/max_power")',
        'charger.charge_power_min_W = snum("ev/limits/min_power")',
        'charger.discharge_power_max_W = snum("ev/limits/max_discharge_power")',
    }
    legacy = {
        "charger.ev_max_power_W",
        "charger.ev_min_power_W",
        "charger.ev_max_discharge_power_W",
    }
    assert all(field in code for field in expected)
    assert all(field not in code for field in legacy)
