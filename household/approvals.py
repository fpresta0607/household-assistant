"""Approvals that bind.

An approval names one action version, one actor, one resource, one destination and
one moment it stops being true. A yes in another chat, a yes from the other person,
a yes for an earlier version of the proposal, and a yes used twice are all refusals.
"""

from __future__ import annotations

import hashlib
import json
import sqlite3
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import datetime, timedelta

from .errors import ApprovalInvalid
from .identity import IdentityEnvelope
from .store import new_id

APPROVAL_TTL = timedelta(minutes=15)

STATE_PENDING = "pending"
STATE_GRANTED = "granted"
STATE_CONSUMED = "consumed"


@dataclass(frozen=True, slots=True)
class ApprovalRecord:
    id: str
    action_version: str
    tool: str
    actor_person_id: str
    route_id: str
    resource: str
    destination: str
    state: str
    requested_at: str
    expires_at: str
    granted_at: str | None
    granted_by_person_id: str | None
    consumed_at: str | None


def action_version(
    *,
    tool: str,
    actor_person_id: str,
    destination: str,
    resource: Mapping[str, str],
) -> str:
    """The fingerprint an approval binds to.

    Change the tool, the person, the destination or any material field of the
    proposal and this changes, which is what makes a stale yes useless.
    """
    payload = json.dumps(
        {
            "tool": tool,
            "actor_person_id": actor_person_id,
            "destination": destination,
            "resource": dict(sorted(resource.items())),
        },
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _record_from_row(row: sqlite3.Row) -> ApprovalRecord:
    return ApprovalRecord(
        id=str(row["id"]),
        action_version=str(row["action_version"]),
        tool=str(row["tool"]),
        actor_person_id=str(row["actor_person_id"]),
        route_id=str(row["route_id"]),
        resource=str(row["resource"]),
        destination=str(row["destination"]),
        state=str(row["state"]),
        requested_at=str(row["requested_at"]),
        expires_at=str(row["expires_at"]),
        granted_at=None if row["granted_at"] is None else str(row["granted_at"]),
        granted_by_person_id=(
            None if row["granted_by_person_id"] is None else str(row["granted_by_person_id"])
        ),
        consumed_at=None if row["consumed_at"] is None else str(row["consumed_at"]),
    )


def create_approval(
    cx: sqlite3.Connection,
    *,
    envelope: IdentityEnvelope,
    tool: str,
    destination: str,
    resource: Mapping[str, str],
    now: datetime,
    ttl: timedelta = APPROVAL_TTL,
) -> ApprovalRecord:
    approval_id = new_id()
    version = action_version(
        tool=tool,
        actor_person_id=envelope.actor_person_id,
        destination=destination,
        resource=resource,
    )
    expires_at = now + ttl
    cx.execute(
        "INSERT INTO approval (id, action_version, tool, actor_person_id, route_id, resource, "
        "destination, state, requested_at, expires_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (
            approval_id,
            version,
            tool,
            envelope.actor_person_id,
            envelope.route_id,
            json.dumps(dict(sorted(resource.items())), sort_keys=True, separators=(",", ":")),
            destination,
            STATE_PENDING,
            now.isoformat(),
            expires_at.isoformat(),
        ),
    )
    return load_approval(cx, approval_id=approval_id)


def load_approval(cx: sqlite3.Connection, *, approval_id: str) -> ApprovalRecord:
    row = cx.execute("SELECT * FROM approval WHERE id = ?", (approval_id,)).fetchone()
    if row is None:
        raise ApprovalInvalid(f"no approval {approval_id!r}")
    return _record_from_row(row)


def _require_binding(
    record: ApprovalRecord,
    *,
    envelope: IdentityEnvelope,
    now: datetime,
) -> None:
    """The actor, the route and the expiry: the bindings that hold for both granting
    and spending an approval."""
    if record.actor_person_id != envelope.actor_person_id:
        raise ApprovalInvalid(
            f"approval {record.id} belongs to {record.actor_person_id}, not "
            f"{envelope.actor_person_id}"
        )
    if record.route_id != envelope.route_id:
        raise ApprovalInvalid(
            f"approval {record.id} was raised in {record.route_id}, not {envelope.route_id}"
        )
    if now >= datetime.fromisoformat(record.expires_at):
        raise ApprovalInvalid(f"approval {record.id} expired at {record.expires_at}")


def grant_approval(
    cx: sqlite3.Connection,
    *,
    envelope: IdentityEnvelope,
    approval_id: str,
    now: datetime,
) -> ApprovalRecord:
    record = load_approval(cx, approval_id=approval_id)
    _require_binding(record, envelope=envelope, now=now)
    if record.state != STATE_PENDING:
        raise ApprovalInvalid(f"approval {record.id} is already {record.state}")
    cx.execute(
        "UPDATE approval SET state = ?, granted_at = ?, granted_by_person_id = ? WHERE id = ?",
        (STATE_GRANTED, now.isoformat(), envelope.actor_person_id, approval_id),
    )
    return load_approval(cx, approval_id=approval_id)


def consume_approval(
    cx: sqlite3.Connection,
    *,
    envelope: IdentityEnvelope,
    approval_id: str,
    tool: str,
    destination: str,
    resource: Mapping[str, str],
    now: datetime,
) -> ApprovalRecord:
    """Spend an approval on exactly the action it was granted for, once.

    The action version is recomputed from the arguments at the moment of the write,
    so a proposal that changed between the yes and the write no longer matches.
    """
    record = load_approval(cx, approval_id=approval_id)
    _require_binding(record, envelope=envelope, now=now)
    if record.state != STATE_GRANTED:
        raise ApprovalInvalid(f"approval {record.id} is {record.state}, not granted")
    presented = action_version(
        tool=tool,
        actor_person_id=envelope.actor_person_id,
        destination=destination,
        resource=resource,
    )
    if presented != record.action_version:
        raise ApprovalInvalid(
            f"approval {record.id} was granted for a different action; the proposal changed"
        )
    cx.execute(
        "UPDATE approval SET state = ?, consumed_at = ? WHERE id = ? AND state = ?",
        (STATE_CONSUMED, now.isoformat(), approval_id, STATE_GRANTED),
    )
    return load_approval(cx, approval_id=approval_id)
