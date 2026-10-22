"""Who is speaking, what they may see, and the envelope that carries the answer.

The authenticated sender decides what "my" means. Nothing in this module reads a
display name, a message body, a forwarded header, or an id a model supplied.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import secrets
import uuid
from collections.abc import Callable, Collection
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from enum import StrEnum

from .db import Database
from .errors import EnvelopeInvalid, NotAuthorized, RouteNotApproved, UnknownSender

SCOPE_FRANCO_PRIVATE = "franco_private"
SCOPE_GIA_PRIVATE = "gia_private"
SCOPE_HOUSEHOLD_SHARED = "household_shared"
ALL_SCOPES = frozenset({SCOPE_FRANCO_PRIVATE, SCOPE_GIA_PRIVATE, SCOPE_HOUSEHOLD_SHARED})
PRIVATE_SCOPES = frozenset({SCOPE_FRANCO_PRIVATE, SCOPE_GIA_PRIVATE})

ROUTE_DIRECT = "direct"
ROUTE_GROUP = "group"

ENVELOPE_TTL = timedelta(minutes=5)

Clock = Callable[[], datetime]


def system_clock() -> datetime:
    return datetime.now(UTC)


def private_scope_for(person_id: str) -> str:
    """The one memory scope that belongs to this person and to nobody else."""
    return f"{person_id}_private"


class Capability(StrEnum):
    """What an envelope may reach. A group route carries fewer of these than a direct one."""

    MEMORY_READ = "memory:read"
    MEMORY_WRITE = "memory:write"
    TASK_READ = "task:read"
    TASK_WRITE = "task:write"
    REMINDER_READ = "reminder:read"
    REMINDER_WRITE = "reminder:write"
    LIST_READ = "list:read"
    LIST_WRITE = "list:write"
    CALENDAR_READ = "calendar:read"
    CALENDAR_WRITE = "calendar:write"
    MAIL_READ = "mail:read"
    MAIL_DRAFT = "mail:draft"
    APPROVAL_READ = "approval:read"
    APPROVAL_GRANT = "approval:grant"
    HEALTH_READ = "health:read"


HOUSEHOLD_MEMBER_CAPABILITIES = frozenset(Capability)

# A person's connected accounts and their approvals belong to that person. The household
# group is read by both people, so an envelope minted there carries nothing that reaches
# one person's mail, calendars, account addresses or pending approvals.
PRIVATE_ROUTE_CAPABILITIES = frozenset(
    {
        Capability.CALENDAR_READ,
        Capability.CALENDAR_WRITE,
        Capability.MAIL_READ,
        Capability.MAIL_DRAFT,
        Capability.APPROVAL_READ,
        Capability.APPROVAL_GRANT,
        Capability.HEALTH_READ,
    }
)
HOUSEHOLD_GROUP_CAPABILITIES = HOUSEHOLD_MEMBER_CAPABILITIES - PRIVATE_ROUTE_CAPABILITIES


@dataclass(frozen=True, slots=True)
class IdentityEnvelope:
    """The only thing the household service trusts.

    It is minted by :class:`IdentityResolver` from authenticated channel metadata and
    signed, so a gateway - or a model driving one - cannot hand the service an actor
    of its choosing.
    """

    envelope_id: str
    actor_person_id: str
    persona_id: str
    channel: str
    route_id: str
    route_kind: str
    scopes: frozenset[str]
    capabilities: frozenset[Capability]
    issued_at: datetime
    expires_at: datetime
    signature: str

    def has(self, capability: Capability) -> bool:
        return capability in self.capabilities


def _signing_payload(
    *,
    envelope_id: str,
    actor_person_id: str,
    persona_id: str,
    channel: str,
    route_id: str,
    route_kind: str,
    scopes: Collection[str],
    capabilities: Collection[Capability],
    issued_at: datetime,
    expires_at: datetime,
) -> bytes:
    return json.dumps(
        {
            "envelope_id": envelope_id,
            "actor_person_id": actor_person_id,
            "persona_id": persona_id,
            "channel": channel,
            "route_id": route_id,
            "route_kind": route_kind,
            "scopes": sorted(scopes),
            "capabilities": sorted(str(capability) for capability in capabilities),
            "issued_at": issued_at.isoformat(),
            "expires_at": expires_at.isoformat(),
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


class EnvelopeIssuer:
    """Mints and verifies identity envelopes.

    The secret is process scoped, which is right while the gateway and the service
    share a process. ponytail: move it to the credential store the day Phase 2 splits
    them apart, and nothing else here changes.
    """

    def __init__(self, secret: bytes | None = None, clock: Clock = system_clock) -> None:
        self._secret = secret if secret is not None else secrets.token_bytes(32)
        self._clock = clock

    def _sign(self, payload: bytes) -> str:
        return hmac.new(self._secret, payload, hashlib.sha256).hexdigest()

    def issue(
        self,
        *,
        actor_person_id: str,
        persona_id: str,
        channel: str,
        route_id: str,
        route_kind: str,
        scopes: Collection[str],
        capabilities: Collection[Capability],
        expires_at: datetime | None = None,
    ) -> IdentityEnvelope:
        issued_at = self._clock()
        expiry = expires_at if expires_at is not None else issued_at + ENVELOPE_TTL
        envelope_id = uuid.uuid4().hex
        signature = self._sign(
            _signing_payload(
                envelope_id=envelope_id,
                actor_person_id=actor_person_id,
                persona_id=persona_id,
                channel=channel,
                route_id=route_id,
                route_kind=route_kind,
                scopes=scopes,
                capabilities=capabilities,
                issued_at=issued_at,
                expires_at=expiry,
            )
        )
        return IdentityEnvelope(
            envelope_id=envelope_id,
            actor_person_id=actor_person_id,
            persona_id=persona_id,
            channel=channel,
            route_id=route_id,
            route_kind=route_kind,
            scopes=frozenset(scopes),
            capabilities=frozenset(capabilities),
            issued_at=issued_at,
            expires_at=expiry,
            signature=signature,
        )

    def verify(self, envelope: IdentityEnvelope) -> None:
        expected = self._sign(
            _signing_payload(
                envelope_id=envelope.envelope_id,
                actor_person_id=envelope.actor_person_id,
                persona_id=envelope.persona_id,
                channel=envelope.channel,
                route_id=envelope.route_id,
                route_kind=envelope.route_kind,
                scopes=envelope.scopes,
                capabilities=envelope.capabilities,
                issued_at=envelope.issued_at,
                expires_at=envelope.expires_at,
            )
        )
        if not hmac.compare_digest(expected, envelope.signature):
            raise EnvelopeInvalid("identity envelope was not issued by this household")
        if self._clock() >= envelope.expires_at:
            raise EnvelopeInvalid("identity envelope has expired")

    def delegate(
        self,
        envelope: IdentityEnvelope,
        *,
        capabilities: Collection[Capability],
        scopes: Collection[str] | None = None,
    ) -> IdentityEnvelope:
        """Narrow an envelope for a sub-task.

        The actor, the persona and the route are carried through untouched. A
        delegate may drop capabilities and scopes; it may never add one, and it may
        never outlive its parent.
        """
        self.verify(envelope)
        requested_capabilities = frozenset(capabilities)
        if not requested_capabilities <= envelope.capabilities:
            escalated = sorted(str(c) for c in requested_capabilities - envelope.capabilities)
            raise NotAuthorized(f"delegation cannot add capabilities: {', '.join(escalated)}")
        requested_scopes = frozenset(scopes) if scopes is not None else envelope.scopes
        if not requested_scopes <= envelope.scopes:
            widened = sorted(requested_scopes - envelope.scopes)
            raise NotAuthorized(f"delegation cannot add scopes: {', '.join(widened)}")
        return self.issue(
            actor_person_id=envelope.actor_person_id,
            persona_id=envelope.persona_id,
            channel=envelope.channel,
            route_id=envelope.route_id,
            route_kind=envelope.route_kind,
            scopes=requested_scopes,
            capabilities=requested_capabilities,
            expires_at=envelope.expires_at,
        )


@dataclass(frozen=True, slots=True)
class InboundMessage:
    """A message as a channel hands it over.

    Only ``channel``, ``sender_channel_id``, ``chat_id`` and ``addressed_persona_id``
    are authenticated by the channel. Everything below them is decoration that a
    sender - or anything quoted inside the message - controls, and the resolver
    reads none of it.
    """

    channel: str
    sender_channel_id: str
    chat_id: str
    addressed_persona_id: str
    text: str = ""
    display_name: str | None = None
    forwarded_from_channel_id: str | None = None
    claimed_person_id: str | None = None


class IdentityResolver:
    """Turns authenticated channel metadata into a signed envelope, or refuses."""

    def __init__(self, database: Database, issuer: EnvelopeIssuer) -> None:
        self._database = database
        self._issuer = issuer

    def resolve(self, message: InboundMessage) -> IdentityEnvelope:
        with self._database.read() as cx:
            sender = cx.execute(
                "SELECT person_id FROM channel_identity WHERE channel = ? AND channel_user_id = ?",
                (message.channel, message.sender_channel_id),
            ).fetchone()
            if sender is None:
                raise UnknownSender(
                    f"no enrolled person for {message.channel}:{message.sender_channel_id}"
                )
            person_id = str(sender["person_id"])

            route = cx.execute(
                "SELECT id, kind, persona_id, approved FROM route "
                "WHERE channel = ? AND channel_chat_id = ?",
                (message.channel, message.chat_id),
            ).fetchone()
            if route is None or not route["approved"]:
                raise RouteNotApproved(
                    f"{message.channel}:{message.chat_id} is not an approved route"
                )
            route_id = str(route["id"])
            route_kind = str(route["kind"])

            member = cx.execute(
                "SELECT 1 FROM route_member WHERE route_id = ? AND person_id = ?",
                (route_id, person_id),
            ).fetchone()
            if member is None:
                raise NotAuthorized(f"{person_id} is not a member of route {route_id}")

            persona_id = (
                str(route["persona_id"])
                if route["persona_id"] is not None
                else message.addressed_persona_id
            )
            if cx.execute("SELECT 1 FROM persona WHERE id = ?", (persona_id,)).fetchone() is None:
                raise NotAuthorized(f"{persona_id!r} is not a household persona")

        # The split happens here, before anything is retrieved and long before a prompt
        # is assembled. A group route never carries a private scope, for anyone, and it
        # never carries a capability that reaches one person's accounts or approvals.
        scopes = {SCOPE_HOUSEHOLD_SHARED}
        capabilities = HOUSEHOLD_GROUP_CAPABILITIES
        if route_kind == ROUTE_DIRECT:
            scopes.add(private_scope_for(person_id))
            capabilities = HOUSEHOLD_MEMBER_CAPABILITIES

        return self._issuer.issue(
            actor_person_id=person_id,
            persona_id=persona_id,
            channel=message.channel,
            route_id=route_id,
            route_kind=route_kind,
            scopes=scopes,
            capabilities=capabilities,
        )


def seed_household(database: Database) -> None:
    """The four identities the plan names. Two people, two personas, nothing else."""
    with database.write() as cx:
        cx.executemany(
            "INSERT OR IGNORE INTO person (id, display_name) VALUES (?, ?)",
            [("franco", "Franco"), ("gia", "Gia")],
        )
        cx.executemany(
            "INSERT OR IGNORE INTO persona (id, display_name) VALUES (?, ?)",
            [("corey", "Corey"), ("denise", "Denise")],
        )


def enroll_channel_identity(
    database: Database,
    *,
    channel: str,
    channel_user_id: str,
    person_id: str,
    clock: Clock = system_clock,
) -> None:
    """Bind a channel account to a person. Only an enrolled sender is ever resolved."""
    with database.write() as cx:
        cx.execute(
            "INSERT INTO channel_identity (channel, channel_user_id, person_id, enrolled_at) "
            "VALUES (?, ?, ?, ?)",
            (channel, channel_user_id, person_id, clock().isoformat()),
        )


def register_route(
    database: Database,
    *,
    route_id: str,
    channel: str,
    channel_chat_id: str,
    kind: str,
    members: Collection[str],
    persona_id: str | None = None,
    approved: bool = False,
) -> None:
    """Record a conversation. It stays inert until someone approves it.

    A direct route is one person alone with a persona, and that is what earns it the
    private scope. Two people in a "direct" route would each read the other's private
    answers, so the shape is refused before anything is written.
    """
    member_ids = set(members)
    if kind == ROUTE_DIRECT and len(member_ids) != 1:
        raise ValueError(
            f"a direct route has exactly one member, {route_id!r} names {len(member_ids)}"
        )
    with database.write() as cx:
        cx.execute(
            "INSERT INTO route (id, channel, channel_chat_id, kind, persona_id, approved) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (route_id, channel, channel_chat_id, kind, persona_id, int(approved)),
        )
        cx.executemany(
            "INSERT INTO route_member (route_id, person_id) VALUES (?, ?)",
            [(route_id, person_id) for person_id in members],
        )
