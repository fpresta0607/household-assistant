"""Scoped reads and writes.

Every read here takes an explicit scope set or an explicit person. There is no
function in this module that returns a household record without one, so a caller
that forgets to authorize gets nothing rather than everything.
"""

from __future__ import annotations

import sqlite3
import uuid
from collections.abc import Collection, Sequence
from dataclasses import dataclass

from .errors import ScopeDenied


@dataclass(frozen=True, slots=True)
class MemoryRecord:
    id: str
    scope: str
    subject: str
    body: str
    author_person_id: str
    created_at: str


@dataclass(frozen=True, slots=True)
class TaskRecord:
    id: str
    scope: str
    title: str
    done: bool
    author_person_id: str
    created_at: str


@dataclass(frozen=True, slots=True)
class ReminderRecord:
    id: str
    scope: str
    text: str
    due_at: str
    delivered_at: str | None
    author_person_id: str
    created_at: str


@dataclass(frozen=True, slots=True)
class ListItemRecord:
    id: str
    list_id: str
    list_name: str
    scope: str
    text: str
    added_by_person_id: str
    created_at: str


@dataclass(frozen=True, slots=True)
class AccountRecord:
    id: str
    person_id: str
    provider: str
    address: str
    mail_monitored: bool
    mail_digest: bool
    mail_writable: bool
    mail_last_sync_at: str | None


@dataclass(frozen=True, slots=True)
class CalendarRecord:
    id: str
    account_id: str
    name: str
    counts_toward_availability: bool
    writable: bool
    last_sync_at: str | None


def new_id() -> str:
    return uuid.uuid4().hex


def _placeholders(values: Collection[str]) -> str:
    return ", ".join("?" for _ in values)


def insert_memory(
    cx: sqlite3.Connection,
    *,
    scope: str,
    subject: str,
    body: str,
    author_person_id: str,
    created_at: str,
) -> str:
    memory_id = new_id()
    cx.execute(
        "INSERT INTO memory (id, scope, subject, body, author_person_id, created_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (memory_id, scope, subject, body, author_person_id, created_at),
    )
    return memory_id


def search_memory(
    cx: sqlite3.Connection,
    *,
    scopes: Collection[str],
    query: str,
    limit: int,
) -> list[MemoryRecord]:
    if not scopes:
        return []
    scope_list = sorted(scopes)
    rows = cx.execute(
        "SELECT id, scope, subject, body, author_person_id, created_at FROM memory "
        f"WHERE scope IN ({_placeholders(scope_list)}) "
        "AND (subject LIKE ? OR body LIKE ?) "
        "ORDER BY created_at DESC, rowid DESC LIMIT ?",
        (*scope_list, f"%{query}%", f"%{query}%", limit),
    ).fetchall()
    return [
        MemoryRecord(
            id=str(row["id"]),
            scope=str(row["scope"]),
            subject=str(row["subject"]),
            body=str(row["body"]),
            author_person_id=str(row["author_person_id"]),
            created_at=str(row["created_at"]),
        )
        for row in rows
    ]


def insert_task(
    cx: sqlite3.Connection,
    *,
    scope: str,
    title: str,
    author_person_id: str,
    created_at: str,
) -> str:
    task_id = new_id()
    cx.execute(
        "INSERT INTO task (id, scope, title, done, author_person_id, created_at) "
        "VALUES (?, ?, ?, 0, ?, ?)",
        (task_id, scope, title, author_person_id, created_at),
    )
    return task_id


def list_tasks(
    cx: sqlite3.Connection,
    *,
    scopes: Collection[str],
    include_done: bool,
) -> list[TaskRecord]:
    if not scopes:
        return []
    scope_list = sorted(scopes)
    rows = cx.execute(
        "SELECT id, scope, title, done, author_person_id, created_at FROM task "
        f"WHERE scope IN ({_placeholders(scope_list)}) "
        "AND (? = 1 OR done = 0) "
        "ORDER BY rowid",
        (*scope_list, int(include_done)),
    ).fetchall()
    return [
        TaskRecord(
            id=str(row["id"]),
            scope=str(row["scope"]),
            title=str(row["title"]),
            done=bool(row["done"]),
            author_person_id=str(row["author_person_id"]),
            created_at=str(row["created_at"]),
        )
        for row in rows
    ]


