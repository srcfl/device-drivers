"""The H3-Smart control v2 entrypoints must prove what they claim.

The control v2 contract (srcfl/ftw#738/#741) makes a driver's word
checkable: a command result is a structured table, "applied" is only
believed alongside host-observed write evidence, and default mode must
write the release and read it back rather than assert it. These tests
drive `driver_command_v2` / `driver_default_mode_v2` against the mock
harness and hold the results to that contract — statuses, codes,
device_state, the evidence list, and the registers actually written.

The v1 entrypoints stay for local operator builds (an unsigned driver
never sees a write scope), so coexistence is asserted too.
"""

from __future__ import annotations

from test_foxess_h3_smart import DRIVER, fixture_registers, run_lua

PV_W = 3121 + 3475
EFF = 0.977

RESULT_REPORT = """
local function show(r)
  print("STATUS " .. tostring(r.status))
  print("CODE " .. tostring(r.code))
  print("STATE " .. tostring(r.device_state))
  local ev = r.evidence or {}
  print("EVIDENCE " .. table.concat(ev, ","))
  if r.applied then
    print("APPLIED_POWER " .. tostring(r.applied.power_w))
    print("APPLIED_VENDOR " .. tostring(r.applied.vendor_setpoint_w))
  end
end
"""

RC_REPORT = """
print("RC_ENABLE " .. tostring(host._modbus_registers.holding[46001]))
print("RC_TIMEOUT " .. tostring(host._modbus_registers.holding[46002]))
print("SP_HI " .. tostring(host._modbus_registers.holding[46003]))
print("SP_LO " .. tostring(host._modbus_registers.holding[46004]))
"""


def drive(body: str, extra: str = "") -> dict[str, str]:
    return run_lua(f"""
{fixture_registers()}
host._modbus_registers.holding[46018] = {{0, 6000}}
{extra}
dofile("{DRIVER}")
driver_init({{}})
local ok, err = pcall(driver_poll)
if not ok then print("POLL_ERROR " .. tostring(err)) os.exit(1) end
{RESULT_REPORT}
{body}
{RC_REPORT}
""")


def setpoint(out: dict[str, str]) -> int:
    raw = (int(out["SP_HI"]) << 16) | int(out["SP_LO"])
    return raw - (1 << 32) if raw >= (1 << 31) else raw


def test_v2_discharge_applies_with_evidence():
    out = drive("""
show(driver_command_v2({ command = "battery",
                         inputs = { power_w = -1000 } }))
""")
    assert out["STATUS"] == "applied"
    assert out["CODE"] == "ok"
    assert out["STATE"] == "controlled"
    assert out["EVIDENCE"] == "write_ack,readback"
    # AC setpoint = pv * eff - target, rounded to whole watts.
    expect = round(PV_W * EFF) + 1000
    assert setpoint(out) == expect
    assert out["APPLIED_POWER"] == "-1000"
    assert out["APPLIED_VENDOR"] == str(expect)
    assert out["RC_ENABLE"] == "1"
    assert out["RC_TIMEOUT"] == "60"


def test_v2_charge_into_full_battery_is_rejected():
    out = drive("""
show(driver_command_v2({ command = "battery",
                         inputs = { power_w = 1000 } }))
""", extra="host._modbus_registers.holding[37612] = 100")
    assert out["STATUS"] == "rejected"
    assert out["CODE"] == "battery_full"
    assert out["STATE"] == "unchanged"
    assert out["RC_ENABLE"] == "nil"  # never engaged


def test_v2_undeclared_command_is_rejected():
    out = drive('show(driver_command_v2({ command = "flux_capacitor" }))')
    assert out["STATUS"] == "rejected"
    assert out["CODE"] == "undeclared_command"


def test_v2_missing_input_is_rejected():
    out = drive('show(driver_command_v2({ command = "battery", inputs = {} }))')
    assert out["STATUS"] == "rejected"
    assert out["CODE"] == "missing_input"


