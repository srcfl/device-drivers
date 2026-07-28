"""The boundary check must read the repository, not the disk under it.

A git worktree under .claude/worktrees/ is a second full checkout. It is
ignored, so it is not part of this repository, but a filesystem walk still
descends into it and reports its provenance files as violations at paths the
contributor never edited. That made `make check` unrunnable while a worktree
existed. These tests pin the enumeration to git.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import check_public_boundary as boundary  # noqa: E402

# Naming a forbidden string here would make this file fail the check it tests.
FORBIDDEN = sorted(boundary.FORBIDDEN_TEXT)[0]


def git(repo: Path, *args: str) -> None:
    subprocess.run(("git", *args), cwd=repo, check=True, capture_output=True)


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    """A small repository standing in for the public one."""
    git(tmp_path, "init", "-q")
    # Ignore the contributor's own global excludes, so the test asserts about
    # this repository's rules and not about the machine it runs on.
    git(tmp_path, "config", "core.excludesFile", "/dev/null")
    (tmp_path / "README.md").write_text("public\n", encoding="utf-8")
    git(tmp_path, "add", "README.md")
    return tmp_path


def test_an_ignored_worktree_is_not_scanned(repo: Path) -> None:
    (repo / ".gitignore").write_text(".claude/worktrees/\n", encoding="utf-8")
    git(repo, "add", ".gitignore")

    worktree = repo / ".claude" / "worktrees" / "copy"
    worktree.mkdir(parents=True)
    (worktree / "SOURCE_IMPORT.md").write_text(FORBIDDEN, encoding="utf-8")

    assert boundary.main(repo) == 0, (
        "a checkout git ignores was scanned as if it were this repository")


def test_a_tracked_file_still_fails(repo: Path) -> None:
    """The check keeps its bite on the files the repository does carry."""
    (repo / "notes.md").write_text(FORBIDDEN, encoding="utf-8")
    git(repo, "add", "notes.md")

    assert boundary.main(repo) == 1


def test_an_untracked_file_still_fails(repo: Path) -> None:
    """Work in progress is caught before it is staged, not after."""
    (repo / "notes.md").write_text(FORBIDDEN, encoding="utf-8")

    assert boundary.main(repo) == 1
