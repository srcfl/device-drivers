"""A driver badged "Control" must be able to control something.

`control` is the manifest field the catalog page turns into a **Control**
badge, and it is the first thing an owner reads when deciding whether a driver
can run their battery or their heat pump. Five drivers carried `control: true`
while their `driver_command` was an unconditional refusal -- three of them
saying so in a comment on the line above the `return false`.

Nothing caught it, because nothing compared the claim against the code. The
signed channel does not settle it either: it infers control from the mere
presence of a `driver_command` entrypoint, so a stub that always refuses reads
to it as a control path.

This is the narrow, checkable half of that question: a command entrypoint that
cannot call anything cannot actuate anything, whatever the manifest says.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Keywords that open a Lua block, for balancing against `end`.
OPENERS = re.compile(r"\b(function|if|for|while|do)\b")
CLOSERS = re.compile(r"\bend\b")
ELSEIF = re.compile(r"\belseif\b")
CALL = re.compile(r"\b([A-Za-z_][A-Za-z_0-9.]*)\s*\(")
NOT_A_CALL = {"function", "if", "while", "for", "return", "and", "or", "not"}


def control_flag(manifest: Path) -> str:
    for line in manifest.read_text(encoding="utf-8").splitlines():
        if line.startswith("control:"):
            return line.split(":", 1)[1].strip()
    return ""


def function_source(text: str, name: str) -> str | None:
    """The source of a top-level `function name(...) ... end`, or None."""
    start = re.search(rf"^function\s+{re.escape(name)}\s*\(", text, re.M)
    if not start:
        return None
    depth = 0
    collected: list[str] = []
    for line in text[start.start():].split("\n"):
        collected.append(line)
        code = re.sub(r"--.*$", "", line)
        depth += len(OPENERS.findall(code))
        depth -= len(CLOSERS.findall(code))
        depth -= len(ELSEIF.findall(code))
        if len(collected) > 1 and depth <= 0:
            break
    return "\n".join(collected)


def is_inert(body: str) -> bool:
    """Whether a function body can do nothing at all.

    Inert means it calls nothing: no host call, no helper, no dispatch. Such a
    body can only fall through to its `return`, so it cannot reach a write no
    matter what it is handed.
    """
    # Drop the declaration line: `function driver_command(...)` is the
    # signature, not a call, and counting it made every body look busy.
    lines = re.sub(r"--.*$", "", body, flags=re.M).split("\n")[1:]
    code = "\n".join(line for line in lines if line.strip())
    calls = [c for c in CALL.findall(code) if c not in NOT_A_CALL]
    return not calls


def test_a_control_driver_has_a_command_that_can_do_something() -> None:
    inert = []
    for manifest in sorted((ROOT / "manifests").glob("*.yaml")):
        if control_flag(manifest) != "true":
            continue
        source = ROOT / "drivers" / "lua" / f"{manifest.stem}.lua"
        body = function_source(source.read_text(encoding="utf-8"), "driver_command")
        if body is not None and is_inert(body):
            inert.append(manifest.stem)

    assert not inert, (
        "these manifests claim control: true, but their driver_command calls "
        f"nothing and so can never actuate: {inert}. Either the driver has a "
        "control path its command entrypoint does not reach, or the manifest "
        "should say control: false.")


def test_the_check_can_still_see_a_real_control_path() -> None:
    """A guard that flags nothing would pass just as quietly if it broke."""
    controlling = []
    for manifest in sorted((ROOT / "manifests").glob("*.yaml")):
        if control_flag(manifest) != "true":
            continue
        source = ROOT / "drivers" / "lua" / f"{manifest.stem}.lua"
        body = function_source(source.read_text(encoding="utf-8"), "driver_command")
        if body is not None and not is_inert(body):
            controlling.append(manifest.stem)

    assert len(controlling) >= 20, (
        "almost no driver reads as controlling, so this check has stopped "
        f"measuring anything: {controlling}")


def test_a_refusal_stub_is_recognised_as_inert() -> None:
    """The shape the five carried, so the guard is pinned to it directly."""
    assert is_inert(
        "function driver_command(_action, _power_w, _cmd)\n"
        "    -- Read-only: no actuation.\n"
        "    return false\n"
        "end")
    # Accepting the lifecycle actions without acting on them is still inert.
    assert is_inert(
        "function driver_command(action)\n"
        '    if action == "init" or action == "deinit" then return true end\n'
        "    return false\n"
        "end")
    # Reaching any call at all is not.
    assert not is_inert(
        "function driver_command(action, value)\n"
        "    return host.modbus_write(40001, value)\n"
        "end")
