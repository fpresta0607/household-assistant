"""SQLite storage: WAL, foreign keys, forward-only migrations, one controlled writer."""

from __future__ import annotations

import re
import sqlite3
import threading
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

MIGRATIONS_DIRECTORY = Path(__file__).parent / "migrations"


class Database:
    """One connection, one writer.

    Every write runs inside ``BEGIN IMMEDIATE`` under a process lock, which is the
    "one controlled writer" the plan asks for without a second process to run it.
    """

    def __init__(self, path: str | Path) -> None:
        self.path = str(path)
        self._connection = sqlite3.connect(self.path, check_same_thread=False, isolation_level=None)
        self._connection.row_factory = sqlite3.Row
        # ponytail: readers take the same lock as the writer. Two people never contend;
        # give readers their own connections only if a measurement ever shows they do.
        self._lock = threading.RLock()
        self._connection.execute("PRAGMA journal_mode = WAL")
        self._connection.execute("PRAGMA foreign_keys = ON")
        self._connection.execute("PRAGMA busy_timeout = 5000")

    @contextmanager
    def read(self) -> Iterator[sqlite3.Connection]:
        with self._lock:
            yield self._connection

    @contextmanager
    def write(self) -> Iterator[sqlite3.Connection]:
        with self._lock:
            self._connection.execute("BEGIN IMMEDIATE")
            try:
                yield self._connection
            except BaseException:
                self._connection.execute("ROLLBACK")
                raise
            self._connection.execute("COMMIT")

    def pragma(self, name: str) -> str:
        with self.read() as cx:
            return str(cx.execute(f"PRAGMA {name}").fetchone()[0])

    def close(self) -> None:
        with self._lock:
            self._connection.close()


def migrate(database: Database) -> list[str]:
    """Apply every migration that is not recorded yet, oldest first.

    Returns the versions applied, so a caller can tell a fresh database from a
    no-op run. Running it twice is a no-op; running it over data adds only what
    is missing.
    """
    with database.write() as cx:
        cx.execute(
            "CREATE TABLE IF NOT EXISTS schema_migration ("
            "  version TEXT PRIMARY KEY,"
            "  applied_at TEXT NOT NULL"
            ")"
        )
        applied = {
            str(row["version"]) for row in cx.execute("SELECT version FROM schema_migration")
        }

    pending = [
        script
        for script in sorted(MIGRATIONS_DIRECTORY.glob("*.sql"))
        if script.stem not in applied
    ]
    for script in pending:
        statements = _statements(script.read_text(encoding="utf-8"))
        with database.write() as cx:
            for statement in statements:
                cx.execute(statement)
            cx.execute(
                "INSERT INTO schema_migration (version, applied_at) VALUES (?, datetime('now'))",
                (script.stem,),
            )
    return [script.stem for script in pending]


def _statements(sql: str) -> list[str]:
    """Split a migration into statements.

    ponytail: strips ``--`` comments and splits on ``;``. That is enough for plain
    DDL and nothing else, so a migration carrying a trigger or a procedural block
    is rejected loudly here rather than half-applied at 3am. No migration may
    contain a ``--`` sequence or a semicolon inside a string literal.
    """
    without_comments = "\n".join(line.split("--", 1)[0] for line in sql.splitlines())
    if re.search(r"\bBEGIN\b", without_comments, re.IGNORECASE):
        raise ValueError(
            "migrations are plain DDL: BEGIN blocks and triggers are not supported by the runner"
        )
    return [statement.strip() for statement in without_comments.split(";") if statement.strip()]
