"""The typed tool contracts."""

from __future__ import annotations

import pytest

from household.app import Household
from household.errors import ArgumentInvalid, CapabilityDenied, ToolUnknown
from household.identity import SCOPE_HOUSEHOLD_SHARED, Capability
from household.service import Proposal
from household.tools import (
    REGISTRY,
    CalendarAvailabilityArgs,
    CalendarEventCreateArgs,
    CalendarEventProposeArgs,
    MemorySearchArgs,
    MemoryWriteArgs,
    ReminderCreateArgs,
    ReminderListArgs,
    TaskListArgs,
    ToolParams,
    parse_arguments,
)

from .conftest import franco_envelope

EXPECTED_TOOLS = {
    "memory_write",
    "memory_search",
    "task_create",
    "task_list",
    "task_complete",
    "reminder_create",
    "reminder_list",
    "list_add",
    "list_items",
    "list_remove",
    "calendar_availability",
    "calendar_event_propose",
    "calendar_event_create",
    "mail_digest",
    "mail_draft",
    "approval_status",
    "integration_health",
}


def test_the_registry_is_exactly_the_set_the_plan_names() -> None:
    assert set(REGISTRY) == EXPECTED_TOOLS


def test_required_arguments_are_required() -> None:
    with pytest.raises(ArgumentInvalid, match="missing required argument 'body'"):
        parse_arguments(MemoryWriteArgs, {"scope": SCOPE_HOUSEHOLD_SHARED, "subject": "s"})


def test_an_unknown_argument_is_refused_rather_than_ignored() -> None:
    with pytest.raises(ArgumentInvalid, match="no argument named"):
        parse_arguments(MemorySearchArgs, {"query": "x", "sneaky": "y"})


@pytest.mark.parametrize(
    ("arguments", "expected"),
    [
        ({"query": 7}, "must be a string"),
        ({"query": "x", "limit": "20"}, "must be an integer"),
        ({"query": "x", "limit": True}, "must be an integer"),
        ({"query": "x", "limit": 0}, "must be a positive integer"),
        ({"query": "x", "limit": -1}, "must be a positive integer"),
    ],
)
def test_the_wrong_type_is_refused(arguments: dict[str, object], expected: str) -> None:
    with pytest.raises(ArgumentInvalid, match=expected):
        parse_arguments(MemorySearchArgs, arguments)


def test_defaults_apply_when_an_argument_is_absent() -> None:
    assert parse_arguments(MemorySearchArgs, {"query": "x"}).limit == 20
    assert parse_arguments(TaskListArgs, {}).include_done is False
    assert parse_arguments(ReminderListArgs, {}).due_before is None


def test_an_optional_argument_accepts_none_and_a_string() -> None:
    assert parse_arguments(ReminderListArgs, {"due_before": None}).due_before is None
    assert (
        parse_arguments(ReminderListArgs, {"due_before": "2026-09-18T10:00:00+02:00"}).due_before
        == "2026-09-18T08:00:00+00:00"
    )
    with pytest.raises(ArgumentInvalid):
        parse_arguments(ReminderListArgs, {"due_before": 3})


def test_a_tool_with_no_arguments_takes_none() -> None:
    assert parse_arguments(ToolParams, {}) == ToolParams()
    with pytest.raises(ArgumentInvalid):
        parse_arguments(ToolParams, {"anything": 1})


def test_a_tool_outside_the_registry_is_refused(household: Household) -> None:
    franco = franco_envelope(household)
    with pytest.raises(ToolUnknown):
        household.service.call(franco, "memory_search_everything", {"query": "x"})


def test_a_missing_capability_is_refused_before_the_arguments_are_parsed(
    household: Household,
) -> None:
    franco = franco_envelope(household)
    reader = household.issuer.issue(
        actor_person_id=franco.actor_person_id,
        persona_id=franco.persona_id,
        channel=franco.channel,
        route_id=franco.route_id,
        route_kind=franco.route_kind,
        scopes=franco.scopes,
        capabilities={Capability.MEMORY_READ},
    )
    with pytest.raises(CapabilityDenied):
        household.service.call(reader, "task_list", {"not_even_a_real_argument": 1})


def test_a_negative_limit_is_refused_rather_than_becoming_no_limit(
    household: Household,
) -> None:
    """SQLite reads LIMIT -1 as every row, so a negative row count never reaches it."""
    franco = franco_envelope(household)
    household.service.call(
        franco,
        "memory_write",
        {"scope": SCOPE_HOUSEHOLD_SHARED, "subject": "bins", "body": "bins go out Thursday"},
    )
    for tool, arguments in (
        ("memory_search", {"query": "bins", "limit": -1}),
        ("mail_digest", {"limit": -1}),
    ):
        with pytest.raises(ArgumentInvalid, match="positive integer"):
            household.service.call(franco, tool, arguments)


