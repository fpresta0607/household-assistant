"""Calendars, mail and integration health against the mock providers."""

from __future__ import annotations

import pytest

from household.app import Household
from household.errors import ArgumentInvalid, NotAuthorized
from household.providers import ProviderEvent, ProviderMailDraft, ProviderMailMessage
from household.service import Availability, IntegrationStatus, MailSummary

from .conftest import (
    CAL_FRANCO_OUTLOOK,
    CAL_FRANCO_PERSONAL,
    CAL_FRANCO_WORK,
    CAL_GIA,
    FRANCO_GMAIL_PERSONAL,
    FRANCO_GMAIL_WORK,
    FRANCO_OUTLOOK,
    GIA_GMAIL,
    franco_envelope,
    gia_envelope,
)

WINDOW = {"start": "2026-09-18T00:00:00+00:00", "end": "2026-09-19T00:00:00+00:00"}


def _event(uid: str, calendar_id: str, start: str, end: str, *, busy: bool = True) -> ProviderEvent:
    return ProviderEvent(
        uid=uid, calendar_id=calendar_id, title="x", start=start, end=end, busy=busy
    )


def _availability(household: Household) -> Availability:
    result = household.service.call(franco_envelope(household), "calendar_availability", WINDOW)
    assert isinstance(result, Availability)
    return result


def test_availability_is_a_union_across_every_counting_account(household: Household) -> None:
    household.providers.calendar.seed(
        account_id=FRANCO_GMAIL_PERSONAL,
        event=_event(
            "gmail-1", CAL_FRANCO_PERSONAL, "2026-09-18T09:00:00+00:00", "2026-09-18T10:00:00+00:00"
        ),
    )
    household.providers.calendar.seed(
        account_id=FRANCO_OUTLOOK,
        event=_event(
            "outlook-1",
            CAL_FRANCO_OUTLOOK,
            "2026-09-18T14:00:00+00:00",
            "2026-09-18T15:00:00+00:00",
        ),
    )

    availability = _availability(household)
    assert [interval.uid for interval in availability.busy] == ["gmail-1", "outlook-1"]
    assert availability.complete is True


def test_one_meeting_invited_to_two_addresses_counts_once(household: Household) -> None:
    """Deduplicated on the provider's own identity, never on a matching title and time."""
    for account_id, calendar_id in (
        (FRANCO_GMAIL_PERSONAL, CAL_FRANCO_PERSONAL),
        (FRANCO_OUTLOOK, CAL_FRANCO_OUTLOOK),
    ):
        household.providers.calendar.seed(
            account_id=account_id,
            event=_event(
                "shared-uid",
                calendar_id,
                "2026-09-18T11:00:00+00:00",
                "2026-09-18T12:00:00+00:00",
            ),
        )

    availability = _availability(household)
    assert len(availability.busy) == 1
    assert set(availability.busy[0].calendar_ids) == {CAL_FRANCO_PERSONAL, CAL_FRANCO_OUTLOOK}


def test_two_occurrences_of_one_recurring_event_both_count(household: Household) -> None:
    """A recurring series gives every occurrence the same uid; they are separate commitments."""
    occurrences = (
        ("2026-09-18T09:00:00+00:00", "2026-09-18T09:30:00+00:00"),
        ("2026-09-18T14:00:00+00:00", "2026-09-18T14:30:00+00:00"),
    )
    for start, end in occurrences:
        household.providers.calendar.seed(
            account_id=FRANCO_GMAIL_PERSONAL,
            event=_event("standup", CAL_FRANCO_PERSONAL, start, end),
        )

    busy = _availability(household).busy
    assert [(interval.start, interval.end) for interval in busy] == list(occurrences)
    assert [interval.calendar_ids for interval in busy] == [
        (CAL_FRANCO_PERSONAL,),
        (CAL_FRANCO_PERSONAL,),
    ]


def test_two_real_events_at_the_same_time_are_not_merged(household: Household) -> None:
    for uid, account_id, calendar_id in (
        ("a", FRANCO_GMAIL_PERSONAL, CAL_FRANCO_PERSONAL),
        ("b", FRANCO_OUTLOOK, CAL_FRANCO_OUTLOOK),
    ):
        household.providers.calendar.seed(
            account_id=account_id,
            event=_event(
                uid, calendar_id, "2026-09-18T11:00:00+00:00", "2026-09-18T12:00:00+00:00"
            ),
        )
    assert len(_availability(household).busy) == 2


def test_a_calendar_marked_not_to_count_is_left_out(household: Household) -> None:
    household.providers.calendar.seed(
        account_id=FRANCO_GMAIL_WORK,
        event=_event(
            "work-1", CAL_FRANCO_WORK, "2026-09-18T09:00:00+00:00", "2026-09-18T10:00:00+00:00"
        ),
    )
    availability = _availability(household)
    assert availability.busy == ()
    assert availability.complete is True