def complete_task(cx: sqlite3.Connection, *, task_id: str, scopes: Collection[str]) -> None:
    if not scopes:
        raise ScopeDenied(f"no task {task_id!r} in your scopes")
    scope_list = sorted(scopes)
    cursor = cx.execute(
        f"UPDATE task SET done = 1 WHERE id = ? AND scope IN ({_placeholders(scope_list)})",
        (task_id, *scope_list),
    )
    if cursor.rowcount == 0:
        raise ScopeDenied(f"no task {task_id!r} in your scopes")


def insert_reminder(
    cx: sqlite3.Connection,
    *,
    scope: str,
    text: str,
    due_at: str,
    author_person_id: str,
    created_at: str,
) -> str:
    reminder_id = new_id()
    cx.execute(
        "INSERT INTO reminder (id, scope, text, due_at, author_person_id, created_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (reminder_id, scope, text, due_at, author_person_id, created_at),
    )
    return reminder_id


def list_reminders(
    cx: sqlite3.Connection,
    *,
    scopes: Collection[str],
    due_before: str | None,
) -> list[ReminderRecord]:
    if not scopes:
        return []
    scope_list = sorted(scopes)
    rows = cx.execute(
        "SELECT id, scope, text, due_at, delivered_at, author_person_id, created_at "
        f"FROM reminder WHERE scope IN ({_placeholders(scope_list)}) "
        "AND (? IS NULL OR due_at <= ?) "
        "ORDER BY due_at, rowid",
        (*scope_list, due_before, due_before),
    ).fetchall()
    return [
        ReminderRecord(
            id=str(row["id"]),
            scope=str(row["scope"]),
            text=str(row["text"]),
            due_at=str(row["due_at"]),
            delivered_at=None if row["delivered_at"] is None else str(row["delivered_at"]),
            author_person_id=str(row["author_person_id"]),
            created_at=str(row["created_at"]),
        )
        for row in rows
    ]


def add_list_item(
    cx: sqlite3.Connection,
    *,
    scope: str,
    list_name: str,
    text: str,
    added_by_person_id: str,
    created_at: str,
) -> str:
    row = cx.execute(
        "SELECT id FROM household_list WHERE scope = ? AND name = ?",
        (scope, list_name),
    ).fetchone()
    if row is None:
        list_id = new_id()
        cx.execute(
            "INSERT INTO household_list (id, scope, name, created_at) VALUES (?, ?, ?, ?)",
            (list_id, scope, list_name, created_at),
        )
    else:
        list_id = str(row["id"])
    item_id = new_id()
    cx.execute(
        "INSERT INTO list_item (id, list_id, text, added_by_person_id, created_at) "
        "VALUES (?, ?, ?, ?, ?)",
        (item_id, list_id, text, added_by_person_id, created_at),
    )
    return item_id


def list_items(
    cx: sqlite3.Connection,
    *,
    scopes: Collection[str],
    list_name: str,
) -> list[ListItemRecord]:
    if not scopes:
        return []
    scope_list = sorted(scopes)
    rows = cx.execute(
        "SELECT i.id, i.list_id, l.name, l.scope, i.text, i.added_by_person_id, i.created_at "
        "FROM list_item i JOIN household_list l ON l.id = i.list_id "
        f"WHERE l.scope IN ({_placeholders(scope_list)}) AND l.name = ? AND i.removed_at IS NULL "
        "ORDER BY i.rowid",
        (*scope_list, list_name),
    ).fetchall()
    return [
        ListItemRecord(
            id=str(row["id"]),
            list_id=str(row["list_id"]),
            list_name=str(row["name"]),
            scope=str(row["scope"]),
            text=str(row["text"]),
            added_by_person_id=str(row["added_by_person_id"]),
            created_at=str(row["created_at"]),
        )
        for row in rows
    ]


def remove_list_item(
    cx: sqlite3.Connection,
    *,
    item_id: str,
    scopes: Collection[str],
    removed_at: str,
) -> None:
    if not scopes:
        raise ScopeDenied(f"no list item {item_id!r} in your scopes")
    scope_list = sorted(scopes)
    cursor = cx.execute(
        "UPDATE list_item SET removed_at = ? WHERE id = ? AND removed_at IS NULL "
        "AND list_id IN (SELECT id FROM household_list "
        f"WHERE scope IN ({_placeholders(scope_list)}))",
        (removed_at, item_id, *scope_list),
    )
    if cursor.rowcount == 0:
        raise ScopeDenied(f"no list item {item_id!r} in your scopes")


