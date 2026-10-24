"""The coordination block of scripts/household-backup-lib.sh, which both backup scripts source.

The scripts themselves need root, docker and the SIQsermon paths, so nothing here runs
them whole. What runs is the `PYBACKUP` program lifted out of the shipped file, against
real databases in a temporary directory, so the copy-and-verify step that decides whether
the off switch survives a restore is executed rather than read. The block around it is
run once, sourced, for the box that never had the relay's database.

The databases are built by the relay's own storage layer rather than by hand, so the
fixture carries the WAL journal mode and the schema of migration 0003 and cannot drift
away from what is on the box.
"""

import sqlite3
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path

import pytest

from household.db import Database, migrate
from tests.capabilities import POSIX_BASH, needs_posix_bash

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "household-backup-lib.sh"
PAGE_SIZE = 4096
FRANCO = "person-franco"
SWITCHED_OFF_AT = "2026-09-19T10:00:00+00:00"


def coordination_program() -> str:
    opener = "<<'PYBACKUP'; then\n"
    text = SCRIPT.read_text(encoding="utf-8")
    start = text.index(opener) + len(opener)
    return text[start : text.index("\nPYBACKUP\n", start)]


def run_backup(source: Path, target: Path) -> subprocess.CompletedProcess[str]:
    # `python3 - source target` reads the program on stdin, which is how the script
    # invokes it, and gives sys.argv[1:] the same two paths.
    return subprocess.run(
        [sys.executable, "-", str(source), str(target)],
        input=coordination_program(),
        capture_output=True,
        text=True,
        check=False,
    )


@pytest.fixture
def destination(tmp_path: Path) -> Path:
    """The timestamped backup directory, holding nothing but what the block writes."""
    path = tmp_path / "backup"
    path.mkdir()
    return path


def make_relay_db(path: Path, *, switched_off: bool = False) -> None:
    database = Database(path)
    migrate(database)
    if switched_off:
        with database.write() as cx:
            # coordination_flag.changed_by_person_id is a foreign key and Database turns
            # foreign_keys on, so the person who threw the switch has to exist first.
            cx.execute("INSERT INTO person VALUES (?, ?)", (FRANCO, "Franco"))
            cx.execute(
                "INSERT INTO coordination_flag VALUES (1, 0, ?, ?)",
                (SWITCHED_OFF_AT, FRANCO),
            )
    database.close()


def make_db_without_the_flag_table(path: Path) -> None:
    # Hand-built, because a database that migration 0003 never reached is the shape
    # under test and the storage layer cannot produce one.
    db = sqlite3.connect(path)
    db.execute("pragma journal_mode=WAL")
    db.execute("create table coordination_seen (key text primary key)")
    db.commit()
    db.close()


@pytest.mark.parametrize("switched_off", [True, False])
def test_the_copy_carries_the_switch_position(
    tmp_path: Path, destination: Path, switched_off: bool
) -> None:
    source, target = tmp_path / "coordination.db", destination / "coordination.db"
    make_relay_db(source, switched_off=switched_off)

    result = run_backup(source, target)

    assert result.returncode == 0, result.stderr
    copy = sqlite3.connect(f"file:{target}?mode=ro", uri=True)
    rows = copy.execute("select id, enabled from coordination_flag").fetchall()
    copy.close()
    # No row is the ordinary state until somebody types `!coordination off`, and it has
    # to pass: a backup that only succeeded on switched-off boxes would be useless.
    assert rows == ([(1, 0)] if switched_off else [])


def test_the_copy_is_the_only_file_left_in_the_backup_directory(
    tmp_path: Path, destination: Path
) -> None:
    source = tmp_path / "coordination.db"
    make_relay_db(source)

    result = run_backup(source, destination / "coordination.db")

    assert result.returncode == 0, result.stderr
    # The relay runs in WAL and the copy inherits it, so a verification connection that
    # cannot checkpoint leaves coordination.db-wal and coordination.db-shm here, where
    # the script's `sha256sum ./*` hashes them into SHA256SUMS as if they were backups.
    assert sorted(path.name for path in destination.iterdir()) == ["coordination.db"]


def test_a_copy_without_the_flag_table_fails(tmp_path: Path, destination: Path) -> None:
    source = tmp_path / "coordination.db"
    make_db_without_the_flag_table(source)

    result = run_backup(source, destination / "coordination.db")

    assert result.returncode != 0
    assert "coordination_flag" in result.stderr


def zero_a_btree_page(source: Path) -> None:
    """Grow the relay past one page, then zero the last one."""
    database = Database(source)
    with database.write() as cx:
        cx.executemany(
            "INSERT INTO coordination_seen VALUES (?)", [(f"key-{i:05d}",) for i in range(2000)]
        )
    database.close()
    raw = bytearray(source.read_bytes())
    raw[-PAGE_SIZE:] = bytes(PAGE_SIZE)
    source.write_bytes(raw)


def zero_the_schema_page(source: Path) -> None:
    """Zero page one past its header, leaving the file openable and its schema gone."""
    raw = bytearray(source.read_bytes())
    raw[100:PAGE_SIZE] = bytes(PAGE_SIZE - 100)
    source.write_bytes(raw)


# Two shapes of damage, because SQLite reports them two ways: a zeroed btree page comes
# back as the pragma's result on some builds and raises on others, while a zeroed schema
# page raises on every build. Both are the same verdict and both have to say so.
@pytest.mark.parametrize("corrupt", [zero_a_btree_page, zero_the_schema_page])
def test_a_torn_source_fails(
    tmp_path: Path, destination: Path, corrupt: Callable[[Path], None]
) -> None:
    source = tmp_path / "coordination.db"
    make_relay_db(source)
    # The online backup API copies pages without reading them, so a torn source copies
    # cleanly and the copy fails integrity_check. That is the case the re-open exists
    # for: the copy raised nothing and is still not restorable.
    corrupt(source)

    result = run_backup(source, destination / "coordination.db")

    assert result.returncode != 0
    assert "integrity_check" in result.stderr


@needs_posix_bash
def test_a_box_without_the_relay_database_skips_it_and_backs_up_cleanly(
    tmp_path: Path, destination: Path
) -> None:
    """The relay was retired with Telegram, so a new box never has its database.

    The block runs as the backup scripts run it, sourced under `set -euo pipefail`, and
    has to record the copy as not installed, leave the failure flag alone and write
    nothing, or every nightly backup on such a box would stop short of its drill.
    """
    program = (
        "set -euo pipefail\n"
        'source "$1"\n'
        'COORDINATION_DB="$2"\n'
        'dest="$3"\n'
        "openclaw_failed=0\n"
        "archive_coordination\n"
        'printf "%s %s\\n" "${coordination_archive}" "${openclaw_failed}"\n'
    )
    assert POSIX_BASH is not None
    result = subprocess.run(
        [
            POSIX_BASH,
            "-c",
            program,
            "bash",
            SCRIPT.as_posix(),
            (tmp_path / "coordination" / "coordination.db").as_posix(),
            destination.as_posix(),
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout.splitlines()[-1] == "none 0"
    assert list(destination.iterdir()) == []