def test_a_free_event_does_not_make_anyone_busy(household: Household) -> None:
    household.providers.calendar.seed(
        account_id=FRANCO_GMAIL_PERSONAL,
        event=_event(
            "free-1",
            CAL_FRANCO_PERSONAL,
            "2026-09-18T09:00:00+00:00",
            "2026-09-18T10:00:00+00:00",
            busy=False,
        ),
    )
    assert _availability(household).busy == ()


def test_a_calendar_that_never_synced_makes_the_answer_incomplete(household: Household) -> None:
    """Silence is never treated as availability."""
    with household.database.write() as cx:
        cx.execute("UPDATE calendar SET last_sync_at = NULL WHERE id = ?", (CAL_FRANCO_OUTLOOK,))

    availability = _availability(household)
    assert availability.complete is False
    assert availability.stale_calendar_ids == (CAL_FRANCO_OUTLOOK,)


def test_availability_never_reaches_the_other_persons_calendar(household: Household) -> None:
    household.providers.calendar.seed(
        account_id=GIA_GMAIL,
        event=_event("gia-1", CAL_GIA, "2026-09-18T09:00:00+00:00", "2026-09-18T10:00:00+00:00"),
    )
    assert _availability(household).busy == ()

    gia_view = household.service.call(gia_envelope(household), "calendar_availability", WINDOW)
    assert isinstance(gia_view, Availability)
    assert [interval.uid for interval in gia_view.busy] == ["gia-1"]


def test_the_digest_covers_every_monitored_account_of_the_actor(household: Household) -> None:
    for index, account_id in enumerate(
        (FRANCO_GMAIL_PERSONAL, FRANCO_GMAIL_WORK, FRANCO_OUTLOOK, GIA_GMAIL)
    ):
        household.providers.mail.seed(
            account_id=account_id,
            message=ProviderMailMessage(
                message_id=f"m{index}",
                sender="someone@example.com",
                subject=f"subject {account_id}",
                body="body",
                received_at="2026-09-17T08:00:00+00:00",
            ),
        )

    digest = household.service.call(franco_envelope(household), "mail_digest", {})
    assert isinstance(digest, list)
    accounts = {summary.account_id for summary in digest if isinstance(summary, MailSummary)}
    assert accounts == {FRANCO_GMAIL_PERSONAL, FRANCO_GMAIL_WORK, FRANCO_OUTLOOK}


def test_a_draft_goes_to_a_writable_account_and_is_never_sent(household: Household) -> None:
    draft = household.service.call(
        franco_envelope(household),
        "mail_draft",
        {
            "account_id": FRANCO_GMAIL_PERSONAL,
            "to": "gia@example.com",
            "subject": "dinner",
            "body": "seven?",
        },
    )
    assert isinstance(draft, ProviderMailDraft)
    assert household.providers.mail.drafts == [draft]


def test_a_read_only_mailbox_refuses_a_draft(household: Household) -> None:
    with pytest.raises(NotAuthorized, match="read-only"):
        household.service.call(
            franco_envelope(household),
            "mail_draft",
            {
                "account_id": FRANCO_GMAIL_WORK,
                "to": "colleague@example.com",
                "subject": "x",
                "body": "y",
            },
        )


def test_integration_health_names_only_the_actors_own_accounts(household: Household) -> None:
    statuses = household.service.call(franco_envelope(household), "integration_health", {})
    assert isinstance(statuses, list)
    reported = {status.account_id for status in statuses if isinstance(status, IntegrationStatus)}
    assert reported == {FRANCO_GMAIL_PERSONAL, FRANCO_GMAIL_WORK, FRANCO_OUTLOOK}

    gia_statuses = household.service.call(gia_envelope(household), "integration_health", {})
    assert isinstance(gia_statuses, list)
    assert {status.account_id for status in gia_statuses} == {GIA_GMAIL}


def test_integration_health_reports_an_unsynced_calendar_as_unhealthy(
    household: Household,
) -> None:
    with household.database.write() as cx:
        cx.execute("UPDATE calendar SET last_sync_at = NULL WHERE id = ?", (CAL_FRANCO_OUTLOOK,))

    statuses = household.service.call(franco_envelope(household), "integration_health", {})
    assert isinstance(statuses, list)
    unhealthy = {
        calendar.calendar_id
        for status in statuses
        if isinstance(status, IntegrationStatus)
        for calendar in status.calendars
        if not calendar.healthy
    }
    assert unhealthy == {CAL_FRANCO_OUTLOOK}