def add_account(
    cx: sqlite3.Connection,
    *,
    account_id: str,
    person_id: str,
    provider: str,
    address: str,
    mail_monitored: bool = False,
    mail_digest: bool = False,
    mail_writable: bool = False,
    mail_last_sync_at: str | None = None,
) -> str:
    cx.execute(
        "INSERT INTO account (id, person_id, provider, address, mail_monitored, mail_digest, "
        "mail_writable, mail_last_sync_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (
            account_id,
            person_id,
            provider,
            address,
            int(mail_monitored),
            int(mail_digest),
            int(mail_writable),
            mail_last_sync_at,
        ),
    )
    return account_id


def add_calendar(
    cx: sqlite3.Connection,
    *,
    calendar_id: str,
    account_id: str,
    name: str,
    counts_toward_availability: bool = True,
    writable: bool = False,
    last_sync_at: str | None = None,
) -> str:
    cx.execute(
        "INSERT INTO calendar (id, account_id, name, counts_toward_availability, writable, "
        "last_sync_at) VALUES (?, ?, ?, ?, ?, ?)",
        (
            calendar_id,
            account_id,
            name,
            int(counts_toward_availability),
            int(writable),
            last_sync_at,
        ),
    )
    return calendar_id


def _account_from_row(row: sqlite3.Row) -> AccountRecord:
    return AccountRecord(
        id=str(row["id"]),
        person_id=str(row["person_id"]),
        provider=str(row["provider"]),
        address=str(row["address"]),
        mail_monitored=bool(row["mail_monitored"]),
        mail_digest=bool(row["mail_digest"]),
        mail_writable=bool(row["mail_writable"]),
        mail_last_sync_at=(
            None if row["mail_last_sync_at"] is None else str(row["mail_last_sync_at"])
        ),
    )


def accounts_for_person(cx: sqlite3.Connection, *, person_id: str) -> list[AccountRecord]:
    rows = cx.execute(
        "SELECT * FROM account WHERE person_id = ? ORDER BY provider, address",
        (person_id,),
    ).fetchall()
    return [_account_from_row(row) for row in rows]


def account_owned_by(
    cx: sqlite3.Connection,
    *,
    account_id: str,
    person_id: str,
) -> AccountRecord | None:
    """An account is only ever reachable through the person who owns it."""
    row = cx.execute(
        "SELECT * FROM account WHERE id = ? AND person_id = ?",
        (account_id, person_id),
    ).fetchone()
    return None if row is None else _account_from_row(row)


def calendars_for_accounts(
    cx: sqlite3.Connection,
    *,
    account_ids: Sequence[str],
) -> list[CalendarRecord]:
    if not account_ids:
        return []
    rows = cx.execute(
        "SELECT id, account_id, name, counts_toward_availability, writable, last_sync_at "
        f"FROM calendar WHERE account_id IN ({_placeholders(account_ids)}) ORDER BY id",
        tuple(account_ids),
    ).fetchall()
    return [
        CalendarRecord(
            id=str(row["id"]),
            account_id=str(row["account_id"]),
            name=str(row["name"]),
            counts_toward_availability=bool(row["counts_toward_availability"]),
            writable=bool(row["writable"]),
            last_sync_at=None if row["last_sync_at"] is None else str(row["last_sync_at"]),
        )
        for row in rows
    ]


def calendar_owned_by(
    cx: sqlite3.Connection,
    *,
    calendar_id: str,
    person_id: str,
) -> CalendarRecord | None:
    """A calendar is reachable only through the account, and the person, that owns it."""
    row = cx.execute(
        "SELECT c.id, c.account_id, c.name, c.counts_toward_availability, c.writable, "
        "c.last_sync_at FROM calendar c JOIN account a ON a.id = c.account_id "
        "WHERE c.id = ? AND a.person_id = ?",
        (calendar_id, person_id),
    ).fetchone()
    if row is None:
        return None
    return CalendarRecord(
        id=str(row["id"]),
        account_id=str(row["account_id"]),
        name=str(row["name"]),
        counts_toward_availability=bool(row["counts_toward_availability"]),
        writable=bool(row["writable"]),
        last_sync_at=None if row["last_sync_at"] is None else str(row["last_sync_at"]),
    )
