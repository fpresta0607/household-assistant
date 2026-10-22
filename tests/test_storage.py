"""Storage: write-ahead logging, foreign keys, migrations, one controlled writer."""

from __future__ import annotations

import sqlite3
import threading
from pathlib import Path

import pytest

from household.app import Household
from household.db import MIGRATIONS_DIRECTORY, Database, _statements, migrate


def _fresh(tmp_path: Path, name: str = "household.db") -> Database:
    return Database(tmp_path / name)


# Written out rather than globbed. ``migrate`` builds its pending list by globbing the
# same directory, so a test that globs it too asserts that two identical expressions
# agree and cannot fail for any set of files. Spelling the versions here is what makes a
# stray, mis-numbered or accidentally added ``.sql`` turn this red. A new migration edits
# this line, and that is the checkpoint rather than the chore.
MIGRATION_VERSIONS = ["0001_identity", "0002_household", "0003_coordination"]


def test_the_database_runs_in_wal_with_foreign_keys_on(tmp_path: Path) -> None:
    database = _fresh(tmp_path)
    assert database.pragma("journal_mode") == "wal"
    assert database.pragma("foreign_keys") == "1"
    database.close()


def test_migrations_run_forward_cleanly_on_an_empty_database(tmp_path: Path) -> None:
    database = _fresh(tmp_path)
    applied = migrate(database)
    assert applied == MIGRATION_VERSIONS

    with database.read() as cx:
        tables = {
            str(row["name"])
            for row in cx.execute("SELECT name FROM sqlite_master WHERE type = 'table'")
        }
    assert {"person", "persona", "channel_identity", "route", "account", "calendar"} <= tables
    assert {"memory", "task", "reminder", "household_list", "list_item", "approval"} <= tables
    assert {"coordination_flag", "coordination_turn", "coordination_message"} <= tables
    assert {"taste_signal", "research_budget"} <= tables
    database.close()


def test_running_migrations_again_changes_nothing(tmp_path: Path) -> None:
    database = _fresh(tmp_path)
    migrate(database)
    assert migrate(database) == []
    database.close()


def test_migrations_run_forward_cleanly_over_existing_data(tmp_path: Path) -> None:
    """The second migration lands on a database that already holds rows from the first."""
    database = _fresh(tmp_path)
    first = sorted(MIGRATIONS_DIRECTORY.glob("*.sql"))[0]
    with database.write() as cx:
        cx.execute(
            "CREATE TABLE schema_migration (version TEXT PRIMARY KEY, applied_at TEXT NOT NULL)"
        )
        for statement in _statements(first.read_text(encoding="utf-8")):
            cx.execute(statement)
        cx.execute(
            "INSERT INTO schema_migration (version, applied_at) VALUES (?, datetime('now'))",
            (first.stem,),
        )
        cx.execute("INSERT INTO person (id, display_name) VALUES ('franco', 'Franco')")

    assert migrate(database) == MIGRATION_VERSIONS[1:]

    with database.read() as cx:
        assert cx.execute("SELECT display_name FROM person WHERE id = 'franco'").fetchone()[0] == (
            "Franco"
        )
        cx.execute(
            "INSERT INTO memory (id, scope, subject, body, author_person_id, created_at) "
            "VALUES ('m1', 'household_shared', 's', 'b', 'franco', '2026-09-17T09:00:00+00:00')"
        )
    database.close()


def test_a_migration_with_a_procedural_block_is_rejected_rather_than_half_applied() -> None:
    with pytest.raises(ValueError, match="plain DDL"):
        _statements("CREATE TRIGGER t AFTER INSERT ON person BEGIN SELECT 1; END;")


def test_foreign_keys_are_enforced(household: Household) -> None:
    with pytest.raises(sqlite3.IntegrityError), household.database.write() as cx:
        cx.execute(
            "INSERT INTO channel_identity (channel, channel_user_id, person_id, enrolled_at) "
            "VALUES ('telegram', '404', 'nobody', '2026-09-17T09:00:00+00:00')"
        )


def test_a_persona_cannot_be_enrolled_as_a_person(household: Household) -> None:
    """A persona is a voice, never a principal. The foreign key says so too."""
    with pytest.raises(sqlite3.IntegrityError), household.database.write() as cx:
        cx.execute(
            "INSERT INTO channel_identity (channel, channel_user_id, person_id, enrolled_at) "
            "VALUES ('telegram', '505', 'corey', '2026-09-17T09:00:00+00:00')"
        )


def test_the_datastore_rejects_a_scope_that_is_not_one_of_the_three(
    household: Household,
) -> None:
    with pytest.raises(sqlite3.IntegrityError), household.database.write() as cx:
        cx.execute(
            "INSERT INTO memory (id, scope, subject, body, author_person_id, created_at) "
            "VALUES ('m1', 'everyone', 's', 'b', 'franco', '2026-09-17T09:00:00+00:00')"
        )


def test_a_failed_write_rolls_back_whole(household: Household) -> None:
    with pytest.raises(sqlite3.IntegrityError), household.database.write() as cx:
        cx.execute(
            "INSERT INTO memory (id, scope, subject, body, author_person_id, created_at) "
            "VALUES ('good', 'household_shared', 's', 'b', 'franco', '2026-09-17T09:00:00+00:00')"
        )
        cx.execute(
            "INSERT INTO memory (id, scope, subject, body, author_person_id, created_at) "
            "VALUES ('bad', 'everyone', 's', 'b', 'franco', '2026-09-17T09:00:00+00:00')"
        )

    with household.database.read() as cx:
        assert cx.execute("SELECT count(*) FROM memory").fetchone()[0] == 0


def test_one_controlled_writer_serializes_concurrent_writes(household: Household) -> None:
    errors: list[BaseException] = []

    def write(worker: int) -> None:
        try:
            for index in range(20):
                with household.database.write() as cx:
                    cx.execute(
                        "INSERT INTO memory (id, scope, subject, body, author_person_id, "
                        "created_at) VALUES (?, 'household_shared', ?, 'b', 'franco', ?)",
                        (f"{worker}-{index}", f"s{index}", "2026-09-17T09:00:00+00:00"),
                    )
        except BaseException as error:  # the test is what reports it
            errors.append(error)

    threads = [threading.Thread(target=write, args=(worker,)) for worker in range(8)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    assert errors == []
    with household.database.read() as cx:
        assert cx.execute("SELECT count(*) FROM memory").fetchone()[0] == 160