def test_v2_write_failure_is_failed_not_applied():
    """The host bindings return an error string instead of raising; a
    driver that only pcall-guards its writes would report this exact
    case as success."""
    out = drive("""
host._modbus_write_error = "simulated bus failure"
show(driver_command_v2({ command = "battery",
                         inputs = { power_w = -1000 } }))
""")
    assert out["STATUS"] == "failed"
    assert out["CODE"] == "write_failed"
    assert out["STATE"] == "unknown"


def test_v2_readback_failure_is_not_applied():
    out = drive("""
host._modbus_read_fail_addresses[46003] = "timeout"
show(driver_command_v2({ command = "battery",
                         inputs = { power_w = -1000 } }))
""")
    assert out["STATUS"] == "failed"
    assert out["CODE"] == "readback_mismatch"


def test_v2_default_mode_writes_and_proves_the_release():
    out = drive("""
driver_command_v2({ command = "battery", inputs = { power_w = -1000 } })
show(driver_default_mode_v2({ reason = "lease_expired" }))
""")
    assert out["STATUS"] == "defaulted"
    assert out["STATE"] == "default"
    assert out["EVIDENCE"] == "write_ack,readback"
    assert out["RC_ENABLE"] == "0"


def test_v2_default_mode_write_failure_reports_failed():
    out = drive("""
driver_command_v2({ command = "battery", inputs = { power_w = -1000 } })
host._modbus_write_error = "simulated bus failure"
show(driver_default_mode_v2({ reason = "lease_expired" }))
""")
    assert out["STATUS"] == "failed"
    assert out["CODE"] == "write_failed"
    assert out["STATE"] == "unknown"


def test_v1_entrypoints_still_serve_local_builds():
    out = drive("""
local r = driver_command("battery", 0)
print("V1_RESULT " .. tostring(r))
""")
    assert out["V1_RESULT"] == "true"
    assert out["RC_ENABLE"] == "1"
    assert setpoint(out) == round(PV_W * EFF)


NIGHT = """
host._modbus_registers.holding[39070] = 550
host._modbus_registers.holding[39072] = 480
host._modbus_registers.holding[39237] = 0
host._modbus_registers.holding[39238] = 0
pcall(driver_poll)
"""

IDLE_BAT = """
host._modbus_registers.holding[39237] = 0
host._modbus_registers.holding[39238] = 0
pcall(driver_poll)
"""


def test_night_charge_with_sleeping_bms_holds_and_waits():
    """A sleeping BMS limit must not fail the command — that released
    the session and put the inverter back to sleep, the loop that made
    grid charging never work at night (2026-08-18/19)."""
    out = drive(NIGHT + """
host._modbus_registers.holding[46018] = {0, 0}
local r = driver_command("battery", 2000)
print("V1_RESULT " .. tostring(r))
""")
    assert out["V1_RESULT"] == "true"       # accepted, not refused
    assert out["RC_ENABLE"] == "1"          # session stays up
    assert setpoint(out) == -200            # probe import, not full charge


def test_night_charge_applies_when_bms_wakes():
    out = drive(NIGHT + """
host._modbus_registers.holding[46018] = {0, 0}
driver_command("battery", 2000)
host._modbus_registers.holding[46018] = {0, 6000}
pcall(driver_poll)
print("MARK done")
""")
    # limit awake: night import setpoint = -(min(2000, 6000-200))
    assert setpoint(out) == -2000
    assert out["RC_ENABLE"] == "1"


PATIENCE_CYCLES = """
for _ = 1, 3 do
  host._millis_counter = host._millis_counter + 70000
  driver_command("battery", 2000)
  pcall(driver_poll)
end
print("MARK done")
"""


def test_night_charge_gives_up_after_patience_window():
    out = drive(NIGHT + """
host._modbus_registers.holding[46018] = {0, 0}
driver_command("battery", 2000)
""" + PATIENCE_CYCLES)
    assert out["RC_ENABLE"] == "0"          # released: genuine refusal


