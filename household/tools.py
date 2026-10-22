"""The typed tool contracts, and the only list of tools the service will dispatch.

A tool argument is data. It never carries an actor, a person, a scope set or a
capability: those come from the identity envelope and from nowhere else.
"""

from __future__ import annotations

import dataclasses
import types
import typing
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import NewType

from .errors import ArgumentInvalid
from .identity import SCOPE_HOUSEHOLD_SHARED, Capability

# Argument names that would let a caller name the actor, the scope or the
# capabilities. No contract may declare one, and ``parse_arguments`` refuses any
# argument a contract does not declare, so none of these can reach a tool.
RESERVED_ARGUMENT_NAMES = frozenset(
    {
        "actor",
        "actor_person_id",
        "as_person",
        "capabilities",
        "envelope",
        "on_behalf_of",
        "person",
        "person_id",
        "principal",
        "scope_override",
        "scopes",
        "user_id",
    }
)


# A timezone-aware ISO 8601 timestamp that ``parse_arguments`` has already normalised
# to UTC. Every due_at, due_before, start and end carries this type, so no handler, no
# stored row, no approval fingerprint and no provider ever sees a naive time, a free-form
# date, or two spellings of one instant.
Instant = NewType("Instant", str)


@dataclass(frozen=True, slots=True)
class ToolParams:
    """Base for every tool's argument record."""


@dataclass(frozen=True, slots=True)
class MemoryWriteArgs(ToolParams):
    scope: str
    subject: str
    body: str


@dataclass(frozen=True, slots=True)
class MemorySearchArgs(ToolParams):
    query: str
    limit: int = 20


@dataclass(frozen=True, slots=True)
class TaskCreateArgs(ToolParams):
    title: str
    scope: str


@dataclass(frozen=True, slots=True)
class TaskListArgs(ToolParams):
    include_done: bool = False


@dataclass(frozen=True, slots=True)
class TaskCompleteArgs(ToolParams):
    task_id: str


@dataclass(frozen=True, slots=True)
class ReminderCreateArgs(ToolParams):
    text: str
    due_at: Instant
    scope: str


@dataclass(frozen=True, slots=True)
class ReminderListArgs(ToolParams):
    due_before: Instant | None = None


@dataclass(frozen=True, slots=True)
class ListAddArgs(ToolParams):
    list_name: str
    text: str
    scope: str = SCOPE_HOUSEHOLD_SHARED


@dataclass(frozen=True, slots=True)
class ListItemsArgs(ToolParams):
    list_name: str
    scope: str = SCOPE_HOUSEHOLD_SHARED


@dataclass(frozen=True, slots=True)
class ListRemoveArgs(ToolParams):
    item_id: str


@dataclass(frozen=True, slots=True)
class CalendarAvailabilityArgs(ToolParams):
    start: Instant
    end: Instant


@dataclass(frozen=True, slots=True)
class CalendarEventProposeArgs(ToolParams):
    calendar_id: str
    title: str
    start: Instant
    end: Instant


@dataclass(frozen=True, slots=True)
class CalendarEventCreateArgs(ToolParams):
    approval_id: str
    calendar_id: str
    title: str
    start: Instant
    end: Instant


@dataclass(frozen=True, slots=True)
class MailDigestArgs(ToolParams):
    limit: int = 20


@dataclass(frozen=True, slots=True)
class MailDraftArgs(ToolParams):
    account_id: str
    to: str
    subject: str
    body: str


@dataclass(frozen=True, slots=True)
class ApprovalStatusArgs(ToolParams):
    approval_id: str


@dataclass(frozen=True, slots=True)
class ToolContract:
    name: str
    params: type[ToolParams]
    capability: Capability


