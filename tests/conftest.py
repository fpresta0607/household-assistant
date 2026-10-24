"""The household the tests run against: two people, two personas, four accounts."""

from __future__ import annotations

import os
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from household import store
from household.app import Household, build_household
from household.identity import (
    ROUTE_DIRECT,
    ROUTE_GROUP,
    IdentityEnvelope,
    InboundMessage,
    enroll_channel_identity,
    register_route,
)

# The installers read the household's members and identifiers from the box's household
# file. The tests read the made-up ones in the example.
os.environ["HOUSEHOLD_FILE"] = str(
    Path(__file__).resolve().parent.parent / "deploy" / "household.example.json"
)
# On the box each script runs from scripts/, which puts the household file's reader and
# gateway_config on its import path; a test loading one by its path needs the same.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

CHANNEL = "telegram"

FRANCO_TELEGRAM = "1001"
GIA_TELEGRAM = "2002"
STRANGER_TELEGRAM = "9999"

CHAT_FRANCO_COREY = "100"
CHAT_FRANCO_DENISE = "101"
CHAT_GIA_COREY = "200"
CHAT_GIA_DENISE = "201"
CHAT_HOUSEHOLD = "300"
CHAT_UNAPPROVED = "999"

ROUTE_FRANCO_COREY = "telegram:direct:franco-corey"
ROUTE_FRANCO_DENISE = "telegram:direct:franco-denise"
ROUTE_GIA_COREY = "telegram:direct:gia-corey"
ROUTE_GIA_DENISE = "telegram:direct:gia-denise"
ROUTE_HOUSEHOLD = "telegram:group:household"
ROUTE_UNAPPROVED = "telegram:group:book-club"

FRANCO_GMAIL_PERSONAL = "acct-franco-gmail-personal"
FRANCO_GMAIL_WORK = "acct-franco-gmail-work"
FRANCO_OUTLOOK = "acct-franco-outlook"
GIA_GMAIL = "acct-gia-gmail"

CAL_FRANCO_PERSONAL = "cal-franco-personal"
CAL_FRANCO_WORK = "cal-franco-work"
CAL_FRANCO_OUTLOOK = "cal-franco-outlook"
CAL_GIA = "cal-gia"

START_OF_TIME = datetime(2026, 9, 17, 9, 0, tzinfo=UTC)
SYNCED_AT = "2026-09-17T08:55:00+00:00"


class FakeClock:
    """A clock the tests move on purpose, so expiry is tested rather than waited for."""

    def __init__(self, start: datetime) -> None:
        self.now = start

    def __call__(self) -> datetime:
        return self.now

    def advance(self, delta: timedelta) -> None:
        self.now += delta


@pytest.fixture
def clock() -> FakeClock:
    return FakeClock(START_OF_TIME)


@pytest.fixture
def household(tmp_path: Path, clock: FakeClock) -> Household:
    built = build_household(tmp_path / "household.db", clock=clock, secret=b"test-secret")
    _enroll(built, clock)
    _add_accounts(built)
    return built


def _enroll(built: Household, clock: FakeClock) -> None:
    enroll_channel_identity(
        built.database,
        channel=CHANNEL,
        channel_user_id=FRANCO_TELEGRAM,
        person_id="franco",
        clock=clock,
    )
    enroll_channel_identity(
        built.database,
        channel=CHANNEL,
        channel_user_id=GIA_TELEGRAM,
        person_id="gia",
        clock=clock,
    )
    for route_id, chat_id, persona_id, owner in (
        (ROUTE_FRANCO_COREY, CHAT_FRANCO_COREY, "corey", "franco"),
        (ROUTE_FRANCO_DENISE, CHAT_FRANCO_DENISE, "denise", "franco"),
        (ROUTE_GIA_COREY, CHAT_GIA_COREY, "corey", "gia"),
        (ROUTE_GIA_DENISE, CHAT_GIA_DENISE, "denise", "gia"),
    ):
        register_route(
            built.database,
            route_id=route_id,
            channel=CHANNEL,
            channel_chat_id=chat_id,
            kind=ROUTE_DIRECT,
            members=[owner],
            persona_id=persona_id,
            approved=True,
        )
    register_route(
        built.database,
        route_id=ROUTE_HOUSEHOLD,
        channel=CHANNEL,
        channel_chat_id=CHAT_HOUSEHOLD,
        kind=ROUTE_GROUP,
        members=["franco", "gia"],
        approved=True,
    )
    register_route(
        built.database,
        route_id=ROUTE_UNAPPROVED,
        channel=CHANNEL,
        channel_chat_id=CHAT_UNAPPROVED,
        kind=ROUTE_GROUP,
        members=["franco", "gia"],
        approved=False,
    )


