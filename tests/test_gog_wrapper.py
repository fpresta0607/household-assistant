"""deploy/openclaw/bin/gog: gog with the Steward app's Google sign-in when there is one.

The wrapper runs the real gog (`gog-bin` beside it) with GOG_ACCESS_TOKEN from
household-app's google-token.mjs when the gateway holds an in-app Google sign-in, and
exactly as installed otherwise. Here gog-bin and node are stand-ins that report what
they were given, so nothing reaches Google.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

from tests.capabilities import POSIX_BASH, needs_posix_bash

ROOT = Path(__file__).resolve().parent.parent
WRAPPER = ROOT / "deploy" / "openclaw" / "bin" / "gog"

FAKE_GOG = """#!/bin/sh
echo "args=$*"
echo "token=${GOG_ACCESS_TOKEN:-none}"
"""


def install(tmp_path: Path, *, node_says: str, node_exit: int = 0) -> tuple[Path, Path]:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    shutil.copy(WRAPPER, bin_dir / "gog")
    (bin_dir / "gog-bin").write_text(FAKE_GOG, encoding="utf-8", newline="\n")
    (bin_dir / "node").write_text(
        f'#!/bin/sh\nprintf "%s" "{node_says}"\nexit {node_exit}\n', encoding="utf-8", newline="\n"
    )
    for name in ("gog", "gog-bin", "node"):
        (bin_dir / name).chmod(0o755)
    state = tmp_path / "state"
    state.mkdir()
    return bin_dir, state


def run(
    bin_dir: Path, state: Path, *args: str, token: str | None = None
) -> subprocess.CompletedProcess[str]:
    assert POSIX_BASH is not None
    env = {
        "PATH": f"{bin_dir}:/usr/bin:/bin",
        "OPENCLAW_STATE_DIR": str(state),
        "GOG_APP_TOKEN_COMMAND": "token.mjs",
    }
    if token is not None:
        env["GOG_ACCESS_TOKEN"] = token
    return subprocess.run(
        [POSIX_BASH, str(bin_dir / "gog"), *args],
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )


def connect_in_app(state: Path) -> None:
    connectors = state / "household-app" / "connectors"
    connectors.mkdir(parents=True)
    (connectors / "google.json").write_text("{}", encoding="utf-8")


@needs_posix_bash
def test_with_no_in_app_sign_in_gog_runs_as_installed(tmp_path: Path) -> None:
    bin_dir, state = install(tmp_path, node_says="should-not-be-asked")

    done = run(bin_dir, state, "gmail", "search", "newer_than:1d")

    assert done.returncode == 0
    assert done.stdout.splitlines() == ["args=gmail search newer_than:1d", "token=none"]


@needs_posix_bash
def test_with_an_in_app_sign_in_gog_gets_a_fresh_access_token(tmp_path: Path) -> None:
    bin_dir, state = install(tmp_path, node_says="access-token-1")
    connect_in_app(state)

    done = run(bin_dir, state, "calendar", "calendars")

    assert done.returncode == 0
    assert done.stdout.splitlines() == ["args=calendar calendars", "token=access-token-1"]


@needs_posix_bash
def test_a_token_the_caller_already_set_is_left_alone(tmp_path: Path) -> None:
    bin_dir, state = install(tmp_path, node_says="access-token-1")
    connect_in_app(state)

    done = run(bin_dir, state, "gmail", "search", "x", token="caller-token")

    assert done.stdout.splitlines()[-1] == "token=caller-token"


@needs_posix_bash
def test_a_sign_in_that_cannot_be_refreshed_stops_gog_and_says_so(tmp_path: Path) -> None:
    bin_dir, state = install(tmp_path, node_says="", node_exit=1)
    connect_in_app(state)

    done = run(bin_dir, state, "gmail", "search", "x")

    assert done.returncode == 1
    assert done.stdout == ""
    assert "could not be refreshed" in done.stderr