def test_bad_arguments_are_refused_before_anything_is_written(household: Household) -> None:
    franco = franco_envelope(household)
    with pytest.raises(ArgumentInvalid):
        household.service.call(
            franco, "memory_write", {"scope": SCOPE_HOUSEHOLD_SHARED, "subject": "s"}
        )
    with household.database.read() as cx:
        assert cx.execute("SELECT count(*) FROM memory").fetchone()[0] == 0


def test_a_reminder_is_listed_by_its_instant_not_its_text(household: Household) -> None:
    """10:00 at -04:00 is 14:00 UTC, and 14:00 at +02:00 is 12:00 UTC.

    Compared as text the first reads as due before noon UTC and the second as due
    after 13:00 UTC, which is each one on the wrong side of the boundary.
    """
    franco = franco_envelope(household)
    for text, due_at in (
        ("afternoon", "2026-09-18T10:00:00-04:00"),
        ("midday", "2026-09-18T14:00:00+02:00"),
    ):
        household.service.call(
            franco,
            "reminder_create",
            {"text": text, "due_at": due_at, "scope": SCOPE_HOUSEHOLD_SHARED},
        )

    def listed(due_before: str) -> list[str]:
        result = household.service.call(franco, "reminder_list", {"due_before": due_before})
        assert isinstance(result, list)
        return [reminder.text for reminder in result]

    assert listed("2026-09-18T12:00:00+00:00") == ["midday"]
    assert listed("2026-09-18T13:00:00+00:00") == ["midday"]
    assert listed("2026-09-18T15:00:00+00:00") == ["midday", "afternoon"]


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("2026-09-18T10:00:00", "timezone offset"),
        ("2026-09-18", "timezone offset"),
        ("tomorrow", "ISO 8601"),
    ],
)
def test_a_reminder_time_that_is_not_an_aware_instant_is_refused(
    household: Household, value: str, expected: str
) -> None:
    franco = franco_envelope(household)
    with pytest.raises(ArgumentInvalid, match=expected):
        household.service.call(
            franco,
            "reminder_create",
            {"text": "x", "due_at": value, "scope": SCOPE_HOUSEHOLD_SHARED},
        )
    with pytest.raises(ArgumentInvalid, match=expected):
        household.service.call(franco, "reminder_list", {"due_before": value})


@pytest.mark.parametrize(
    ("spec", "arguments"),
    [
        (ReminderCreateArgs, {"text": "x", "scope": SCOPE_HOUSEHOLD_SHARED}),
        (ReminderListArgs, {}),
        (CalendarAvailabilityArgs, {"end": "2026-09-19T00:00:00+00:00"}),
        (
            CalendarEventProposeArgs,
            {"calendar_id": "c", "title": "t", "end": "2026-09-19T00:00:00+00:00"},
        ),
        (
            CalendarEventCreateArgs,
            {
                "approval_id": "a",
                "calendar_id": "c",
                "title": "t",
                "end": "2026-09-19T00:00:00+00:00",
            },
        ),
    ],
)
def test_every_timestamp_argument_is_normalised_to_utc_at_the_boundary(
    spec: type[ToolParams], arguments: dict[str, object]
) -> None:
    """10:00 at +02:00 is 08:00 UTC, and that is the only spelling a handler ever sees."""
    field = {
        ReminderCreateArgs: "due_at",
        ReminderListArgs: "due_before",
    }.get(spec, "start")
    parsed = parse_arguments(spec, {**arguments, field: "2026-09-18T10:00:00+02:00"})
    assert getattr(parsed, field) == "2026-09-18T08:00:00+00:00"


def test_two_spellings_of_one_instant_yield_one_approval_fingerprint(
    household: Household,
) -> None:
    """The approval binds to the instant, so a client that re-renders the offset still matches."""
    franco = franco_envelope(household)
    first = household.service.call(
        franco,
        "calendar_event_propose",
        {
            "calendar_id": "cal-franco-personal",
            "title": "Dinner",
            "start": "2026-09-18T19:00:00+00:00",
            "end": "2026-09-18T21:00:00+00:00",
        },
    )
    second = household.service.call(
        franco,
        "calendar_event_propose",
        {
            "calendar_id": "cal-franco-personal",
            "title": "Dinner",
            "start": "2026-09-18T21:00:00+02:00",
            "end": "2026-09-18T23:00:00+02:00",
        },
    )
    assert isinstance(first, Proposal)
    assert isinstance(second, Proposal)
    assert first.action_version == second.action_version
