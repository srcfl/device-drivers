"""heishamon resets the heat curve offset only after FTW wrote one."""

from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[2]


def test_heishamon_default_mode_resets_only_what_ftw_wrote():
    result = subprocess.run(
        [str(ROOT / "lua55"), "drivers/tests/lua_harness/test_heishamon_offset_reset.lua"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
