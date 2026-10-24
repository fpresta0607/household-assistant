"""The scheduled backup of both gateways: scripts/household-backup.sh and its units.

Nothing ran the backup job on a schedule, and its newest archive on the box was from
18 September. The script needs root, docker and the gateways' state, so nothing here
runs it whole. What runs is the retention program lifted out of the shipped file,
against backup directories in a temporary root, the same way test_backup_script.py
runs the coordination copy. The units are read as systemd reads them.
"""

import configparser
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

from tests.capabilities import needs_posix_bash

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "household-backup.sh"
LIBRARY = ROOT / "scripts" / "household-backup-lib.sh"
SIQSERMON = ROOT / "scripts" / "siqsermon-backup.sh"
DRILL = ROOT / "scripts" / "household-restore-drill.sh"
UNITS = ROOT / "deploy" / "backup"


def retention_program() -> str:
    opener = "<<'PRUNE'\n"
    text = SCRIPT.read_text(encoding="utf-8")
    start = text.index(opener) + len(opener)
    return text[start : text.index("\nPRUNE\n", start)]


def prune(root: Path, keep: int) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, "-", str(root), str(keep)],
        input=retention_program(),
        capture_output=True,
        text=True,
        check=False,
    )


def backup(root: Path, stamp: str, *, is_complete: bool = True) -> Path:
    path = root / stamp
    path.mkdir()
    (path / "openclaw-state.tar.gz").write_text("archive")
    (path / "MANIFEST.tsv").write_text("taken_at_utc\t" + stamp + "\n")
    (path / "SHA256SUMS").write_text("")
    if is_complete:
        (path / "RESTORED").write_text("DRILL PASSED\n")
    return path


def stamps(day: int) -> str:
    return f"202610{day:02d}T093000Z"


def test_retention_keeps_the_newest_complete_backups(tmp_path: Path) -> None:
    for day in range(1, 21):
        backup(tmp_path, stamps(day))

    result = prune(tmp_path, 14)

    assert result.returncode == 0, result.stderr
    assert sorted(path.name for path in tmp_path.iterdir()) == [stamps(day) for day in range(7, 21)]


def test_a_backup_whose_drill_failed_does_not_count_toward_what_is_kept(tmp_path: Path) -> None:
    for day in range(1, 5):
        backup(tmp_path, stamps(day))
    backup(tmp_path, stamps(5), is_complete=False)

    assert prune(tmp_path, 3).returncode == 0

    # The newest is unfinished, so three complete ones stay behind it, and it stays
    # too: it may be a run still writing.
    assert sorted(path.name for path in tmp_path.iterdir()) == [stamps(day) for day in (2, 3, 4, 5)]


def test_an_incomplete_backup_older_than_every_kept_one_goes(tmp_path: Path) -> None:
    backup(tmp_path, stamps(1), is_complete=False)
    for day in range(2, 5):
        backup(tmp_path, stamps(day))

    assert prune(tmp_path, 3).returncode == 0

    assert sorted(path.name for path in tmp_path.iterdir()) == [stamps(day) for day in (2, 3, 4)]


def test_retention_leaves_what_it_did_not_write(tmp_path: Path) -> None:
    for day in range(1, 4):
        backup(tmp_path, stamps(day))
    (tmp_path / "keep-me").mkdir()
    (tmp_path / "notes.txt").write_text("a person's note")

    assert prune(tmp_path, 1).returncode == 0

    assert sorted(path.name for path in tmp_path.iterdir()) == [stamps(3), "keep-me", "notes.txt"]