_CONTRACTS: tuple[ToolContract, ...] = (
    ToolContract("memory_write", MemoryWriteArgs, Capability.MEMORY_WRITE),
    ToolContract("memory_search", MemorySearchArgs, Capability.MEMORY_READ),
    ToolContract("task_create", TaskCreateArgs, Capability.TASK_WRITE),
    ToolContract("task_list", TaskListArgs, Capability.TASK_READ),
    ToolContract("task_complete", TaskCompleteArgs, Capability.TASK_WRITE),
    ToolContract("reminder_create", ReminderCreateArgs, Capability.REMINDER_WRITE),
    ToolContract("reminder_list", ReminderListArgs, Capability.REMINDER_READ),
    ToolContract("list_add", ListAddArgs, Capability.LIST_WRITE),
    ToolContract("list_items", ListItemsArgs, Capability.LIST_READ),
    ToolContract("list_remove", ListRemoveArgs, Capability.LIST_WRITE),
    ToolContract("calendar_availability", CalendarAvailabilityArgs, Capability.CALENDAR_READ),
    ToolContract("calendar_event_propose", CalendarEventProposeArgs, Capability.CALENDAR_WRITE),
    ToolContract("calendar_event_create", CalendarEventCreateArgs, Capability.CALENDAR_WRITE),
    ToolContract("mail_digest", MailDigestArgs, Capability.MAIL_READ),
    ToolContract("mail_draft", MailDraftArgs, Capability.MAIL_DRAFT),
    ToolContract("approval_status", ApprovalStatusArgs, Capability.APPROVAL_READ),
    ToolContract("integration_health", ToolParams, Capability.HEALTH_READ),
)


def _build_registry() -> dict[str, ToolContract]:
    registry: dict[str, ToolContract] = {}
    for contract in _CONTRACTS:
        declared = {field.name for field in dataclasses.fields(contract.params)}
        reserved = declared & RESERVED_ARGUMENT_NAMES
        if reserved:
            raise ValueError(
                f"tool {contract.name!r} declares identity-bearing arguments: "
                f"{', '.join(sorted(reserved))}"
            )
        registry[contract.name] = contract
    return registry


REGISTRY: dict[str, ToolContract] = _build_registry()


def parse_arguments[ParamsT: ToolParams](
    spec: type[ParamsT], arguments: Mapping[str, object]
) -> ParamsT:
    """Validate raw arguments against a contract, or refuse.

    Unknown keys are an error rather than something to ignore, so a model that
    smuggles an extra field gets a refusal instead of silence.
    """
    fields_by_name = {field.name: field for field in dataclasses.fields(spec)}
    unknown = sorted(set(arguments) - set(fields_by_name))
    if unknown:
        raise ArgumentInvalid(f"{spec.__name__} has no argument named {', '.join(unknown)}")

    hints = typing.get_type_hints(spec)
    values: dict[str, object] = {}
    for name, field in fields_by_name.items():
        if name in arguments:
            values[name] = _coerce(spec.__name__, name, hints[name], arguments[name])
        elif field.default is dataclasses.MISSING and field.default_factory is dataclasses.MISSING:
            raise ArgumentInvalid(f"{spec.__name__} is missing required argument {name!r}")
    return spec(**values)


def _coerce(spec_name: str, name: str, annotation: object, value: object) -> object:
    """str, int, bool, ``Instant`` and ``X | None`` are what the contracts declare, so that
    is what this understands. Anything else is an error here rather than a surprise later."""
    origin = typing.get_origin(annotation)
    if origin in (types.UnionType, typing.Union):
        arms = [arm for arm in typing.get_args(annotation) if arm is not type(None)]
        if value is None:
            return None
        if len(arms) != 1:
            raise ArgumentInvalid(f"{spec_name}.{name} has an unsupported parameter type")
        return _coerce(spec_name, name, arms[0], value)
    if annotation is bool:
        if not isinstance(value, bool):
            raise ArgumentInvalid(f"{spec_name}.{name} must be a boolean")
        return value
    if annotation is int:
        if isinstance(value, bool) or not isinstance(value, int):
            raise ArgumentInvalid(f"{spec_name}.{name} must be an integer")
        # Every integer a contract declares is a row count. A negative one is not a
        # smaller answer, it is a different query, so it is refused here rather than
        # reaching SQLite's LIMIT or a slice.
        if value < 1:
            raise ArgumentInvalid(f"{spec_name}.{name} must be a positive integer")
        return value
    if annotation is Instant:
        if not isinstance(value, str):
            raise ArgumentInvalid(f"{spec_name}.{name} must be an ISO 8601 timestamp")
        try:
            instant = datetime.fromisoformat(value)
        except ValueError as error:
            raise ArgumentInvalid(
                f"{spec_name}.{name} must be an ISO 8601 timestamp: {value!r}"
            ) from error
        if instant.tzinfo is None:
            raise ArgumentInvalid(f"{spec_name}.{name} must carry a timezone offset: {value!r}")
        return Instant(instant.astimezone(UTC).isoformat())
    if annotation is str:
        if not isinstance(value, str):
            raise ArgumentInvalid(f"{spec_name}.{name} must be a string")
        return value
    raise ArgumentInvalid(f"{spec_name}.{name} has an unsupported parameter type")
