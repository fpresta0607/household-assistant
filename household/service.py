"""The scoped household service: one authenticated API over memory, tasks, reminders,
lists, calendars, mail, approvals and integration health.

Authorization lives here and in :mod:`household.store`, never in a prompt. The actor
and the scopes come from the identity envelope the gateway presents; no tool contract
declares an argument that names either one, and an argument a contract does not
declare is refused when it is parsed.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from datetime import datetime

from . import approvals, store
from .approvals import ApprovalRecord
from .db import Database
from .errors import ArgumentInvalid, CapabilityDenied, NotAuthorized, ScopeDenied, ToolUnknown
from .identity import Capability, Clock, EnvelopeIssuer, IdentityEnvelope, system_clock
from .providers import AccountGrant, ProviderEvent, ProviderMailDraft, Providers
from .store import AccountRecord, CalendarRecord
from .tools import (
    REGISTRY,
    ApprovalStatusArgs,
    CalendarAvailabilityArgs,
    CalendarEventCreateArgs,
    CalendarEventProposeArgs,
    ListAddArgs,
    ListItemsArgs,
    ListRemoveArgs,
    MailDigestArgs,
    MailDraftArgs,
    MemorySearchArgs,
    MemoryWriteArgs,
    ReminderCreateArgs,
    ReminderListArgs,
    TaskCompleteArgs,
    TaskCreateArgs,
    TaskListArgs,
    ToolParams,
    parse_arguments,
)

PREVIEW_LENGTH = 120


def _require_window(start: str, end: str) -> None:
    """Both ends arrive as UTC instants from the contract; the window must still be real."""
    if datetime.fromisoformat(start) >= datetime.fromisoformat(end):
        raise ArgumentInvalid(f"start {start!r} must be before end {end!r}")


@dataclass(frozen=True, slots=True)
class BusyInterval:
    uid: str
    start: str
    end: str
    calendar_ids: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class Availability:
    start: str
    end: str
    busy: tuple[BusyInterval, ...]
    complete: bool
    stale_calendar_ids: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class Proposal:
    approval_id: str
    action_version: str
    tool: str
    destination: str
    resource: dict[str, str]
    expires_at: str


@dataclass(frozen=True, slots=True)
class MailSummary:
    account_id: str
    address: str
    message_id: str
    sender: str
    subject: str
    preview: str
    received_at: str


@dataclass(frozen=True, slots=True)
class CalendarHealth:
    calendar_id: str
    last_sync_at: str | None
    healthy: bool


@dataclass(frozen=True, slots=True)
class IntegrationStatus:
    account_id: str
    provider: str
    address: str
    mail_monitored: bool
    mail_last_sync_at: str | None
    mail_healthy: bool
    calendars: tuple[CalendarHealth, ...]


class HouseholdService:
    """Every household operation, behind one authenticated door."""

    def __init__(
        self,
        database: Database,
        issuer: EnvelopeIssuer,
        providers: Providers,
        clock: Clock = system_clock,
    ) -> None:
        self._database = database
        self._issuer = issuer
        self._providers = providers
        self._clock = clock

    def call(
        self,
        envelope: IdentityEnvelope,
        tool_name: str,
        arguments: Mapping[str, object] | None = None,
    ) -> object:
        supplied = dict(arguments or {})
        self._issuer.verify(envelope)

        contract = REGISTRY.get(tool_name)
        if contract is None:
            raise ToolUnknown(f"{tool_name!r} is not a scoped household tool")
        if contract.capability not in envelope.capabilities:
            raise CapabilityDenied(
                f"{tool_name} needs {contract.capability}, which this envelope does not carry"
            )

        params = parse_arguments(contract.params, supplied)
        if tool_name == "integration_health":
            return self._integration_health(envelope)
        return self._dispatch(envelope, tool_name, params)

    def _dispatch(
        self,
        envelope: IdentityEnvelope,
        tool_name: str,
        params: ToolParams,
    ) -> object:
        match params:
            case MemoryWriteArgs():
                return self._memory_write(envelope, params)
            case MemorySearchArgs():
                return self._memory_search(envelope, params)
            case TaskCreateArgs():
                return self._task_create(envelope, params)
            case TaskListArgs():
                return self._task_list(envelope, params)
            case TaskCompleteArgs():
                self._task_complete(envelope, params)
                return None
            case ReminderCreateArgs():
                return self._reminder_create(envelope, params)
            case ReminderListArgs():
                return self._reminder_list(envelope, params)
            case ListAddArgs():
                return self._list_add(envelope, params)
            case ListItemsArgs():
                return self._list_items(envelope, params)
            case ListRemoveArgs():
                self._list_remove(envelope, params)
                return None
            case CalendarAvailabilityArgs():
                return self._calendar_availability(envelope, params)
            case CalendarEventProposeArgs():
                return self._calendar_event_propose(envelope, params)
            case CalendarEventCreateArgs():
                return self._calendar_event_create(envelope, params)
            case MailDigestArgs():
                return self._mail_digest(envelope, params)
            case MailDraftArgs():
                return self._mail_draft(envelope, params)
            case ApprovalStatusArgs():
                return self._approval_status(envelope, params)
            case _:
                raise ToolUnknown(f"{tool_name!r} has no handler")

    # -- authorization helpers -------------------------------------------------

    def _now(self) -> datetime:
        return self._clock()

    def _require_scope(self, envelope: IdentityEnvelope, scope: str) -> None:
        if scope not in envelope.scopes:
            raise ScopeDenied(
                f"{envelope.actor_person_id} cannot reach {scope!r} from this conversation"
            )

    def _grant_for_account(
        self,
        envelope: IdentityEnvelope,
        account_id: str,
    ) -> tuple[AccountGrant, AccountRecord]:
        """Mint the only thing a provider accepts, and only for an account the actor owns."""
        with self._database.read() as cx:
            account = store.account_owned_by(
                cx, account_id=account_id, person_id=envelope.actor_person_id
            )
        if account is None:
            raise NotAuthorized(f"no account {account_id!r} belongs to {envelope.actor_person_id}")
        grant = AccountGrant(
            account_id=account.id,
            person_id=account.person_id,
            envelope_id=envelope.envelope_id,
        )
        return grant, account

    def _writable_calendar(
        self,
        envelope: IdentityEnvelope,
        calendar_id: str,
    ) -> tuple[AccountGrant, CalendarRecord]:
        with self._database.read() as cx:
            calendar = store.calendar_owned_by(
                cx, calendar_id=calendar_id, person_id=envelope.actor_person_id
            )
        if calendar is None:
            raise NotAuthorized(
                f"no calendar {calendar_id!r} belongs to {envelope.actor_person_id}"
            )
        if not calendar.writable:
            raise NotAuthorized(f"calendar {calendar_id!r} is read-only")
        grant, _ = self._grant_for_account(envelope, calendar.account_id)
        return grant, calendar

    # -- memory ----------------------------------------------------------------

    def _memory_write(self, envelope: IdentityEnvelope, params: MemoryWriteArgs) -> str:
        self._require_scope(envelope, params.scope)
        with self._database.write() as cx:
            return store.insert_memory(
                cx,
                scope=params.scope,
                subject=params.subject,
                body=params.body,
                author_person_id=envelope.actor_person_id,
                created_at=self._now().isoformat(),
            )

    def _memory_search(
        self,
        envelope: IdentityEnvelope,
        params: MemorySearchArgs,
    ) -> list[store.MemoryRecord]:
        with self._database.read() as cx:
            return store.search_memory(
                cx, scopes=envelope.scopes, query=params.query, limit=params.limit
            )

    # -- tasks -----------------------------------------------------------------

    def _task_create(self, envelope: IdentityEnvelope, params: TaskCreateArgs) -> str:
        self._require_scope(envelope, params.scope)
        with self._database.write() as cx:
            return store.insert_task(
                cx,
                scope=params.scope,
                title=params.title,
                author_person_id=envelope.actor_person_id,
                created_at=self._now().isoformat(),
            )

    def _task_list(
        self,
        envelope: IdentityEnvelope,
        params: TaskListArgs,
    ) -> list[store.TaskRecord]:
        with self._database.read() as cx:
            return store.list_tasks(cx, scopes=envelope.scopes, include_done=params.include_done)

    def _task_complete(self, envelope: IdentityEnvelope, params: TaskCompleteArgs) -> None:
        with self._database.write() as cx:
            store.complete_task(cx, task_id=params.task_id, scopes=envelope.scopes)

    # -- reminders -------------------------------------------------------------

    def _reminder_create(self, envelope: IdentityEnvelope, params: ReminderCreateArgs) -> str:
        self._require_scope(envelope, params.scope)
        with self._database.write() as cx:
            return store.insert_reminder(
                cx,
                scope=params.scope,
                text=params.text,
                due_at=params.due_at,
                author_person_id=envelope.actor_person_id,
                created_at=self._now().isoformat(),
            )

    def _reminder_list(
        self,
        envelope: IdentityEnvelope,
        params: ReminderListArgs,
    ) -> list[store.ReminderRecord]:
        with self._database.read() as cx:
            return store.list_reminders(cx, scopes=envelope.scopes, due_before=params.due_before)

    # -- lists -----------------------------------------------------------------

    def _list_add(self, envelope: IdentityEnvelope, params: ListAddArgs) -> str:
        self._require_scope(envelope, params.scope)
        with self._database.write() as cx:
            return store.add_list_item(
                cx,
                scope=params.scope,
                list_name=params.list_name,
                text=params.text,
                added_by_person_id=envelope.actor_person_id,
                created_at=self._now().isoformat(),
            )

    def _list_items(
        self,
        envelope: IdentityEnvelope,
        params: ListItemsArgs,
    ) -> list[store.ListItemRecord]:
        self._require_scope(envelope, params.scope)
        with self._database.read() as cx:
            return store.list_items(
                cx, scopes={params.scope} & envelope.scopes, list_name=params.list_name
            )

    def _list_remove(self, envelope: IdentityEnvelope, params: ListRemoveArgs) -> None:
        with self._database.write() as cx:
            store.remove_list_item(
                cx,
                item_id=params.item_id,
                scopes=envelope.scopes,
                removed_at=self._now().isoformat(),
            )

    # -- calendar --------------------------------------------------------------

    def _calendar_availability(
        self,
        envelope: IdentityEnvelope,
        params: CalendarAvailabilityArgs,
    ) -> Availability:
        _require_window(params.start, params.end)
        with self._database.read() as cx:
            accounts = store.accounts_for_person(cx, person_id=envelope.actor_person_id)
            calendars = store.calendars_for_accounts(
                cx, account_ids=[account.id for account in accounts]
            )

        intervals: dict[tuple[str, datetime, datetime], BusyInterval] = {}
        stale: list[str] = []
        for calendar in calendars:
            if not calendar.counts_toward_availability:
                continue
            if calendar.last_sync_at is None:
                # Silence is never availability. An unsynced calendar makes the answer
                # incomplete rather than free.
                stale.append(calendar.id)
                continue
            grant, _ = self._grant_for_account(envelope, calendar.account_id)
            for event in self._providers.calendar.events(
                grant, calendar_id=calendar.id, start=params.start, end=params.end
            ):
                if not event.busy:
                    continue
                # One commitment invited to two addresses is one busy interval, matched
                # on the provider's own identity and never on a title and time. The
                # times are part of the key because a recurring event gives every
                # occurrence the same uid, and those are separate commitments. They are
                # instants, so two providers rendering one moment in different offsets
                # still meet on the same key.
                key = (
                    event.uid,
                    datetime.fromisoformat(event.start),
                    datetime.fromisoformat(event.end),
                )
                existing = intervals.get(key)
                if existing is None:
                    intervals[key] = BusyInterval(
                        uid=event.uid,
                        start=event.start,
                        end=event.end,
                        calendar_ids=(calendar.id,),
                    )
                elif calendar.id not in existing.calendar_ids:
                    intervals[key] = BusyInterval(
                        uid=existing.uid,
                        start=existing.start,
                        end=existing.end,
                        calendar_ids=(*existing.calendar_ids, calendar.id),
                    )

        busy = tuple(
            sorted(
                intervals.values(),
                key=lambda interval: (
                    datetime.fromisoformat(interval.start),
                    datetime.fromisoformat(interval.end),
                    interval.uid,
                ),
            )
        )
        return Availability(
            start=params.start,
            end=params.end,
            busy=busy,
            complete=not stale,
            stale_calendar_ids=tuple(sorted(stale)),
        )

    def _calendar_event_propose(
        self,
        envelope: IdentityEnvelope,
        params: CalendarEventProposeArgs,
    ) -> Proposal:
        _require_window(params.start, params.end)
        self._writable_calendar(envelope, params.calendar_id)
        resource = {"title": params.title, "start": params.start, "end": params.end}
        with self._database.write() as cx:
            record = approvals.create_approval(
                cx,
                envelope=envelope,
                tool="calendar_event_create",
                destination=params.calendar_id,
                resource=resource,
                now=self._now(),
            )
        return Proposal(
            approval_id=record.id,
            action_version=record.action_version,
            tool=record.tool,
            destination=record.destination,
            resource=resource,
            expires_at=record.expires_at,
        )

    def _calendar_event_create(
        self,
        envelope: IdentityEnvelope,
        params: CalendarEventCreateArgs,
    ) -> ProviderEvent:
        _require_window(params.start, params.end)
        grant, _ = self._writable_calendar(envelope, params.calendar_id)
        resource = {"title": params.title, "start": params.start, "end": params.end}
        with self._database.write() as cx:
            approvals.consume_approval(
                cx,
                envelope=envelope,
                approval_id=params.approval_id,
                tool="calendar_event_create",
                destination=params.calendar_id,
                resource=resource,
                now=self._now(),
            )
            return self._providers.calendar.create_event(
                grant,
                calendar_id=params.calendar_id,
                title=params.title,
                start=params.start,
                end=params.end,
            )

    # -- mail ------------------------------------------------------------------

    def _mail_digest(
        self,
        envelope: IdentityEnvelope,
        params: MailDigestArgs,
    ) -> list[MailSummary]:
        with self._database.read() as cx:
            accounts = store.accounts_for_person(cx, person_id=envelope.actor_person_id)

        summaries: list[MailSummary] = []
        for account in accounts:
            if not (account.mail_monitored and account.mail_digest):
                continue
            grant, _ = self._grant_for_account(envelope, account.id)
            for message in self._providers.mail.inbox(grant, limit=params.limit):
                # A message body is data. Nothing here reads it for an instruction,
                # an approval, or an identity.
                summaries.append(
                    MailSummary(
                        account_id=account.id,
                        address=account.address,
                        message_id=message.message_id,
                        sender=message.sender,
                        subject=message.subject,
                        preview=message.body[:PREVIEW_LENGTH],
                        received_at=message.received_at,
                    )
                )
        return summaries

    def _mail_draft(
        self,
        envelope: IdentityEnvelope,
        params: MailDraftArgs,
    ) -> ProviderMailDraft:
        grant, account = self._grant_for_account(envelope, params.account_id)
        if not account.mail_writable:
            raise NotAuthorized(f"account {account.id!r} is monitored read-only")
        return self._providers.mail.draft(
            grant, to=params.to, subject=params.subject, body=params.body
        )

    # -- approvals -------------------------------------------------------------

    def grant_approval(self, envelope: IdentityEnvelope, approval_id: str) -> ApprovalRecord:
        """A person's yes, arriving on the route that raised the proposal.

        Deliberately not a tool. The loop that proposes an action must not be able to
        approve it, so the only way in is an inbound message the gateway resolves.
        """
        self._issuer.verify(envelope)
        if Capability.APPROVAL_GRANT not in envelope.capabilities:
            raise CapabilityDenied(
                f"approving needs {Capability.APPROVAL_GRANT}, which this envelope does not carry"
            )
        with self._database.write() as cx:
            return approvals.grant_approval(
                cx, envelope=envelope, approval_id=approval_id, now=self._now()
            )

    def _approval_status(
        self,
        envelope: IdentityEnvelope,
        params: ApprovalStatusArgs,
    ) -> ApprovalRecord:
        with self._database.read() as cx:
            record = approvals.load_approval(cx, approval_id=params.approval_id)
        if record.actor_person_id != envelope.actor_person_id:
            raise NotAuthorized(f"approval {record.id} belongs to another person")
        return record

    # -- integration health ----------------------------------------------------

    def _integration_health(self, envelope: IdentityEnvelope) -> list[IntegrationStatus]:
        with self._database.read() as cx:
            accounts = store.accounts_for_person(cx, person_id=envelope.actor_person_id)
            calendars = store.calendars_for_accounts(
                cx, account_ids=[account.id for account in accounts]
            )

        by_account: dict[str, list[CalendarHealth]] = {account.id: [] for account in accounts}
        for calendar in calendars:
            by_account[calendar.account_id].append(
                CalendarHealth(
                    calendar_id=calendar.id,
                    last_sync_at=calendar.last_sync_at,
                    healthy=calendar.last_sync_at is not None,
                )
            )
        return [
            IntegrationStatus(
                account_id=account.id,
                provider=account.provider,
                address=account.address,
                mail_monitored=account.mail_monitored,
                mail_last_sync_at=account.mail_last_sync_at,
                mail_healthy=not account.mail_monitored or account.mail_last_sync_at is not None,
                calendars=tuple(by_account[account.id]),
            )
            for account in accounts
        ]


__all__ = [
    "Availability",
    "BusyInterval",
    "CalendarHealth",
    "HouseholdService",
    "IntegrationStatus",
    "MailSummary",
    "Proposal",
]
