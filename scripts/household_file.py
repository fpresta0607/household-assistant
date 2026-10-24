"""The household file: who lives here, their assistants, and what the box needs to know.

It lives on the box in a root-only file the repository does not hold,
/etc/household-assistant/household.json; deploy/household.example.json shows its shape,
and HOUSEHOLD_FILE points the test suite at that example.

Each adult of the household is a member with an assistant of their own, on a gateway of
their own. The household app's family room is shared by exactly two people and their two
assistants, so a household file names two members.

This module needs nothing but the standard library, so the installers that copy
themselves to the box, and run from there, can carry it beside them.
"""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

HOUSEHOLD_FILE = Path(os.environ.get("HOUSEHOLD_FILE", "/etc/household-assistant/household.json"))
# Where each gateway's state lives on the box, one directory per member.
STATE_ROOT = Path("/var/lib/household-assistant")
# The first gateway's port on the box's loopback; each member after it takes the next one.
FIRST_PORT = 18789
MEMBERS = 2

ID = re.compile(r"[a-z][a-z0-9-]{0,31}")
NAME = re.compile(r"[A-Za-z][A-Za-z .'-]{0,39}")
DIRECTORY = re.compile(r"[a-z0-9][a-z0-9_.-]{0,63}")


class UnsupportedConfig(ValueError):
    """A config shape a script does not evaluate, rather than guess at."""


@dataclass(frozen=True, slots=True)
class Member:
    """One adult of the household, their assistant, and the gateway it runs on."""

    person: str
    name: str
    assistant: str
    assistant_name: str
    # The gateway's container, its state directory under STATE_ROOT, and the port the box
    # publishes it on, which the phones' tailnet route reaches.
    container: str
    state: str
    port: int

    @property
    def state_dir(self) -> Path:
        return STATE_ROOT / self.state


# A household file written before it named its members is the first household's own:
# Franco with Corey and Gia with Denise, on the gateways their box already runs.
LEGACY_MEMBERS = (
    Member("franco", "Franco", "corey", "Corey", "openclaw-gateway", "openclaw", 18789),
    Member("gia", "Gia", "denise", "Denise", "openclaw-denise", "openclaw-denise", 18790),
)


@dataclass(frozen=True, slots=True)
class Household:
    """The members, who lets in a phone that signed in with Apple and nobody linked, where
    the phones reach the gateways, the app's Google client, the calendar the planner reads
    and the Bible edition the household reads. The Telegram group and accounts a file
    written before Telegram was retired still names are not read."""

    members: tuple[Member, ...]
    approver: str
    gateway_host: str
    google_client_id: str
    shared_calendar: str
    shared_calendar_apple_id: str
    bible_version: str

    def member(self, persona: str) -> Member:
        """The member whose assistant is `persona`."""
        found = next((member for member in self.members if member.assistant == persona), None)
        if found is None:
            raise UnsupportedConfig(f"no member of the household has the assistant {persona!r}")
        return found


def _text(section: dict[str, Any], key: str, path: Path) -> str:
    value = section.get(key)
    if not isinstance(value, str) or not value:
        raise UnsupportedConfig(f"{path} has no {key}")
    return value


def _matching(value: object, pattern: re.Pattern[str], what: str, path: Path) -> str:
    if not isinstance(value, str) or not pattern.fullmatch(value):
        raise UnsupportedConfig(f"{path}: {what} {value!r} is not allowed")
    return value


def _member(raw: object, index: int, path: Path) -> Member:
    if not isinstance(raw, dict):
        raise UnsupportedConfig(f"{path}: member {index + 1} is not an object")
    person = _matching(raw.get("person"), ID, "a person id", path)
    assistant = _matching(raw.get("assistant"), ID, "an assistant id", path)
    port = raw.get("port", FIRST_PORT + index)
    if not isinstance(port, int) or isinstance(port, bool) or not 1024 <= port <= 65535:
        raise UnsupportedConfig(f"{path}: {assistant}'s port {port!r} is not allowed")
    return Member(
        person=person,
        name=_matching(raw.get("name", person.capitalize()), NAME, "a name", path),
        assistant=assistant,
        assistant_name=_matching(
            raw.get("assistantName", assistant.capitalize()), NAME, "an assistant name", path
        ),
        container=_matching(
            raw.get("container", f"openclaw-{assistant}"), DIRECTORY, "a container", path
        ),
        state=_matching(raw.get("state", f"openclaw-{assistant}"), DIRECTORY, "a state", path),
        port=port,
    )


def members_from(loaded: dict[str, Any], path: Path) -> tuple[Member, ...]:
    """The household's members, every id, container, state directory and port its own."""
    raw = loaded.get("members")
    if raw is None:
        return LEGACY_MEMBERS
    if not isinstance(raw, list) or len(raw) != MEMBERS:
        raise UnsupportedConfig(
            f"{path} must name exactly {MEMBERS} members, the two people of the family room"
        )
    members = tuple(_member(entry, index, path) for index, entry in enumerate(raw))
    for field in ("container", "state", "port"):
        values = [getattr(member, field) for member in members]
        if len(set(values)) != len(values):
            raise UnsupportedConfig(f"{path}: two members share a {field}")
    ids = [member.person for member in members] + [member.assistant for member in members]
    if len(set(ids)) != len(ids):
        raise UnsupportedConfig(f"{path}: every person and assistant needs an id of its own")
    return members


def load_household(path: Path = HOUSEHOLD_FILE) -> Household:
    loaded = json.loads(path.read_bytes())
    if not isinstance(loaded, dict):
        raise UnsupportedConfig(f"{path} is not a JSON object")
    members = members_from(loaded, path)
    approver = loaded.get("approver", members[0].person)
    if approver not in [member.person for member in members]:
        raise UnsupportedConfig(f"{path}: the approver {approver!r} is not a member")
    calendar = loaded.get("sharedCalendar")
    if not isinstance(calendar, dict):
        raise UnsupportedConfig(f"{path} has no sharedCalendar")
    return Household(
        members=members,
        approver=approver,
        gateway_host=_text(loaded, "gatewayHost", path),
        google_client_id=_text(loaded, "googleClientId", path),
        shared_calendar=_text(calendar, "name", path),
        shared_calendar_apple_id=_text(calendar, "appleId", path),
        bible_version=_text(loaded, "bibleVersion", path),
    )
