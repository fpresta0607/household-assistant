"""Voicebox: the local speech service holds its own invariants, asserted from here.

The service lives outside the household package because it runs on the Mac and
not on the VPS, and it is deliberately standard-library only. It is run as a
subprocess rather than imported so that a standard-library HTTP server does not
enter this suite's strict type-checking for no benefit.
"""

from __future__ import annotations

import os
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

from tests.capabilities import needs_posix_bash

ROOT = Path(__file__).resolve().parent.parent
SERVICE = ROOT / "services" / "voicebox" / "voicebox.py"
INSTALLER = ROOT / "scripts" / "macos" / "voicebox-install.sh"


def test_voicebox_selfcheck_passes() -> None:
    """Bind policy, argv expansion, request validation and a live loopback server.

    The bind policy is the one that matters: Voicebox speaks household
    conversation out loud, so it refuses a wildcard address outright and takes a
    private one only when told to. This fails if that stops being true.
    """
    result = subprocess.run(
        [sys.executable, str(SERVICE), "selfcheck"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "voicebox selfcheck passed" in result.stdout


def test_the_preview_phrase_is_the_one_the_brief_fixed() -> None:
    """Every document, script and benchmark reads this string from one place.

    Two engine measurements taken weeks apart are only comparable if the phrase
    they spoke is identical, so rewording it is a defect rather than an edit.
    """
    result = subprocess.run(
        [sys.executable, str(SERVICE), "phrase"],
        capture_output=True,
        text=True,
        check=True,
    )
    assert result.stdout.strip() == (
        "Good morning. I have reviewed your schedule and you have about an hour "
        "free before your next appointment."
    )


def render_job_description(**settings: str) -> dict[str, Any]:
    """The launchd job description the installer renders, parsed as a plist.

    A dry run writes nothing and loads nothing, so it renders the real job
    description on any machine with bash. The rendered plist is the installer's
    output contract - it is what launchd is handed - so it is read here from
    the dry run rather than inferred from the installer's shell source.
    """
    bash = shutil.which("bash")
    assert bash is not None, "bash renders the job description and CI has to have it"
    result = subprocess.run(
        [bash, INSTALLER.as_posix(), "--dry-run"],
        env={**os.environ, "HOME": "/tmp/voicebox-test-home", "HA_DRY_RUN": "0", **settings},
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    start = result.stderr.index("<?xml")
    end = result.stderr.index("</plist>") + len("</plist>")
    rendered = result.stderr[start:end]
    assert not re.search(r"@[A-Z_]+@", rendered), f"unreplaced placeholder in:\n{rendered}"
    job = plistlib.loads(rendered.encode("utf-8"))
    assert isinstance(job, dict), f"the job description is not a plist dictionary:\n{rendered}"
    return job


@needs_posix_bash
def test_the_dry_run_reports_that_it_installed_nothing(tmp_path: Path) -> None:
    """The docs put this run on the line above the real install, so it must not lie.

    It closed with `ok installed. Check it with voicebox-health.sh` and exit 0
    while writing no plist, copying no service and loading no agent, which is
    the last thing an owner reads before deciding the step is done.
    """
    bash = shutil.which("bash")
    assert bash is not None, "bash renders the job description and CI has to have it"
    home = tmp_path / "home"
    result = subprocess.run(
        [bash, INSTALLER.as_posix(), "--dry-run"],
        env={**os.environ, "HOME": home.as_posix(), "HA_DRY_RUN": "0"},
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert not home.exists(), f"a dry run created {home}"

    # The script's progress report is its user-facing output contract; every
    # step it announces here is one it did not take.
    reported = [line for line in result.stderr.splitlines() if line.startswith("ok ")]
    assert reported == [
        "ok     dry run complete. Nothing was written, nothing was copied and no agent was loaded."
    ], result.stderr
    would_run = [line for line in result.stderr.splitlines() if line.startswith("would run ")]
    assert any("launchctl bootout" in line for line in would_run), result.stderr
    assert any("launchctl bootstrap" in line for line in would_run), result.stderr


@needs_posix_bash
def test_the_installer_renders_a_job_description_launchd_can_load() -> None:
    """A placeholder the installer does not fill aborts every install.

    That is how c0228c4 broke: the template's own comment held a
    placeholder-shaped string, the installer's guard matched it, and the
    install died on a machine none of this can be run from. So this renders the
    real thing and asserts it is complete and that it parses.
    """
    job = render_job_description(
        HA_VOICEBOX_LABEL="com.example.test.voicebox",
        HA_VOICEBOX_ROOT="/tmp/voicebox-test-root",
        HA_VOICEBOX_LOGS="/tmp/voicebox-test-logs",
        HA_VOICEBOX_HOST="127.0.0.1",
        HA_VOICEBOX_PORT="8799",
    )
    assert job["Label"] == "com.example.test.voicebox"
    assert job["ProgramArguments"][1:] == ["/tmp/voicebox-test-root/voicebox.py", "serve"]
    assert job["StandardErrorPath"] == "/tmp/voicebox-test-logs/voicebox.err.log"
    assert job["EnvironmentVariables"]["VOICEBOX_HOST"] == "127.0.0.1"
    assert job["EnvironmentVariables"]["VOICEBOX_PORT"] == "8799"


@needs_posix_bash
def test_the_job_description_carries_the_variables_the_chosen_engine_needs() -> None:
    """An engine needs its settings under launchd, not only in the installing shell.

    `piper` reads its voice from `VOICEBOX_PIPER_MODEL`. When that reaches the
    job description the documented sequence works; when it does not, the
    service starts, reports its engine, and fails every single request.
    """
    job = render_job_description(
        VOICEBOX_ENGINE="piper",
        VOICEBOX_PIPER_MODEL="/tmp/voices/en_US.onnx",
        VOICEBOX_ALLOW_PRIVATE="1",
    )
    environment = job["EnvironmentVariables"]
    assert environment["VOICEBOX_ENGINE"] == "piper"
    assert environment["VOICEBOX_PIPER_MODEL"] == "/tmp/voices/en_US.onnx"
    assert environment["VOICEBOX_ALLOW_PRIVATE"] == "1"


@needs_posix_bash
def test_an_unset_variable_is_left_out_rather_than_written_empty() -> None:
    """An engine handed an empty path is worse off than one handed nothing."""
    job = render_job_description(VOICEBOX_ENGINE="", VOICEBOX_PIPER_MODEL="")
    assert "VOICEBOX_ENGINE" not in job["EnvironmentVariables"]
    assert "VOICEBOX_PIPER_MODEL" not in job["EnvironmentVariables"]
    assert job["EnvironmentVariables"]["PYTHONUNBUFFERED"] == "1"