@pytest.mark.parametrize("keep", ["0", "-1", "lots"])
def test_retention_refuses_a_count_that_would_keep_nothing(tmp_path: Path, keep: str) -> None:
    backup(tmp_path, stamps(1))
    result = subprocess.run(
        [sys.executable, "-", str(tmp_path), keep],
        input=retention_program(),
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode != 0
    assert (tmp_path / stamps(1)).is_dir()


def read_unit(name: str) -> configparser.ConfigParser:
    unit = configparser.ConfigParser(strict=False, interpolation=None)
    unit.optionxform = str  # type: ignore[assignment,method-assign]
    unit.read_string((UNITS / name).read_text(encoding="utf-8"))
    return unit


def test_the_timer_runs_nightly_and_catches_up_after_downtime() -> None:
    timer = read_unit("household-backup.timer")
    assert timer["Timer"]["OnCalendar"] == "*-*-* 04:30:00 America/Chicago"
    assert timer["Timer"]["Persistent"] == "true"
    assert timer["Timer"]["Unit"] == "household-backup.service"
    assert timer["Install"]["WantedBy"] == "timers.target"


def test_the_service_runs_the_backup_with_its_retention() -> None:
    service = read_unit("household-backup.service")["Service"]
    assert service["Type"] == "oneshot"
    assert service["ExecStart"] == "/opt/household-assistant/backup/household-backup.sh --keep 14"
    assert service["Nice"] == "10"


def test_both_backup_scripts_archive_the_gateways_with_one_shared_definition() -> None:
    for script in (SCRIPT, SIQSERMON):
        text = script.read_text(encoding="utf-8")
        assert 'source "${here}/household-backup-lib.sh"' in text, script.name
        assert "archive_assistant()" not in text, script.name
    assert "archive_assistant()" in LIBRARY.read_text(encoding="utf-8")


def test_each_backup_ends_with_a_restore_drill_of_what_it_wrote() -> None:
    text = SCRIPT.read_text(encoding="utf-8")
    assert '"${here}/household-restore-drill.sh" "${dest}"' in text
    drill = DRILL.read_text(encoding="utf-8")
    assert 'drill_gateway "${label}"' in drill
    assert "coordination_flag" in drill


def gateways_of(household: Path) -> list[list[str]]:
    bash = shutil.which("bash")
    assert bash is not None
    listed = subprocess.run(
        [bash, "-c", f'source "{LIBRARY.as_posix()}" && household_gateways'],
        env={**os.environ, "HOUSEHOLD_FILE": household.as_posix()},
        capture_output=True,
        text=True,
        check=True,
    )
    return [line.split("\t") for line in listed.stdout.splitlines()]


@needs_posix_bash
def test_the_first_households_gateways_keep_the_labels_every_backup_had() -> None:
    root = "/var/lib/household-assistant"
    assert gateways_of(ROOT / "deploy" / "household.example.json") == [
        [
            "openclaw",
            "openclaw-gateway",
            f"{root}/openclaw",
            f"{root}/openclaw-auth-secrets",
            f"{root}/codex",
        ],
        [
            "denise",
            "openclaw-denise",
            f"{root}/openclaw-denise",
            f"{root}/openclaw-denise-auth-secrets",
            f"{root}/codex-denise",
        ],
    ]


@needs_posix_bash
def test_a_new_households_gateways_are_labelled_by_their_assistants() -> None:
    labels = [line[:2] for line in gateways_of(ROOT / "deploy" / "household.new.example.json")]
    assert labels == [["ada", "openclaw-ada"], ["rex", "openclaw-rex"]]


@needs_posix_bash
def test_the_drill_restores_every_gateway_its_manifest_names(tmp_path: Path) -> None:
    bash = shutil.which("bash")
    assert bash is not None
    backup = tmp_path / "20261024T043000Z"
    backup.mkdir()
    (backup / "MANIFEST.tsv").write_text(
        "taken_at_utc\t20261024T043000Z\n"
        "ada_archive\tnone\nada_codex_archive\tmissing\n"
        "rex_archive\tnone\nrex_codex_archive\tmissing\n"
        "coordination_archive\tnone\n",
        encoding="utf-8",
    )
    subprocess.run(
        "sha256sum ./* > SHA256SUMS", shell=True, cwd=backup, check=True, capture_output=True
    )

    drilled = subprocess.run(
        [bash, DRILL.as_posix(), backup.as_posix()],
        env={
            **os.environ,
            "HOUSEHOLD_FILE": (ROOT / "deploy" / "household.new.example.json").as_posix(),
            "TMPDIR": tmp_path.as_posix(),
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert "--- ada ---" in drilled.stdout, drilled.stdout + drilled.stderr
    assert "--- rex ---" in drilled.stdout
    assert "--- codex ---" not in drilled.stdout
    assert "DRILL PASSED" in drilled.stdout


@pytest.mark.parametrize("script", [SCRIPT, LIBRARY, SIQSERMON, DRILL])
@needs_posix_bash
def test_the_scripts_parse(script: Path) -> None:
    # Resolved from PATH: a bare "bash" on Windows is System32's, which starts WSL.
    bash = shutil.which("bash")
    assert bash is not None, "the deployment scripts are bash, and CI has to have it"
    parsed = subprocess.run(
        [bash, "-n", script.as_posix()], capture_output=True, text=True, check=False
    )
    assert parsed.returncode == 0, parsed.stderr


def test_the_archive_container_sees_the_plugins_the_config_names() -> None:
    """Without the household plugins mounted where the config names them, OpenClaw
    calls the config invalid and `backup create` refuses: the first nightly run on
    14 October archived neither gateway, and nor could any run since 5 October."""
    library = LIBRARY.read_text(encoding="utf-8")
    assert "PLUGINS=/opt/household-assistant/plugins" in library
    run = library[
        library.index("docker run --rm") : library.index("backup create --output /backup")
    ]
    assert '-v "${PLUGINS}":/opt/household-plugins:ro' in run


def test_a_backup_is_marked_restored_only_after_its_drill_passes() -> None:
    text = SCRIPT.read_text(encoding="utf-8")
    drill = text.index('"${here}/household-restore-drill.sh" "${dest}"')
    failure_exit = text.index("exit 1", drill)
    marker = text.index('> "${dest}/RESTORED"')
    assert drill < failure_exit < marker


def test_the_drill_hands_its_scratch_to_the_gateway_user_by_number() -> None:
    """The box has no user named for uid 1000, and its `install -o 1000` refuses one,
    which stopped the drill on 14 October before it restored anything."""
    drill = DRILL.read_text(encoding="utf-8")
    assert "-o 1000" not in drill
    assert 'chown -R 1000:1000 "${WORK}/${label}"' in drill


def library_says(script: str, env: dict[str, str] | None = None) -> str:
    bash = shutil.which("bash")
    assert bash is not None
    said = subprocess.run(
        [bash, "-c", f'source "{LIBRARY.as_posix()}" && {script}'],
        env={**os.environ, **(env or {})},
        capture_output=True,
        text=True,
        check=True,
    )
    return said.stdout.strip()


@needs_posix_bash
@pytest.mark.parametrize(
    ("recorded", "asked"),
    [
        ("", "openclaw.json workspace/AGENTS.md workspace/USER.md household-memory/kept.json"),
        ("none", "openclaw.json"),
        ("openclaw.json workspace/AGENTS.md", "openclaw.json workspace/AGENTS.md"),
        ("workspace/AGENTS.md", "openclaw.json workspace/AGENTS.md"),
    ],
)
def test_the_drill_asks_a_gateway_for_the_files_it_had_when_backed_up(
    recorded: str, asked: str
) -> None:
    """A new gateway has no kept.json until someone asks to keep something, and OpenClaw
    writes USER.md only into a brand-new workspace, so asking every gateway for all of them
    failed every backup of a new box, and with it every update."""
    assert library_says(f'drill_files "{recorded}"') == asked


@needs_posix_bash
def test_each_backup_records_the_files_its_gateway_had(tmp_path: Path) -> None:
    state = tmp_path / "state"
    (state / "workspace").mkdir(parents=True)
    (state / "workspace" / "AGENTS.md").write_text("# agents\n", encoding="utf-8")
    (state / "workspace" / "USER.md").write_text("", encoding="utf-8")
    script = (
        f'dest="{tmp_path / "dest"}"; openclaw_failed=0; '
        f'archive_assistant ada openclaw-ada "{state}" "{tmp_path / "s"}" "{tmp_path / "c"}" '
        '>/dev/null 2>&1; echo "${ada_files}"'
    )

    assert library_says(script) == "workspace/AGENTS.md"