def test_daylight_low_limit_holds_and_waits():
    """0.9.5: the limit register follows battery ACTIVITY, not
    capability — an idle battery dozes off in daylight too (observed
    at 11-14% SoC with the sun up). Pending is universal: hold the
    probe gently (AC = pv - 200) and wait."""
    out = drive(IDLE_BAT + """
host._modbus_registers.holding[46018] = {0, 0}
local r = driver_command("battery", 2000)
print("V1_RESULT " .. tostring(r))
""")
    assert out["V1_RESULT"] == "true"
    assert out["RC_ENABLE"] == "1"
    assert setpoint(out) == round(PV_W * EFF) - 200  # probe under PV pass-through


def test_daylight_charge_applies_when_bms_wakes():
    out = drive(IDLE_BAT + """
host._modbus_registers.holding[46018] = {0, 0}
driver_command("battery", 2000)
host._modbus_registers.holding[46018] = {0, 6000}
pcall(driver_poll)
print("MARK done")
""")
    # limit awake: daylight vendor = pv * eff - target
    assert setpoint(out) == round(PV_W * EFF) - 2000


def test_daylight_pending_gives_up_after_patience_window():
    out = drive(IDLE_BAT + """
host._modbus_registers.holding[46018] = {0, 0}
driver_command("battery", 2000)
""" + PATIENCE_CYCLES)
    assert out["RC_ENABLE"] == "0"          # released: genuine refusal


def test_v2_night_charge_pending_is_accepted_not_applied():
    out = drive(NIGHT + """
host._modbus_registers.holding[46018] = {0, 0}
show(driver_command_v2({ command = "battery",
                         inputs = { power_w = 2000 } }))
""")
    assert out["STATUS"] == "accepted"
    assert out["CODE"] == "charge_pending_bms_wake"
    assert out["STATE"] == "controlled"
    assert out["EVIDENCE"] == "write_ack,readback"
    assert setpoint(out) == -200  # the probe, not the full charge


def _bat_charging(w):
    """Registers for a battery charging at `w` (vendor: negative)."""
    raw = (-w) & 0xFFFFFFFF
    return (f"host._modbus_registers.holding[39237] = {raw >> 16}\n"
            f"host._modbus_registers.holding[39238] = {raw & 0xFFFF}\n")


def test_pending_ramps_on_measured_uptake_with_dead_register():
    """2026-08-20 hardware finding: the pack charges at the probe level
    while the limit register stays flat 0 — capability must be read
    from measured uptake, one step per poll."""
    out = drive(NIGHT + """
host._modbus_registers.holding[46018] = {0, 0}
driver_command("battery", 2000)
""" + _bat_charging(210) + """
pcall(driver_poll)
print("SP1_HI " .. tostring(host._modbus_registers.holding[46003]))
print("SP1_LO " .. tostring(host._modbus_registers.holding[46004]))
""" + _bat_charging(650) + """
pcall(driver_poll)
print("MARK done")
""")
    sp1 = (int(out["SP1_HI"]) << 16) | int(out["SP1_LO"])
    sp1 = sp1 - (1 << 32) if sp1 >= (1 << 31) else sp1
    assert sp1 == -700                     # probe followed -> one step up
    assert setpoint(out) == -1200          # still following -> next step
    assert out["RC_ENABLE"] == "1"


def test_pending_ramp_decays_when_uptake_stalls():
    out = drive(NIGHT + """
host._modbus_registers.holding[46018] = {0, 0}
driver_command("battery", 2000)
""" + _bat_charging(210) + """
pcall(driver_poll)
""" + _bat_charging(650) + """
pcall(driver_poll)
""" + _bat_charging(100) + """
pcall(driver_poll)
print("MARK done")
""")
    assert setpoint(out) == -700           # 1200 decays one step, no reset


def test_pending_with_uptake_never_times_out():
    out = drive(NIGHT + """
host._modbus_registers.holding[46018] = {0, 0}
driver_command("battery", 2000)
""" + _bat_charging(210) + PATIENCE_CYCLES)
    assert out["RC_ENABLE"] == "1"         # charging = success in progress
