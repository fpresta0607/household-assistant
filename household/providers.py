"""Mock calendar, mail and messaging providers.

Phase 1 proves the shape; Phase 3 and Phase 4 replace the bodies with Google,
Microsoft Graph and CalDAV. Every provider entry point takes an :class:`AccountGrant`
rather than a bare account id, and the service mints one only after checking that the
envelope's actor owns the account.

That check lives in the service, not here. In this phase the grant is an in-process
convention: it is a plain dataclass, nothing verifies who built it, and a provider
trusts the account id it names. The enforced boundary is the service's tool registry
one layer up. ponytail: sign the grant through EnvelopeIssuer and verify it at every
provider entry point before Phase 3 hands a provider a real credential, because from
then on anything that can build this dataclass could read that account.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime

from .identity import IdentityEnvelope


@dataclass(frozen=True, slots=True)
class AccountGrant:
    """The account the service checked the actor owns.

    An in-process convention in this phase, not a verified token: see the module
    docstring for what that means and when it must change.
    """

    account_id: str
    person_id: str
    envelope_id: str


@dataclass(frozen=True, slots=True)
class ProviderEvent:
    uid: str
    calendar_id: str
    title: str
    start: str
    end: str
    busy: bool = True


@dataclass(frozen=True, slots=True)
class ProviderMailMessage:
    message_id: str
    sender: str
    subject: str
    body: str
    received_at: str


@dataclass(frozen=True, slots=True)
class ProviderMailDraft:
    draft_id: str
    account_id: str
    to: str
    subject: str
    body: str


@dataclass(frozen=True, slots=True)
class OutboundMessage:
    route_id: str
    persona_id: str
    actor_person_id: str
    text: str


@dataclass
class MockCalendarProvider:
    """Events keyed by the account that owns them, so a grant cannot reach past itself."""

    _events: dict[tuple[str, str], list[ProviderEvent]] = field(
        default_factory=lambda: defaultdict(list)
    )
    created: list[ProviderEvent] = field(default_factory=list)

    def seed(self, *, account_id: str, event: ProviderEvent) -> None:
        self._events[(account_id, event.calendar_id)].append(event)

    def events(
        self,
        grant: AccountGrant,
        *,
        calendar_id: str,
        start: str,
        end: str,
    ) -> list[ProviderEvent]:
        stored = self._events.get((grant.account_id, calendar_id), [])
        window_start = datetime.fromisoformat(start)
        window_end = datetime.fromisoformat(end)
        return [
            event
            for event in stored
            if datetime.fromisoformat(event.start) < window_end
            and datetime.fromisoformat(event.end) > window_start
        ]

    def create_event(
        self,
        grant: AccountGrant,
        *,
        calendar_id: str,
        title: str,
        start: str,
        end: str,
    ) -> ProviderEvent:
        event = ProviderEvent(
            uid=f"mock-{len(self.created) + 1}",
            calendar_id=calendar_id,
            title=title,
            start=start,
            end=end,
        )
        self._events[(grant.account_id, calendar_id)].append(event)
        self.created.append(event)
        return event


@dataclass
class MockMailProvider:
    """One inbox and one draft folder per account, reachable only with that account's grant."""

    _inboxes: dict[str, list[ProviderMailMessage]] = field(
        default_factory=lambda: defaultdict(list)
    )
    drafts: list[ProviderMailDraft] = field(default_factory=list)

    def seed(self, *, account_id: str, message: ProviderMailMessage) -> None:
        self._inboxes[account_id].append(message)

    def inbox(self, grant: AccountGrant, *, limit: int) -> list[ProviderMailMessage]:
        return self._inboxes.get(grant.account_id, [])[:limit]

    def draft(
        self,
        grant: AccountGrant,
        *,
        to: str,
        subject: str,
        body: str,
    ) -> ProviderMailDraft:
        draft = ProviderMailDraft(
            draft_id=f"draft-{len(self.drafts) + 1}",
            account_id=grant.account_id,
            to=to,
            subject=subject,
            body=body,
        )
        self.drafts.append(draft)
        return draft


@dataclass
class MockMessagingProvider:
    """Replies go back to the route the envelope came from, and there is no other option.

    Deliberately there is no destination argument. A result fetched in a private chat
    cannot be addressed at the household group, because nothing can name a route.
    """

    sent: list[OutboundMessage] = field(default_factory=list)

    def send(self, envelope: IdentityEnvelope, text: str) -> None:
        self.sent.append(
            OutboundMessage(
                route_id=envelope.route_id,
                persona_id=envelope.persona_id,
                actor_person_id=envelope.actor_person_id,
                text=text,
            )
        )

    def sent_to(self, route_id: str) -> list[OutboundMessage]:
        return [message for message in self.sent if message.route_id == route_id]


@dataclass(frozen=True, slots=True)
class Providers:
    calendar: MockCalendarProvider
    mail: MockMailProvider
    messaging: MockMessagingProvider


def mock_providers() -> Providers:
    return Providers(
        calendar=MockCalendarProvider(),
        mail=MockMailProvider(),
        messaging=MockMessagingProvider(),
    )