def test_the_household_list_is_shared_between_both_people(household: Household) -> None:
    franco = franco_envelope(household)
    household.service.call(franco, "list_add", {"list_name": "grocery", "text": "milk"})

    gia = gia_envelope(household)
    household.service.call(gia, "list_add", {"list_name": "grocery", "text": "bread"})

    items = household.service.call(gia, "list_items", {"list_name": "grocery"})
    assert isinstance(items, list)
    assert [item.text for item in items] == ["milk", "bread"]

    household.service.call(franco, "list_remove", {"item_id": items[0].id})
    remaining = household.service.call(gia, "list_items", {"list_name": "grocery"})
    assert isinstance(remaining, list)
    assert [item.text for item in remaining] == ["bread"]


def test_an_event_in_another_offset_still_counts_as_busy(household: Household) -> None:
    """Compared as instants, not as text.

    22:00 to 23:30 at -04:00 is 02:00 to 03:30 UTC on the 19th, inside a window that
    starts at midnight UTC on the 19th. Compared as strings the event's date reads as
    the 18th and it vanishes, and Franco is told he is free during the dinner he booked.
    """
    household.providers.calendar.seed(
        account_id=FRANCO_GMAIL_PERSONAL,
        event=_event(
            "offset-1",
            CAL_FRANCO_PERSONAL,
            "2026-09-18T22:00:00-04:00",
            "2026-09-18T23:30:00-04:00",
        ),
    )
    result = household.service.call(
        franco_envelope(household),
        "calendar_availability",
        {"start": "2026-09-19T00:00:00+00:00", "end": "2026-09-19T12:00:00+00:00"},
    )
    assert isinstance(result, Availability)
    assert [interval.uid for interval in result.busy] == ["offset-1"]


@pytest.mark.parametrize(
    ("start", "end", "expected"),
    [
        ("2026-09-18T09:00:00", "2026-09-18T10:00:00+00:00", "timezone offset"),
        ("tomorrow", "2026-09-18T10:00:00+00:00", "ISO 8601"),
        ("2026-09-18T10:00:00+00:00", "2026-09-18T09:00:00+00:00", "must be before"),
    ],
)
def test_a_window_that_is_not_two_aware_instants_is_refused(
    household: Household, start: str, end: str, expected: str
) -> None:
    for tool, extra in (
        ("calendar_availability", {}),
        ("calendar_event_propose", {"calendar_id": CAL_FRANCO_PERSONAL, "title": "x"}),
    ):
        with pytest.raises(ArgumentInvalid, match=expected):
            household.service.call(
                franco_envelope(household), tool, {"start": start, "end": end, **extra}
            )


def test_busy_intervals_are_ordered_by_instant_not_by_text(household: Household) -> None:
    """22:00 at -04:00 is 02:00 UTC the next day, three hours after 23:00 UTC."""
    household.providers.calendar.seed(
        account_id=FRANCO_GMAIL_PERSONAL,
        event=_event(
            "later", CAL_FRANCO_PERSONAL, "2026-09-18T22:00:00-04:00", "2026-09-18T23:00:00-04:00"
        ),
    )
    household.providers.calendar.seed(
        account_id=FRANCO_OUTLOOK,
        event=_event(
            "earlier", CAL_FRANCO_OUTLOOK, "2026-09-18T23:00:00+00:00", "2026-09-19T00:00:00+00:00"
        ),
    )
    result = household.service.call(
        franco_envelope(household),
        "calendar_availability",
        {"start": "2026-09-18T00:00:00+00:00", "end": "2026-09-19T12:00:00+00:00"},
    )
    assert isinstance(result, Availability)
    assert [interval.uid for interval in result.busy] == ["earlier", "later"]


def test_one_meeting_rendered_in_two_offsets_still_counts_once(household: Household) -> None:
    """Two providers may print the same instant differently; it is still one commitment."""
    for account_id, calendar_id, start, end in (
        (
            FRANCO_GMAIL_PERSONAL,
            CAL_FRANCO_PERSONAL,
            "2026-09-18T11:00:00+00:00",
            "2026-09-18T12:00:00+00:00",
        ),
        (
            FRANCO_OUTLOOK,
            CAL_FRANCO_OUTLOOK,
            "2026-09-18T07:00:00-04:00",
            "2026-09-18T08:00:00-04:00",
        ),
    ):
        household.providers.calendar.seed(
            account_id=account_id, event=_event("shared-uid", calendar_id, start, end)
        )

    availability = _availability(household)
    assert len(availability.busy) == 1
    assert set(availability.busy[0].calendar_ids) == {CAL_FRANCO_PERSONAL, CAL_FRANCO_OUTLOOK}