def _add_accounts(built: Household) -> None:
    """Franco's two Gmail accounts plus an Outlook that carries a calendar, and Gia's one."""
    with built.database.write() as cx:
        store.add_account(
            cx,
            account_id=FRANCO_GMAIL_PERSONAL,
            person_id="franco",
            provider="google",
            address="franco.personal@example.com",
            mail_monitored=True,
            mail_digest=True,
            mail_writable=True,
            mail_last_sync_at=SYNCED_AT,
        )
        store.add_account(
            cx,
            account_id=FRANCO_GMAIL_WORK,
            person_id="franco",
            provider="google",
            address="franco.work@example.com",
            mail_monitored=True,
            mail_digest=True,
            mail_writable=False,
            mail_last_sync_at=SYNCED_AT,
        )
        store.add_account(
            cx,
            account_id=FRANCO_OUTLOOK,
            person_id="franco",
            provider="microsoft",
            address="franco@example-outlook.com",
            mail_monitored=True,
            mail_digest=True,
            mail_writable=True,
            mail_last_sync_at=SYNCED_AT,
        )
        store.add_account(
            cx,
            account_id=GIA_GMAIL,
            person_id="gia",
            provider="google",
            address="gia@example.com",
            mail_monitored=True,
            mail_digest=True,
            mail_writable=True,
            mail_last_sync_at=SYNCED_AT,
        )
        store.add_calendar(
            cx,
            calendar_id=CAL_FRANCO_PERSONAL,
            account_id=FRANCO_GMAIL_PERSONAL,
            name="Franco personal",
            writable=True,
            last_sync_at=SYNCED_AT,
        )
        store.add_calendar(
            cx,
            calendar_id=CAL_FRANCO_WORK,
            account_id=FRANCO_GMAIL_WORK,
            name="Franco work",
            counts_toward_availability=False,
            writable=False,
            last_sync_at=SYNCED_AT,
        )
        store.add_calendar(
            cx,
            calendar_id=CAL_FRANCO_OUTLOOK,
            account_id=FRANCO_OUTLOOK,
            name="Franco Outlook",
            writable=True,
            last_sync_at=SYNCED_AT,
        )
        store.add_calendar(
            cx,
            calendar_id=CAL_GIA,
            account_id=GIA_GMAIL,
            name="Gia",
            writable=True,
            last_sync_at=SYNCED_AT,
        )


def message(
    *,
    sender: str = FRANCO_TELEGRAM,
    chat: str = CHAT_FRANCO_COREY,
    persona: str = "corey",
    text: str = "",
    display_name: str | None = None,
    forwarded_from_channel_id: str | None = None,
    claimed_person_id: str | None = None,
) -> InboundMessage:
    return InboundMessage(
        channel=CHANNEL,
        sender_channel_id=sender,
        chat_id=chat,
        addressed_persona_id=persona,
        text=text,
        display_name=display_name,
        forwarded_from_channel_id=forwarded_from_channel_id,
        claimed_person_id=claimed_person_id,
    )


def franco_envelope(built: Household) -> IdentityEnvelope:
    return built.resolver.resolve(message())


def gia_envelope(built: Household) -> IdentityEnvelope:
    return built.resolver.resolve(
        message(sender=GIA_TELEGRAM, chat=CHAT_GIA_DENISE, persona="denise")
    )


def group_envelope(built: Household, *, sender: str = FRANCO_TELEGRAM) -> IdentityEnvelope:
    return built.resolver.resolve(message(sender=sender, chat=CHAT_HOUSEHOLD, persona="corey"))
