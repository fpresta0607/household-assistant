"""The runbook's commands run as they are written.

On 2026-10-10 the first command of a deploy answered "Permission denied". The runbook
runs `scripts/openclaw-install.sh` and `scripts/openclaw-verify.sh` by their paths, and
git held them without the executable bit, which `git archive` carries to the box as it
is. The scripts under scripts/macos always had it.
"""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
RUNBOOK = ROOT / "docs" / "deploy" / "openclaw.md"

# A script run by its path at the start of a line, with or without settings before it.
DIRECT_COMMAND = re.compile(r"^(?:[A-Z_]+=\S+ )*(scripts/[\w./-]+\.sh)(?:\s|$)")


def scripts_run_by_path() -> list[str]:
    lines = RUNBOOK.read_text(encoding="utf-8").splitlines()
    return sorted({found.group(1) for line in lines if (found := DIRECT_COMMAND.match(line))})


def test_the_runbook_does_run_scripts_by_their_paths() -> None:
    """Without this the test below could pass by finding nothing to check."""
    assert "scripts/openclaw-install.sh" in scripts_run_by_path()
    assert "scripts/openclaw-verify.sh" in scripts_run_by_path()


@pytest.mark.parametrize("script", scripts_run_by_path())
def test_a_script_the_runbook_runs_by_its_path_is_executable_in_git(script: str) -> None:
    git = shutil.which("git")
    if git is None:
        pytest.skip("git is not installed")
    listed = subprocess.run(
        [git, "ls-files", "--stage", "--", script],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    if listed.returncode != 0:
        pytest.skip("not a git checkout")
    assert listed.stdout.strip(), f"{script} is not in git"
    mode = listed.stdout.split()[0]
    assert mode == "100755", f"{script} is {mode} in git, so `{script}` answers Permission denied"
