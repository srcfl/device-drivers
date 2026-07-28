"""A driver must not read a local it never declared.

Lua has no error for this. An undefined name is a global, a global that was
never assigned is `nil`, and `nil` in a condition is simply false — so a
mistyped or orphaned variable turns a branch off in complete silence. Nothing
in the toolchain complains: `luac -p` compiles it, the sandbox check allows it,
and the driver keeps emitting, just with one field quietly missing.

That is not hypothetical. Refactoring pixii to route its reads through one
helper rewrote conditions of the form `if ok_x and x_regs then`, but left the
three-term ones like `if ok_soc and soc_regs and soc_regs[1] ~= nil then`
untouched. `ok_soc` stopped existing, the condition became permanently false,
and the driver stopped reporting state of charge — while still emitting a
battery record, so every emit-count comparison stayed green. FTW's Go test
suite caught it; nothing in this repository did.

The check is deliberately narrow. It looks for names that follow this
repository's `local ok_*` / `local *_regs` conventions and are read without
ever being declared, which is where the mistake actually happens. A general
undefined-global analysis would need a real Lua parser and would fight with
`host`, `DRIVER` and the lifecycle functions.
"""

import re
from pathlib import Path

import pytest
from conftest import get_driver_names, read_driver, strip_lua_comments

ROOT = Path(__file__).resolve().parents[2]

# Names shaped like a local this repository would declare: a read guard or a
# register block. Anything else is out of scope for this check.
#
# The lookbehind keeps `host.write_registers` out of it — a field access is
# the host API, never a local this driver was supposed to declare.
CANDIDATE = re.compile(
    r"(?<![.\w])(ok_[a-z0-9_]+|[a-z][a-z0-9_]*_regs|[a-z][a-z0-9_]*_registers)\b")


def declared_locals(code: str) -> set[str]:
    """Every name bound by a `local` statement, including multiple assignment."""
    names = set()
    for line in re.findall(r"^\s*local\s+([^=\n]+?)(?:=|$)", code, re.M):
        for name in line.split(","):
            name = name.strip()
            if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
                names.add(name)
    # `for k, v in ...` and function parameters bind names too.
    for line in re.findall(r"^\s*for\s+([^=\n]+?)\s+(?:=|in)\s", code, re.M):
        for name in line.split(","):
            names.add(name.strip())
    for params in re.findall(r"function[^(]*\(([^)]*)\)", code):
        for name in params.split(","):
            name = name.strip()
            if name:
                names.add(name)
    return names


def driver_sources():
    sources = [(name, ROOT / "drivers" / "lua" / f"{name}.lua")
               for name in get_driver_names()]
    sources += [(f"package:{path.parent.parent.name}", path)
                for path in sorted((ROOT / "packages" / "v1").glob("*/targets/*.lua"))]
    return sources


@pytest.mark.holds_for_ftw_drivers
@pytest.mark.parametrize("name,path", driver_sources(), ids=lambda v: v if isinstance(v, str) else "")
def test_driver_declares_every_guard_it_reads(name, path):
    code = strip_lua_comments(
        read_driver(name) if not str(path).startswith(str(ROOT / "packages"))
        else path.read_text())
    declared = declared_locals(code)

    used = {}
    for line_number, line in enumerate(code.splitlines(), start=1):
        for match in CANDIDATE.finditer(line):
            used.setdefault(match.group(1), line_number)

    orphans = {n: line for n, line in used.items() if n not in declared}
    assert not orphans, (
        f"{name}: reads {sorted(orphans)} without declaring them. In Lua an "
        f"undeclared name is nil, so a condition using one is permanently "
        f"false and the branch never runs — silently. First seen at "
        f"{', '.join(f'{n}:{line}' for n, line in sorted(orphans.items()))}."
    )
