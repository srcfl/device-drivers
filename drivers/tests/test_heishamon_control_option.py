"""heishamon: control: false keeps the driver read-only."""

from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[2]


def test_heishamon_control_false_is_read_only():
    result = subprocess.run(
        [str(ROOT / "lua55"), "drivers/tests/lua_harness/test_heishamon_control_option.lua"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
